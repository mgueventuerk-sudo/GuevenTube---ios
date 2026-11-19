import SwiftUI
import Combine
import GuevenCore

/// Musikwiedergabe: Warteschlangenlogik aus GuevenCore (`MusicQueueState`), Ton über `AppModel`/`PlayerManager`.
/// Apple-only, ungetestet.
@MainActor
final class MusicModel: ObservableObject {
    @Published private(set) var queue = MusicQueueState()
    @Published private(set) var sections: [MusicSection] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    private let app: AppModel
    private var rng = AnyRandom()
    private var endObserver: AnyCancellable?

    init(app: AppModel) {
        self.app = app
        endObserver = app.player.$state.removeDuplicates().sink { [weak self] state in
            if state == .ended { self?.trackEnded() }
        }
    }

    // MARK: Laden

    func loadHome() async {
        await load { try await self.musicCall("browse", [("browseId", .string("FEmusic_home"))]) }
    }

    func search(_ q: String) async {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await load { try await self.musicCall("search", [("query", .string(text))]) }
    }

    /// Album-, Playlist- oder Interpretenseite.
    func detail(_ browseId: String) async throws -> MusicDetail {
        MusicParser.parseDetail(try await musicCall("browse", [("browseId", .string(browseId))]))
    }

    private func load(_ call: () async throws -> JSON) async {
        loading = true; defer { loading = false }
        do {
            sections = MusicParser.parseSections(try await call()).sections
            error = sections.isEmpty ? "Keine Ergebnisse." : nil
        } catch { self.error = GTError.text(error) }
    }

    private func musicCall(_ endpoint: String, _ payload: [(String, JSON)]) async throws -> JSON {
        try await app.env.innerTube.music(endpoint, withAccount: false, payload: payload)
    }

    // MARK: Warteschlange

    func play(_ songs: [MusicSong], index: Int = 0) {
        let effect = queue.play(songs, index: index, using: &rng)
        run(effect)
    }

    func next() { run(queue.next(using: &rng)) }
    func previous() { run(queue.previous(positionMs: app.player.positionMs)) }
    func toggleShuffle() { queue.toggleShuffle(using: &rng) }
    func cycleRepeat() { queue.cycleRepeat() }

    private func trackEnded() {
        guard queue.current != nil else { return }
        run(queue.trackEnded(using: &rng))
    }

    private func run(_ e: MusicQueueEffect) {
        if let song = e.play { start(song) }
        else if e.restartCurrent { app.player.seek(toMs: 0); app.player.resume() }
        if let seed = e.refillSeed { Task { await refill(seed, startWhenLoaded: e.refillStartsPlayback) } }
        else if e.play != nil, queue.upcoming.count < MusicQueueState.refillBelow, let seed = queue.radioSeed {
            Task { await refill(seed, startWhenLoaded: false) }
        }
    }

    private func start(_ song: MusicSong) {
        let item = VideoItem(videoId: song.videoId, title: song.title, channelName: song.artists,
                             thumbnailUrl: song.thumbnailUrl ?? InnerTubeParser.fallbackThumbnail(song.videoId),
                             durationSeconds: song.durationSeconds)
        app.play(item, audioOnly: true, showPlayer: false)
    }

    /// Radio-Nachschub (`next` mit `RDAMVM<id>`, wie Android).
    private func refill(_ seed: String, startWhenLoaded: Bool) async {
        do {
            let json = try await musicCall("next", [("videoId", .string(seed)), ("playlistId", .string("RDAMVM\(seed)")),
                                                    ("isAudioOnly", .bool(true))])
            let songs = MusicParser.parseQueue(json).songs
            let result = queue.applyRadio(songs, startWhenLoaded: startWhenLoaded, using: &rng)
            if let song = result.effect.play { start(song) }
        } catch { self.error = GTError.text(error) }
    }
}
