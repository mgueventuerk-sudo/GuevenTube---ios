import Combine
import SwiftUI
import GuevenCore

/// Brücke zwischen Oberfläche und Diensten: löst ein Video auf und startet die Wiedergabe. Apple-only, ungetestet.
@MainActor
final class AppModel: ObservableObject {
    let env = AppEnvironment.shared
    let player = PlayerManager()
    @Published private(set) var current: VideoItem?
    @Published private(set) var playbackError: String?
    @Published var showPlayer = false
    /// Kanalseite als Sheet; im Player und außerhalb davon je ein eigenes Sheet (zwei Sheets gleichzeitig gehen nicht).
    @Published var channelRoute: ChannelRef?
    /// Empfohlene Videos zum laufenden Video (unter dem Player).
    @Published private(set) var related: [VideoItem] = []
    @Published private(set) var skipPrompt: SponsorSegment?
    /// Untertitelspuren des laufenden Videos (für das Transkript).
    @Published private(set) var captions: [CaptionTrack] = []
    private var skipPlanner: SponsorSkipPlanner?
    private var lastSavedAtMs: Int64 = 0
    private var task: Task<Void, Never>?
    /// Folge-Videos einer Playlist; leer, sobald etwas anderes gestartet wird.
    private var queue: [VideoItem] = []
    @Published private(set) var queueRemaining = 0
    private var endObserver: AnyCancellable?
    /// Autoplay nur nach einzeln gestarteten Videos: nicht nach Musik (eigene Warteschlange) und nicht nach Playlists.
    private var autoplayAllowed = false
    /// Wie oft für das aktuelle Video nach einer Ablehnung durch den Videoserver ein anderer Weg versucht wurde.
    private var routeRetries = 0
    private var lastReresolve = Date.distantPast
    /// Läuft gerade nur der Ton (Musik oder „Nur Ton“ im Video-Player)?
    @Published private(set) var lastAudioOnly = false

    init() {
        player.onRouteRejected = { [weak self] label, _ in self?.retryWithNextRoute(label) ?? false }
        player.onPosition = { [weak self] ms in self?.handleSkip(ms) }
        endObserver = player.$state.removeDuplicates().sink { [weak self] state in
            if state == .ended { self?.playNextInQueue() }
        }
    }

    /// Empfohlenes Folgevideo (erstes aus `next`, ohne bereits Gesehenes im Verlauf); scheitert still – dann bleibt das Video am Ende stehen.
    private func autoplayNext() {
        guard autoplayAllowed, let current else { return }
        let id = current.videoId
        Task { [weak self] in
            guard let self, await env.settings.current().autoplay else { return }
            guard let json = try? await env.innerTube.next(videoId: id) else { return }
            let related = InnerTubeParser.parseWatchNext(json, videoId: id).related
            let watched = await env.library.progressMap()
            guard let next = related.first(where: { watched[$0.videoId] == nil && !$0.isLive }),
                  self.current?.videoId == id, self.player.state == .ended else { return }
            play(next)
        }
    }

    private func loadRelated(_ id: String) {
        Task { [weak self] in
            guard let self, let json = try? await env.innerTube.next(videoId: id) else { return }
            let items = InnerTubeParser.parseWatchNext(json, videoId: id).related
            if current?.videoId == id { related = items }
        }
    }

    /// Spielt [items] nacheinander; jedes andere `play` beendet die Reihenfolge.
    func playQueue(_ items: [VideoItem]) {
        guard let first = items.first else { return }
        play(first)
        queue = Array(items.dropFirst()); queueRemaining = queue.count
        autoplayAllowed = false
    }

    func playNextInQueue() {
        guard !queue.isEmpty else { return autoplayNext() }
        let next = queue.removeFirst(); queueRemaining = queue.count
        play(next, keepQueue: true)
    }

