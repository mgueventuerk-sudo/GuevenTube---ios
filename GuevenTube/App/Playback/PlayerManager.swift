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

    func play(_ plan: PlaybackPlan, startAtMs: Int64 = 0, info: NowPlaying? = nil) {
        loadTask?.cancel()
        self.plan = plan
        self.info = info
        state = .loading
        positionMs = startAtMs
        loadTask = Task { [weak self] in
            do {
                let item = try await Self.makeItem(for: plan)
                guard !Task.isCancelled, let self else { return }
                self.attach(item, startAtMs: startAtMs)
            } catch is CancellationError {
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
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
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        plan = nil; info = nil; state = .idle; positionMs = 0; durationMs = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Item-Bau

    nonisolated static func headers(for plan: PlaybackPlan) -> [String: String] {
        ["User-Agent": plan.userAgent]
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

    private func attach(_ item: AVPlayerItem, startAtMs: Int64) {
        itemObservers.removeAll()
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
                self.state = .failed(item.error?.localizedDescription ?? "Wiedergabe fehlgeschlagen")
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
#endif
