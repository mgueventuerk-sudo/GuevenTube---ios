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
    /// Liedtext des laufenden Titels (`nil`: nicht geladen oder keiner vorhanden, siehe [lyricsState]).
    @Published private(set) var lyrics: MusicLyrics?
    enum LyricsState: Equatable { case idle, loading, loaded, none, failed }
    @Published private(set) var lyricsState: LyricsState = .idle
    private var lyricsVideoId: String?

    private let app: AppModel
    private var rng = AnyRandom()
    private var endObserver: AnyCancellable?

    /// Geliketen Titel (neueste zuerst) und ihre IDs für das Herz in Player und Listen.
    @Published private(set) var favorites: [MusicSong] = []
    @Published private(set) var favoriteIds: Set<String> = []
    private let library = AppEnvironment.shared.library

    func reloadFavorites() async {
        let items = await library.favoriteSongItems()
        favorites = items.map { MusicSong(videoId: $0.videoId, title: $0.title, artists: $0.channelName, album: nil,
                                          thumbnailUrl: $0.thumbnailUrl, durationSeconds: $0.durationSeconds) }
        favoriteIds = Set(items.map(\.videoId))
    }

    func isFavorite(_ song: MusicSong) -> Bool { favoriteIds.contains(song.videoId) }

    func toggleFavorite(_ song: MusicSong) {
        let liked = !favoriteIds.contains(song.videoId)
        // Sofort im UI, dann speichern.
        if liked { favoriteIds.insert(song.videoId) } else { favoriteIds.remove(song.videoId) }
        let video = VideoItem(videoId: song.videoId, title: song.title, channelName: song.artists,
                              thumbnailUrl: song.thumbnailUrl ?? InnerTubeParser.fallbackThumbnail(song.videoId), durationSeconds: song.durationSeconds)
        Task { await library.setFavoriteSong(video, liked: liked); await reloadFavorites() }
    }

    private var currentObserver: AnyCancellable?

    init(app: AppModel) {
        self.app = app
        Task { await reloadFavorites() }
        // Weiter/Zurück auf Sperrbildschirm und in der Kopfhörer-Steuerung nur, solange ein Musiktitel läuft.
        currentObserver = app.$current.sink { [weak self] item in
            guard let self else { return }
            let isMusic = item != nil && item?.videoId == self.queue.current?.videoId
            if isMusic {
                self.app.player.trackCommands = (next: { [weak self] in self?.next() }, previous: { [weak self] in self?.previous() })
            } else {
                self.app.player.trackCommands = nil
            }
        }
        endObserver = app.player.$state.removeDuplicates().sink { [weak self] state in
            if state == .ended { self?.trackEnded() }
        }
    }

    // MARK: Laden

    /// Suchfilter von YouTube Music (`params` wie in ytmusicapi); `nil`: alles.
    enum SearchFilter: String, CaseIterable, Identifiable {
        case all, songs, videos, albums, artists, playlists
        var id: String { rawValue }
        var title: String {
            switch self { case .all: "Alle"; case .songs: "Songs"; case .videos: "Videos"; case .albums: "Alben"; case .artists: "Interpreten"; case .playlists: "Playlists" }
        }
        var params: String? {
            let tail = "AWoMEA4QChADEAQQCRAF"
            switch self {
            case .all: return nil
            case .songs: return "EgWKAQII" + tail
            case .videos: return "EgWKAQIQ" + tail
            case .albums: return "EgWKAQIY" + tail
            case .artists: return "EgWKAQIg" + tail
            case .playlists: return "EgWKAQIo" + tail
            }
        }
    }

    @Published private(set) var continuation: String?
    @Published private(set) var loadingMore = false
    @Published var filter: SearchFilter = .all
    @Published private(set) var searchQuery = ""
    /// Jede neue Anfrage zählt hoch; Antworten älterer Anfragen werden verworfen.
    private var generation = 0
    private var continuationEndpoint = "search"

    func loadHome() async {
        searchQuery = ""
        await load(endpoint: "browse") { try await self.musicCall("browse", [("browseId", .string("FEmusic_home"))]) }
    }

    func search(_ q: String) async {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchQuery = text
        var payload: [(String, JSON)] = [("query", .string(text))]
        if let p = filter.params { payload.append(("params", .string(p))) }
        await load(endpoint: "search") { try await self.musicCall("search", payload) }
    }

    func setFilter(_ f: SearchFilter) async {
        guard f != filter else { return }
        filter = f
        if !searchQuery.isEmpty { await search(searchQuery) }
    }

    /// Weitere Treffer derselben Liste (Suche mit Filter, Startseite).
    func loadMore() async {
        guard let token = continuation, !loading, !loadingMore else { return }
        let gen = generation
        loadingMore = true; defer { if gen == generation { loadingMore = false } }
        do {
            let page = MusicParser.parseSections(try await musicCall(continuationEndpoint, [("continuation", .string(token))]))
            guard gen == generation else { return }
            var merged = sections
            var known = Set(merged.flatMap { $0.items.map(\.key) })
            for s in page.sections {
                let fresh = s.items.filter { known.insert($0.key).inserted }
                if fresh.isEmpty { continue }
                if s.title.isEmpty, let last = merged.indices.last { merged[last].items += fresh } else { merged.append(MusicSection(title: s.title, items: fresh)) }
            }
            sections = merged
            continuation = page.continuation == token ? nil : page.continuation
        } catch { guard gen == generation else { return }; continuation = nil }
    }

    /// Album-, Playlist- oder Interpretenseite.
    func detail(_ browseId: String) async throws -> MusicDetail {
        MusicParser.parseDetail(try await musicCall("browse", [("browseId", .string(browseId))]))
    }

    private func load(endpoint: String, _ call: () async throws -> JSON) async {
        generation += 1; let gen = generation; continuationEndpoint = endpoint; continuation = nil
        loadingMore = false // ein verworfenes Nachladen darf den Spinner nicht dauerhaft stehen lassen
        loading = true; defer { if gen == generation { loading = false } }
        do {
            let page = MusicParser.parseSections(try await call())
            guard gen == generation else { return }
            sections = page.sections; continuation = page.continuation
            error = sections.isEmpty ? "Keine Ergebnisse." : nil
        } catch { guard gen == generation else { return }; self.error = GTError.text(error) }
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

    /// „Als Nächstes spielen“: reiht vor den kommenden Titeln ein; ohne laufende Musik startet der Titel sofort.
    func playNext(_ song: MusicSong) { run(queue.playNext(song, using: &rng)) }
    func jumpToQueue(_ index: Int) { run(queue.jumpTo(index)) }
    func removeFromQueue(at index: Int) { queue.remove(at: index) }
    /// Ziehen in der Liste (`onMove`): [destination] ist die Einfügeposition vor dem Entfernen.
    func moveInQueue(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        queue.move(from: from, to: destination > from ? destination - 1 : destination)
    }

    /// Lädt den Liedtext des laufenden Titels (einmal je Titel; `retry` erzwingt einen neuen Versuch nach einem Fehler).
    func loadLyrics(retry: Bool = false) async {
        guard let song = queue.current else { return }
        if lyricsVideoId == song.videoId, lyricsState != .idle, !(retry && lyricsState == .failed) { return }
        lyricsVideoId = song.videoId; lyrics = nil; lyricsState = .loading
        do {
            let json = try await musicCall("next", [("videoId", .string(song.videoId)), ("playlistId", .string("RDAMVM\(song.videoId)")),
                                                    ("isAudioOnly", .bool(true))])
            guard let browseId = MusicParser.parseQueue(json).lyricsBrowseId else { finishLyrics(song.videoId, nil, .none); return }
            let page = try await musicCall("browse", [("browseId", .string(browseId))])
            if let text = MusicParser.parseLyrics(page) { finishLyrics(song.videoId, text, .loaded) } else { finishLyrics(song.videoId, nil, .none) }
        } catch {
            // Player-Fenster geschlossen (Task abgebrochen): kein Fehler, beim nächsten Öffnen neu laden.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if lyricsVideoId == song.videoId { lyricsVideoId = nil; lyricsState = .idle; lyrics = nil }
            } else { finishLyrics(song.videoId, nil, .failed) }
        }
    }

    private func finishLyrics(_ videoId: String, _ text: MusicLyrics?, _ state: LyricsState) {
        guard lyricsVideoId == videoId else { return } // inzwischen anderer Titel
        lyrics = text; lyricsState = state
    }

    private func trackEnded() {
        // Nur reagieren, wenn der beendete Titel wirklich der Musiktitel ist (nicht ein später gestartetes Video).
        guard let cur = queue.current, app.current?.videoId == cur.videoId else { return }
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
