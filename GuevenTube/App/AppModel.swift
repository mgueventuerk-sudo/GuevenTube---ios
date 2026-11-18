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

    init() {
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

    func play(_ item: VideoItem, audioOnly: Bool = false, showPlayer: Bool = true, keepQueue: Bool = false, startAtMs: Int64? = nil) {
        task?.cancel()
        if !keepQueue { queue = []; queueRemaining = 0 }
        autoplayAllowed = !audioOnly && !keepQueue
        current = item
        skipPlanner = nil; skipPrompt = nil; captions = []
        playbackError = nil
        self.showPlayer = showPlayer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let settings = await env.settings.current()
                let resolved = try await env.resolver.resolve(item.videoId)
                captions = resolved.playerData.captions
                try Task.checkCancellation()
                let plan = try PlaybackSourcePlanner.plan(resolved, maxHeight: settings.maxResolution?.height, audioOnly: audioOnly)
                Task { await self.loadSponsorSegments(item.videoId) }
                // `await` darf nicht in einem `??`-Autoclosure stehen: darum ausgeschrieben.
                let resume: Int64
                if audioOnly { resume = 0 }
                else if let startAtMs { resume = startAtMs }
                else { resume = await env.library.resumePositionMs(item.videoId) }
                player.setRate(settings.defaultPlaybackSpeed)
                player.play(plan, startAtMs: resume, info: .init(title: item.title, artist: item.channelName ?? "",
                                              artworkUrl: URL(string: item.thumbnailUrl)))
            } catch is CancellationError {
            } catch {
                playbackError = String(describing: error)
            }
        }
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
        guard let item = current, !(player.plan?.isLive ?? false), player.durationMs > 0 else { return }
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
