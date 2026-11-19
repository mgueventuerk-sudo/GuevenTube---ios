#if canImport(AVFoundation)
import AVFoundation
import MediaPlayer
import Combine
import GuevenCore

/// Spielt einen `PlaybackPlan` mit AVPlayer ab. Apple-only, bis zum ersten Mac-Lauf ungetestet.
/// Getrennte Bild-/Tonströme werden per `AVMutableComposition` zu einem Item zusammengesetzt (ersetzt DASH).
@MainActor
final class PlayerManager: ObservableObject {
    enum State: Equatable { case idle, loading, ready, playing, paused, ended, failed(String) }

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var artworkUrl: URL?
    }

    let player = AVPlayer()
    @Published private(set) var state: State = .idle
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var plan: PlaybackPlan?
    /// Wird ca. 4-mal pro Sekunde mit der Position aufgerufen (SponsorBlock).
    var onPosition: ((Int64) -> Void)?

    private var timeObserver: Any?
    private var itemObservers: [AnyCancellable] = []
    private var statusObserver: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var info: NowPlaying?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // 4 Hz reicht für Fortschrittsleiste und SponsorBlock-Überspringen.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        // Anruf, Siri, Kopfhörer abziehen oder Bild-in-Bild pausieren den Player am Code vorbei: Zustand nachziehen,
        // sonst zeigen Play-Taste, Sperrbildschirm und Kindermodus-Zeitzähler etwas Falsches.
        statusObserver = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self else { return }
            if status == .paused, self.state == .playing { self.state = .paused; self.publishNowPlaying() }
            else if status == .playing, self.state == .paused { self.state = .playing; self.publishNowPlaying() }
        }
        configureRemoteCommands()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Steuerung

    func play(_ plan: PlaybackPlan, startAtMs: Int64 = 0, info: NowPlaying? = nil, resolveNote: String? = nil) {
        // Ohne aktive Sitzung bricht die Wiedergabe im Hintergrund und bei gesperrtem Bildschirm ab.
        try? AVAudioSession.sharedInstance().setActive(true)
        alternatives = []
        hlsMaxHeight = nil
        diag = resolveNote.map { [$0] } ?? []
        var first = plan
        if let hls = plan.hlsFallbackUrl, !plan.isLive {
            var viaHls = plan
            viaHls.source = .hls(url: hls); viaHls.hlsFallbackUrl = nil; viaHls.qualityLabel = "HLS"
            var original = plan
            original.hlsFallbackUrl = nil
            switch plan.source {
            case .separate(_, _, let height):
                // Zwei getrennte Ströme zu einem Medium zusammensetzen hängt auf dem iPhone mit YouTube-DASH-URLs (Ladekreis ohne Ende).
                // HLS spielt AVPlayer nativ: zuerst HLS (mit Höhenbegrenzung), die Zusammensetzung nur als Notweg.
                first = viaHls; alternatives = [original]; hlsMaxHeight = height
            case .progressive:
                alternatives = [viaHls]
            case .hls, .audioOnly:
                break
            }
        }
        // Schlechtere Stufen als weitere Notwege (der Videoserver lehnt manche Stufen ab, andere nicht).
        for alt in plan.ladder {
            var p = plan
            p.source = alt.source; p.qualityLabel = alt.label; p.hlsFallbackUrl = nil; p.ladder = []
            alternatives.append(p)
        }
        diagnosedOnce = false
        start(first, startAtMs: startAtMs, info: info)
    }

    /// Weitere Wege, falls der erste fehlschlägt oder nicht rechtzeitig startet (HLS/Zusammensetzen, dann schlechtere Stufen).
    private var alternatives: [PlaybackPlan] = []
    private var hlsMaxHeight: Int?
    private var watchdog: Task<Void, Never>?
    private var startGeneration = 0
    /// Was jeder Versuch ergeben hat (Weg, HTTP-Status, Tempo, Dateikopf): erscheint bei einem Fehler im Player.
    private(set) var diag: [String] = []
    /// Hat der Videoserver alle Notwege eines Wegs abgelehnt (HTTP 4xx), fragt der Player den Aufrufer nach dem nächsten Weg.
    /// Rückgabe `true` = der Aufrufer startet neu, kein Fehler anzeigen.
    var onRouteRejected: ((_ routeLabel: String, _ status: Int) -> Bool)?

    private func start(_ plan: PlaybackPlan, startAtMs: Int64, info: NowPlaying?) {
        loadTask?.cancel()
        watchdog?.cancel()
        startGeneration += 1
        let generation = startGeneration
        self.plan = plan
        self.info = info
        state = .loading
        positionMs = startAtMs
        // Schneller Weg: sofort abspielen. Die Adress-Probe (Status, Tempo, Dateikopf) läuft nur noch nach einem Fehler.
        loadTask = Task { [weak self] in
            do {
                let item = try await Self.makeItem(for: plan)
                guard !Task.isCancelled, let self, self.startGeneration == generation else { return }
                self.attach(item, startAtMs: startAtMs, generation: generation)
            } catch is CancellationError {
            } catch {
                self?.recover(startAtMs: startAtMs, info: info, error: error, generation: generation)
            }
        }
        // Ein Weg, der nie fertig wird, darf nicht ewig den Ladekreis zeigen.
        let limitSeconds: UInt64 = alternatives.isEmpty ? 45 : 12
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: limitSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.startGeneration == generation, self.state == .loading else { return }
            self.recover(startAtMs: startAtMs, info: info, generation: generation,
                         error: NSError(domain: "GuevenTube", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zeitüberschreitung: Das Video startet nicht."]))
        }
    }

    private var recoveringGeneration = -1
    private var diagnosedOnce = false

    /// Nach einem Fehler erst messen, was der Videoserver sagt (HTTP-Status), dann Notweg oder Fehleranzeige.
    private func recover(startAtMs: Int64, info: NowPlaying?, error: Error?, generation: Int) {
        guard generation == startGeneration, recoveringGeneration != generation, let failed = plan else { return }
        recoveringGeneration = generation
        let full = !diagnosedOnce
        diagnosedOnce = true
        Task { [weak self] in
            let probes = await Self.probe(failed, full: full)
            guard let self, generation == self.startGeneration else { return }
            self.diag.append(contentsOf: probes.lines)
            var reason = error
            if let bad = probes.badStatus {
                reason = NSError(domain: "GuevenTube", code: bad, userInfo: [NSLocalizedDescriptionKey: "Server verweigert den Strom (HTTP \(bad))"])
            }
            self.fallbackOrFail(startAtMs: startAtMs, info: info, error: reason)
        }
    }

    /// Notweg, falls vorhanden; sonst Fehler mit der echten Ursache anzeigen.
    private func fallbackOrFail(startAtMs: Int64, info: NowPlaying?, error: Error?) {
        if !alternatives.isEmpty {
            let next = alternatives.removeFirst()
            hlsMaxHeight = nil
            start(next, startAtMs: startAtMs, info: info)
            return
        }
        let ns = error as NSError?
        if let ns, ns.domain == "GuevenTube", (400..<500).contains(ns.code), let label = plan?.clientLabel, !label.isEmpty,
           onRouteRejected?(label, ns.code) == true { return }
        var detail = ns.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "Wiedergabe fehlgeschlagen"
        if let u = ns?.userInfo[NSUnderlyingErrorKey] as? NSError { detail += " ← \(u.domain) \(u.code)" }
        state = .failed(([detail] + diag).joined(separator: "\n"))
    }

    /// Testet jede Adresse des Plans mit einer kleinen Bereichsanfrage (128 KB). Lehnt der Server den Standard mit 4xx ab,
    /// werden Varianten probiert (andere Kopfzeilen, Bereich als Parameter); die erste, die klappt, wird für den Player übernommen.
    nonisolated static func probe(_ plan: PlaybackPlan, full: Bool) async -> (lines: [String], badStatus: Int?, headers: [String: String]) {
        let targets: [(String, String)]
        switch plan.source {
        case .hls(let u): targets = [("HLS", u)]
        case .progressive(let u, _): targets = [("Einzelstrom", u)]
        case .audioOnly(let u): targets = [("Ton", u)]
        case .separate(let v, let a, _): targets = [("Bild", v), ("Ton", a)]
        }
        struct Variant { let name: String; let headers: [String: String]; let rangeParam: Bool }
        let yt = HTTPConstants.youtubeOrigin
        let allVariants: [Variant] = [
            Variant(name: "+Origin/Referer", headers: ["Origin": yt, "Referer": yt + "/"], rangeParam: false),
            Variant(name: "Standard", headers: [:], rangeParam: false),
            Variant(name: "TV-Cobalt-UA", headers: ["User-Agent": HTTPConstants.tvUserAgent, "Origin": yt, "Referer": HTTPConstants.youtubeTvReferer], rangeParam: false),
            Variant(name: "Desktop-UA", headers: ["User-Agent": HTTPConstants.desktopUserAgent, "Origin": yt, "Referer": yt + "/"], rangeParam: false),
            Variant(name: "range-Parameter", headers: [:], rangeParam: true),
        ]
        // Alle Varianten nur beim ersten Weg; die Notwege prüfen die zwei wahrscheinlichsten (spart Wartezeit).
        let variants = full ? allVariants : Array(allVariants.prefix(2))
        func fetch(_ url: URL, _ v: Variant) async -> (status: Int, type: String, bytes: Int, ms: Int, head: String, text: String, error: String?, family: String) {
            var u = url
            if v.rangeParam, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "range", value: "0-131071")]
                u = c.url ?? url
            }
            var r = URLRequest(url: u); r.timeoutInterval = 6
            r.setValue(plan.userAgent, forHTTPHeaderField: "User-Agent")
            if !v.rangeParam { r.setValue("bytes=0-131071", forHTTPHeaderField: "Range") }
            for (k, val) in v.headers { r.setValue(val, forHTTPHeaderField: k) }
            let t0 = Date()
            let family = ConnectionFamily()
            do {
                let (data, resp) = try await URLSessionTransport.cookieFreeSession.data(for: r, delegate: family)
                let h = resp as? HTTPURLResponse
                let type = h?.value(forHTTPHeaderField: "Content-Type") ?? "?"
                let ms = max(Int(Date().timeIntervalSince(t0) * 1000), 1)
                var text = ""
                if type.contains("text") || type.contains("json") || type.contains("mpegurl") || type.contains("xml") {
                    text = " „" + String(decoding: data.prefix(50), as: UTF8.self).replacingOccurrences(of: "\n", with: " ") + "“"
                }
                return (h?.statusCode ?? 0, type, data.count, ms, data.prefix(8).map { String(format: "%02x", $0) }.joined(), text, nil, family.label)
            } catch {
                let ns = error as NSError
                return (0, "", 0, Int(Date().timeIntervalSince(t0) * 1000), "", "", "\(ns.domain) \(ns.code)", family.label)
            }
        }
        var lines: [String] = [], bad: Int?, chosen: [String: String] = [:]
        for (name, url) in targets {
            guard let u = URL(string: url) else { lines.append("\(name): ungültige Adresse"); continue }
            let tag = "\(plan.qualityLabel) \(name) \((u.host ?? "?").prefix(14))"
            var ok = false
            for (index, v) in variants.enumerated() {
                // Nach einer funktionierenden Variante für den ersten Strom gleich diese für den zweiten zuerst, sonst der Reihe nach.
                let res = await fetch(u, v)
                let good = (200..<300).contains(res.status)
                if let e = res.error { lines.append("\(tag) \(v.name): \(e) \(res.ms)ms") }
                else { lines.append("\(tag) \(v.name) via \(res.family): HTTP \(res.status) \(res.type) \(res.bytes)B \(res.ms)ms (\(res.bytes / res.ms) kB/s) [\(res.head)]\(res.text)") }
                if good {
                    ok = true
                    if !v.rangeParam { for (k, val) in v.headers { chosen[k] = val } }
                    break
                }
                // Nur bei echten Ablehnungen (4xx) Varianten durchprobieren; Netzwerkfehler und Erfolg beenden die Schleife.
                if !(400..<500).contains(res.status) || index == variants.count - 1 { bad = res.status >= 400 ? res.status : bad; break }
            }
            // Ist ein Strom abgelehnt, ist der Weg unbrauchbar: den zweiten nicht mehr testen.
            if !ok && bad != nil { break }
        }
        // IP-Familie, an die die Adresse gebunden ist (nur v4/v6, nie die Adresse selbst).
        if full, let first = targets.first, let c = URLComponents(string: first.1), let ip = c.queryItems?.first(where: { $0.name == "ip" })?.value {
            lines.append("Adresse gebunden an: \(ip.contains(":") ? "IPv6" : "IPv4")")
        }
        // Query-Parameter-Namen (ohne Werte) der ersten Adresse: zeigt z. B. ein fehlendes `pot`.
        if full, bad != nil, let first = targets.first, let c = URLComponents(string: first.1) {
            let items = c.queryItems ?? []
            let c0 = items.first { $0.name == "c" }?.value ?? "-"
            lines.append("Parameter: c=\(c0) " + items.map(\.name).sorted().joined(separator: ","))
            // n-Wert (Drosselungs-Parameter, kein Geheimnis): erkennt eine kaputte Entschlüsselung („enhanced_except_…“).
            if let n = items.first(where: { $0.name == "n" })?.value { lines.append("n=\(n.prefix(40)) (Länge \(n.count))") }
        }
        return (lines, bad, chosen)
    }

    func resume() { player.play(); if state == .paused || state == .ready { state = .playing } }
    func pause() { player.pause(); if state == .playing { state = .paused } }
    func toggle() { state == .playing ? pause() : resume() }

    func seek(toMs ms: Int64) {
        let t = CMTime(value: ms, timescale: 1000)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        positionMs = ms
    }

    func skip(byMs delta: Int64) {
        let target = max(0, positionMs + delta)
        seek(toMs: durationMs > 0 ? min(target, durationMs) : target)
    }

    func setRate(_ rate: Float) { player.defaultRate = rate; if state == .playing { player.rate = rate } }

    func stop() {
        loadTask?.cancel(); watchdog?.cancel(); alternatives = []; hlsMaxHeight = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        plan = nil; info = nil; state = .idle; positionMs = 0; durationMs = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Item-Bau

    nonisolated static func headers(for plan: PlaybackPlan) -> [String: String] {
        // Origin/Referer wie die erste (und bei dir erfolgreiche) Variante der früheren Vorab-Probe: Der Videoserver nahm den Ton nur damit an.
        var h = ["User-Agent": plan.userAgent, "Origin": HTTPConstants.youtubeOrigin, "Referer": HTTPConstants.youtubeOrigin + "/"]
        for (k, v) in plan.extraHeaders { h[k] = v }
        return h
    }

    /// `AVURLAssetHTTPHeaderFieldsKey` ist nicht dokumentiert, wird aber seit Jahren von Apps genutzt (wahrscheinlich stabil).
    nonisolated static func asset(_ url: String, plan: PlaybackPlan) throws -> AVURLAsset {
        guard let u = URL(string: url) else { throw PlaybackPlanError("Ungültige Stream-Adresse") }
        return AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers(for: plan)])
    }

    nonisolated static func makeItem(for plan: PlaybackPlan) async throws -> AVPlayerItem {
        switch plan.source {
        case .hls(let url), .progressive(let url, _), .audioOnly(let url):
            return AVPlayerItem(asset: try asset(url, plan: plan))
        case .separate(let videoUrl, let audioUrl, _):
            let video = try asset(videoUrl, plan: plan)
            let audio = try asset(audioUrl, plan: plan)
            async let vTracks = video.loadTracks(withMediaType: .video)
            async let aTracks = audio.loadTracks(withMediaType: .audio)
            async let vDur = video.load(.duration)
            async let aDur = audio.load(.duration)
            guard let vTrack = try await vTracks.first, let aTrack = try await aTracks.first else {
                throw PlaybackPlanError("Bild- oder Tonspur fehlt")
            }
            // Kürzere Dauer, damit die Zusammensetzung nicht über das Ende einer Spur hinausläuft.
            let duration = CMTimeMinimum(try await vDur, try await aDur)
            let range = CMTimeRange(start: .zero, duration: duration)
            let comp = AVMutableComposition()
            guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PlaybackPlanError("Zusammensetzen nicht möglich")
            }
            try cv.insertTimeRange(range, of: vTrack, at: .zero)
            try ca.insertTimeRange(range, of: aTrack, at: .zero)
            cv.preferredTransform = try await vTrack.load(.preferredTransform)
            return AVPlayerItem(asset: comp)
        }
    }

    private func attach(_ item: AVPlayerItem, startAtMs: Int64, generation: Int) {
        itemObservers.removeAll()
        if let h = hlsMaxHeight { item.preferredMaximumResolution = CGSize(width: Double(h) * 16 / 9, height: Double(h)) }
        item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self else { return }
            switch status {
            case .readyToPlay:
                let d = item.duration
                self.durationMs = d.isNumeric && d.seconds.isFinite ? Int64(d.seconds * 1000) : 0
                if self.state == .loading { self.state = .ready }
                if startAtMs > 0 { self.seek(toMs: startAtMs) }
                self.player.play()
                self.state = .playing
                self.publishNowPlaying()
            case .failed:
                self.recover(startAtMs: startAtMs, info: self.info, error: item.error, generation: generation)
            default: break
            }
        }.store(in: &itemObservers)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.state = .ended }.store(in: &itemObservers)
        player.replaceCurrentItem(with: item)
    }

    private func tick(_ t: CMTime) {
        guard t.isNumeric, t.seconds.isFinite else { return }
        positionMs = Int64(t.seconds * 1000)
        if state == .playing { onPosition?(positionMs) }
        if var np = MPNowPlayingInfoCenter.default().nowPlayingInfo, state == .playing || state == .paused {
            np[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t.seconds
            np[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? Double(player.rate) : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = np
        }
    }

    // MARK: Sperrbildschirm / Kopfhörer

    private func publishNowPlaying() {
        guard let info else { return }
        var np: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if plan?.isLive == true { np[MPNowPlayingInfoPropertyIsLiveStream] = true }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
        guard let url = info.artworkUrl else { return }
        Task.detached {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                cur[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
            }
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            // assumeIsolated stürzt ab, wenn iOS den Handler nicht auf dem Main-Thread ruft: dann dorthin wechseln.
            let target = cmd.addTarget { e in
                if Thread.isMainThread { return MainActor.assumeIsolated { handler(e) } }
                return DispatchQueue.main.sync { MainActor.assumeIsolated { handler(e) } }
            }
            remoteTargets.append((cmd, target))
        }
        add(c.playCommand) { [weak self] _ in self?.resume(); return .success }
        add(c.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        add(c.togglePlayPauseCommand) { [weak self] _ in self?.toggle(); return .success }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        add(c.skipForwardCommand) { [weak self] _ in self?.skip(byMs: 10_000); return .success }
        add(c.skipBackwardCommand) { [weak self] _ in self?.skip(byMs: -10_000); return .success }
        add(c.changePlaybackPositionCommand) { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(toMs: Int64(e.positionTime * 1000)); return .success
        }
    }
}

/// Merkt sich, mit welcher Gegenstelle (IPv4/IPv6) die Anfrage tatsächlich verbunden war.
/// Die Stream-Adresse gilt nur für die IP, von der `/player` kam: Wechselt die Verbindung die IP-Familie, antwortet Google mit 403.
private final class ConnectionFamily: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var remote: String?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        remote = metrics.transactionMetrics.last?.remoteAddress
    }
    var label: String { remote.map { $0.contains(":") ? "v6" : "v4" } ?? "?" }
}
#endif