    func play(_ item: VideoItem, audioOnly: Bool = false, showPlayer: Bool = true, keepQueue: Bool = false, startAtMs: Int64? = nil, isRouteRetry: Bool = false) {
        task?.cancel()
        if !isRouteRetry {
            // Beim Wechsel mitten im Video den Fortschritt des bisherigen sichern (sonst nur der Stand bis zu 10 s davor).
            if current != nil { saveProgress(player.positionMs, force: true) }
            routeRetries = 0
            if !keepQueue { queue = []; queueRemaining = 0 }
            autoplayAllowed = !audioOnly && !keepQueue
        }
        lastAudioOnly = audioOnly
        current = item
        skipPlanner = nil; skipPrompt = nil; captions = []
        playbackError = nil
        related = []
        if !audioOnly { loadRelated(item.videoId) }
        self.showPlayer = showPlayer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let settings = await env.settings.current()
                let t0 = Date()
                let resolved = try await env.resolver.resolve(item.videoId)
                let resolveMs = Int(Date().timeIntervalSince(t0) * 1000)
                let potStatus = await env.poTokens.status
                let tried = resolved.attempts.map { $0.displayLine() }.joined(separator: "\n")
                // Nach einem abgelehnten Weg: bisherige Messwerte vorne anhängen, damit ein Fehler alle Wege zeigt.
                let earlier = isRouteRetry ? player.diag.joined(separator: "\n") + "\n— nächster Weg —\n" : ""
                let resolveNote = earlier + "Auflösung \(Int(Date().timeIntervalSince(t0) * 1000)) ms · \(resolved.clientLabel): \(resolved.summary)" + (tried.isEmpty ? "" : "\n" + tried)
                    + "\nPO-Token: " + potStatus
                try Task.checkCancellation()
                captions = resolved.playerData.captions
                let plan = try PlaybackSourcePlanner.plan(resolved, maxHeight: settings.maxResolution?.height, audioOnly: audioOnly)
                Task { await self.loadSponsorSegments(item.videoId) }
                // `await` darf nicht in einem `??`-Autoclosure stehen: darum ausgeschrieben.
                let resume: Int64
                if let startAtMs { resume = startAtMs }
                else if audioOnly { resume = 0 }
                else { resume = await env.library.resumePositionMs(item.videoId) }
                // Ein neueres play() darf nicht von diesem veralteten Aufruf überschrieben werden.
                try Task.checkCancellation()
                player.setRate(settings.defaultPlaybackSpeed)
                player.play(plan, startAtMs: resume, info: .init(title: item.title, artist: item.channelName ?? "",
                                              artworkUrl: URL(string: item.thumbnailUrl)), resolveNote: resolveNote, resolveMs: resolveMs)
            } catch is CancellationError {
            } catch {
                playbackError = Self.describe(error)
            }
        }
    }

    /// „Neu auflösen“: Zwischenspeicher dieses Videos verwerfen und an derselben Stelle neu starten.
    func reresolve() {
        // Abkühlzeit: wiederholtes Tippen darf keine Anfragewelle (Bot-Muster) auslösen.
        guard let item = current, Date().timeIntervalSince(lastReresolve) > 30 else { playbackError = playbackError ?? "Bitte kurz warten (30 s) vor dem nächsten Neu-Auflösen."; return }
        lastReresolve = Date()
        let pos = player.positionMs, audioOnly = lastAudioOnly, show = showPlayer
        Task { [weak self] in
            guard let self else { return }
            await env.resolver.invalidate(item.videoId)
            play(item, audioOnly: audioOnly, showPlayer: show, keepQueue: true, startAtMs: pos)
        }
    }

    /// Video ↔ „Nur Ton“ umschalten, an derselben Stelle; Warteschlange und Autoplay bleiben erhalten.
    func setAudioOnly(_ on: Bool) {
        guard let item = current, !item.isLive, on != lastAudioOnly else { return }
        let position = player.positionMs, auto = autoplayAllowed
        play(item, audioOnly: on, showPlayer: showPlayer, keepQueue: true, startAtMs: position)
        autoplayAllowed = auto
    }

    /// Der Videoserver hat die Streams eines Wegs abgelehnt: Weg sperren, neu auflösen (nächster Weg), höchstens zweimal.
    private func retryWithNextRoute(_ routeLabel: String) -> Bool {
        guard routeRetries < 2, let item = current else { return false }
        routeRetries += 1
        let audioOnly = lastAudioOnly, show = showPlayer
        Task { [weak self] in
            guard let self else { return }
            await env.resolver.rejectRoute(videoId: item.videoId, routeLabel: routeLabel)
            play(item, audioOnly: audioOnly, showPlayer: show, keepQueue: true, isRouteRetry: true)
        }
        return true
    }

    /// Deutscher Satz zu bekannten Gründen (steht über den technischen Zeilen), sonst `nil`.
    static func hint(for message: String) -> String? {
        let m = message.lowercased()
        if m.contains("requires payment") {
            return "Dieser Film ist bei YouTube kostenpflichtig (Kauf oder Leihe) und lässt sich in der App nicht abspielen. Wähle ein anderes Video."
        }
        if m.contains("unavailable") {
            return "Dieses Video ist bei YouTube nicht (mehr) verfügbar. Wähle ein anderes Video."
        }
        return nil
    }

    /// Lesbare Fehlermeldung samt den versuchten Wegen, damit ein Screenshot die Ursache zeigt.
    static func describe(_ error: Error) -> String {
        if let e = error as? PlaybackUnavailableError {
            let details = ([e.message] + e.attempts.map { $0.displayLine() }).joined(separator: "\n")
            guard let hint = hint(for: e.message) else { return details }
            return hint + "\n\nTechnische Details:\n" + details
        }
        if let e = error as? PlaybackPlanError { return e.message }
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    /// Lädt SponsorBlock-Segmente im Hintergrund; ohne Treffer oder bei Fehlern läuft die Wiedergabe unverändert.
    private func loadSponsorSegments(_ videoId: String) async {
        let settings = await env.settings.current()
        guard settings.sponsorBlockEnabled else { return }
        let categories = Set(SponsorCategory.allCases.filter { settings.skipMode($0) != .disabled })
        guard let segments = try? await env.sponsorBlock.segments(videoId, categories: categories), !segments.isEmpty,
              current?.videoId == videoId else { return }
        skipPlanner = SponsorSkipPlanner(segments: segments, enabled: true, mode: { settings.skipMode($0) })
    }

    /// Fortschritt höchstens alle 10 s sichern (Datei wird je Speichern geschrieben).
    private func saveProgress(_ ms: Int64, force: Bool = false) {
        // Musik (nur Ton) gehört nicht in „Weiterschauen“: Sie startet ohnehin immer bei 0.
        guard let item = current, !lastAudioOnly, !(player.plan?.isLive ?? false), player.durationMs > 0 else { return }
        guard force || abs(ms - lastSavedAtMs) >= 10_000 else { return }
        lastSavedAtMs = ms
        let duration = player.durationMs
        Task { await env.library.saveProgress(videoId: item.videoId, positionMs: ms, durationMs: duration, title: item.title,
                                              channelName: item.channelName, thumbnailUrl: item.thumbnailUrl) }
    }

    private func handleSkip(_ ms: Int64) {
        saveProgress(ms)
        guard var planner = skipPlanner else { return }
        let action = planner.update(positionMs: ms)
        skipPlanner = planner
        switch action {
        case .none: break
        case .seek(let to, _): player.seek(toMs: to)
        case .showPrompt(let s): skipPrompt = s
        case .hidePrompt: skipPrompt = nil
        }
    }

    func skipPrompted() {
        guard var planner = skipPlanner, let target = planner.skipPrompted() else { return }
        skipPlanner = planner; skipPrompt = nil
        player.seek(toMs: target)
    }

    func closePlayer() { queue = []; queueRemaining = 0; saveProgress(player.positionMs, force: true); task?.cancel(); skipPlanner = nil; skipPrompt = nil; player.stop(); current = nil; showPlayer = false }
}
