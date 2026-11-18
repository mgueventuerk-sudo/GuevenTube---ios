import Foundation

/// Wiedergabefortschritt für „Weitersehen“ – auch im Gast-Modus.
public struct WatchProgressEntry: Codable, Equatable, Sendable {
    public var videoId: String
    public var positionMs: Int64
    public var durationMs: Int64
    public var updatedAt: Int64
    public var title: String?
    public var channelName: String?
    public var thumbnailUrl: String?
    public init(videoId: String, positionMs: Int64, durationMs: Int64, updatedAt: Int64, title: String? = nil, channelName: String? = nil, thumbnailUrl: String? = nil) {
        self.videoId = videoId; self.positionMs = positionMs; self.durationMs = durationMs; self.updatedAt = updatedAt
        self.title = title; self.channelName = channelName; self.thumbnailUrl = thumbnailUrl
    }
}

public struct LocalPlaylist: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var createdAt: Int64
}

public struct LocalPlaylistWithCount: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var createdAt: Int64
    public var itemCount: Int
}

public struct LocalPlaylistItem: Codable, Equatable, Sendable {
    public var playlistId: Int64
    public var videoId: String
    public var title: String
    public var channelName: String?
    public var thumbnailUrl: String
    public var durationSeconds: Int64?
    public var addedAt: Int64
}

/// Lokales Kanal-Abo für Nutzer ohne Google-Konto.
public struct LocalSubscription: Codable, Equatable, Sendable {
    public var channelId: String
    public var name: String
    public var avatarUrl: String?
    public var subscribedAt: Int64
}

public struct SearchHistoryEntry: Codable, Equatable, Sendable {
    public var query: String
    public var searchedAt: Int64
}

public struct DuplicatePlaylistName: Error, Equatable {}

/// Lokale Bibliothek (Weitersehen, „Später ansehen“, Merklisten, lokale Abos, Suchverlauf) in einer kleinen JSON-Datei.
/// Ersetzt auf dem iPhone die Room-Datenbank: die Datenmengen sind klein (Hunderte Einträge), eine Datei ist einfacher,
/// atomar und unter Linux testbar. Beschädigte Dateien beginnen leer, statt die App zu blockieren.
public actor LocalLibrary {
    public static let watchLater = "Später ansehen"
    static let minResumePositionMs: Int64 = 30_000
    static let finishedPercent: Int64 = 95
    static let maxProgressEntries = 500
    static let pruneEverySaves = 50
    static let maxSearchHistory = 30

    private struct Snapshot: Codable {
        var progress: [WatchProgressEntry] = []
        var playlists: [LocalPlaylist] = []
        var items: [LocalPlaylistItem] = []
        var subscriptions: [LocalSubscription] = []
        var searches: [SearchHistoryEntry] = []
        var nextPlaylistId: Int64 = 1
    }

    private let file: URL?
    private let nowMs: @Sendable () -> Int64
    private var data: Snapshot
    private var savesSincePrune = 0
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// [file] = `nil` hält alles nur im Speicher (Tests, Vorschau).
    public init(file: URL? = nil, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.file = file; self.nowMs = nowMs
        if let file, let raw = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Snapshot.self, from: raw) { data = decoded }
        else { data = Snapshot() }
    }

    /// Meldet jede Änderung (Oberflächen laden dann neu).
    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func commit() {
        if let file {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(data).write(to: file, options: .atomic)
            } catch { /* nicht speicherbar: Zustand bleibt im Speicher, nächste Änderung versucht es erneut */ }
        }
        listeners.values.forEach { $0.yield() }
    }

    // MARK: Fortschritt

    /// „Weitersehen“: angefangen (mindestens 30 s) und noch nicht zu Ende geschaut (unter 95 %), neueste zuerst.
    public func continueWatching(limit: Int = 20) -> [VideoItem] {
        sortedByRecency(data.progress).filter { e in
            e.positionMs >= Self.minResumePositionMs && (e.durationMs <= 0 || e.positionMs < e.durationMs * Self.finishedPercent / 100)
        }.prefix(limit).map { e in
            VideoItem(videoId: e.videoId, title: e.title ?? e.videoId, channelName: e.channelName, channelId: nil,
                      thumbnailUrl: e.thumbnailUrl ?? "https://i.ytimg.com/vi/\(e.videoId)/hqdefault.jpg",
                      durationSeconds: e.durationMs > 0 ? e.durationMs / 1000 : nil, viewCountText: nil, publishedText: nil, isLive: false)
        }
    }

    /// Angesehener Anteil je Video (0…1), nur für Videos mit bekannter Dauer.
    public func progressMap() -> [String: Float] {
        var map: [String: Float] = [:]
        for e in data.progress where e.durationMs > 0 && e.positionMs >= Self.minResumePositionMs {
            map[e.videoId] = min(max(Float(e.positionMs) / Float(e.durationMs), 0), 1)
        }
        return map
    }

    /// Startposition zum Fortsetzen; `0`, wenn kaum angesehen oder fast zu Ende.
    public func resumePositionMs(_ videoId: String) -> Int64 {
        guard let e = data.progress.first(where: { $0.videoId == videoId }), e.positionMs >= Self.minResumePositionMs else { return 0 }
        if e.durationMs > 0 && Double(e.positionMs) >= Double(e.durationMs) * 0.95 { return 0 }
        return e.positionMs
    }

    public func saveProgress(videoId: String, positionMs: Int64, durationMs: Int64, title: String?, channelName: String?, thumbnailUrl: String?) {
        upsertProgress(WatchProgressEntry(videoId: videoId, positionMs: max(positionMs, 0), durationMs: max(durationMs, 0), updatedAt: nowMs(),
                                          title: title, channelName: channelName, thumbnailUrl: thumbnailUrl))
        savesSincePrune += 1
        if savesSincePrune >= Self.pruneEverySaves { savesSincePrune = 0; prune() }
        commit()
    }

    public func removeProgress(_ videoId: String) { data.progress.removeAll { $0.videoId == videoId }; commit() }
    public func clearProgress() { data.progress = []; commit() }

    /// Neueste Einträge für den Abgleich mit dem gekoppelten Gerät.
    public func recentProgress(limit: Int) -> [WatchProgressEntry] { Array(sortedByRecency(data.progress).prefix(limit)) }

    /// Übernimmt fremde Einträge, wenn sie neuer sind als die eigenen; liefert die Anzahl übernommener.
    @discardableResult
    public func mergeProgress(_ entries: [WatchProgressEntry]) -> Int {
        var merged = 0
        for var entry in entries {
            if let own = data.progress.first(where: { $0.videoId == entry.videoId }), own.updatedAt >= entry.updatedAt { continue }
            entry.positionMs = max(entry.positionMs, 0); entry.durationMs = max(entry.durationMs, 0)
            upsertProgress(entry); merged += 1
        }
        if merged > 0 { commit() }
        return merged
    }

    private func upsertProgress(_ entry: WatchProgressEntry) {
        if let i = data.progress.firstIndex(where: { $0.videoId == entry.videoId }) { data.progress[i] = entry } else { data.progress.append(entry) }
    }

    private func prune() {
        if data.progress.count > Self.maxProgressEntries { data.progress = Array(sortedByRecency(data.progress).prefix(Self.maxProgressEntries)) }
    }

    private func sortedByRecency(_ list: [WatchProgressEntry]) -> [WatchProgressEntry] {
        list.enumerated().sorted { $0.element.updatedAt != $1.element.updatedAt ? $0.element.updatedAt > $1.element.updatedAt : $0.offset > $1.offset }.map(\.element)
    }

    // MARK: Lokale Abos

    /// Nach Name sortiert, Groß-/Kleinschreibung egal.
    public func subscriptions() -> [LocalSubscription] {
        data.subscriptions.enumerated().sorted {
            let r = $0.element.name.compare($1.element.name, options: .caseInsensitive)
            return r != .orderedSame ? r == .orderedAscending : $0.offset < $1.offset
        }.map(\.element)
    }
    public func isSubscribed(_ channelId: String) -> Bool { data.subscriptions.contains { $0.channelId == channelId } }
    public func subscribedChannelIds() -> Set<String> { Set(data.subscriptions.map(\.channelId)) }

    public func subscribe(channelId: String, name: String, avatarUrl: String?) {
        let sub = LocalSubscription(channelId: channelId, name: name, avatarUrl: avatarUrl, subscribedAt: nowMs())
        if let i = data.subscriptions.firstIndex(where: { $0.channelId == channelId }) { data.subscriptions[i] = sub } else { data.subscriptions.append(sub) }
        commit()
    }
    public func unsubscribe(_ channelId: String) { data.subscriptions.removeAll { $0.channelId == channelId }; commit() }

    // MARK: Merklisten

    public func playlists() -> [LocalPlaylistWithCount] {
        data.playlists.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }.map { p in
            LocalPlaylistWithCount(id: p.id, name: p.name, createdAt: p.createdAt, itemCount: data.items.filter { $0.playlistId == p.id }.count)
        }
    }

    /// ID der Liste [name]; legt sie bei Bedarf an.
    @discardableResult
    public func playlistId(named name: String) -> Int64 {
        if let p = data.playlists.first(where: { $0.name == name }) { return p.id }
        let p = LocalPlaylist(id: data.nextPlaylistId, name: name, createdAt: nowMs())
        data.nextPlaylistId += 1
        data.playlists.append(p)
        commit()
        return p.id
    }

    public func renamePlaylist(_ id: Int64, to name: String) throws {
        if data.playlists.contains(where: { $0.name == name && $0.id != id }) { throw DuplicatePlaylistName() }
        if let i = data.playlists.firstIndex(where: { $0.id == id }) { data.playlists[i].name = name; commit() }
    }

    /// Löscht die Liste samt Einträgen.
    public func deletePlaylist(_ id: Int64) {
        data.playlists.removeAll { $0.id == id }
        data.items.removeAll { $0.playlistId == id }
        commit()
    }

    public func items(in playlistId: Int64) -> [LocalPlaylistItem] {
        data.items.enumerated().filter { $0.element.playlistId == playlistId }
            .sorted { $0.element.addedAt != $1.element.addedAt ? $0.element.addedAt > $1.element.addedAt : $0.offset > $1.offset }.map(\.element)
    }

    public func add(_ video: VideoItem, to playlistId: Int64) {
        let item = LocalPlaylistItem(playlistId: playlistId, videoId: video.videoId, title: video.title, channelName: video.channelName,
                                     thumbnailUrl: video.thumbnailUrl, durationSeconds: video.durationSeconds, addedAt: nowMs())
        if let i = data.items.firstIndex(where: { $0.playlistId == playlistId && $0.videoId == video.videoId }) { data.items[i] = item } else { data.items.append(item) }
        commit()
    }

    public func remove(videoId: String, from playlistId: Int64) {
        data.items.removeAll { $0.playlistId == playlistId && $0.videoId == videoId }
        commit()
    }

    public func contains(videoId: String, in playlistId: Int64) -> Bool { data.items.contains { $0.playlistId == playlistId && $0.videoId == videoId } }

    public func watchLaterItems() -> [VideoItem] {
        items(in: playlistId(named: Self.watchLater)).map { i in
            VideoItem(videoId: i.videoId, title: i.title, channelName: i.channelName, channelId: nil, thumbnailUrl: i.thumbnailUrl,
                      durationSeconds: i.durationSeconds, viewCountText: nil, publishedText: nil, isLive: false)
        }
    }
    public func isInWatchLater(_ videoId: String) -> Bool { contains(videoId: videoId, in: playlistId(named: Self.watchLater)) }
    public func addToWatchLater(_ video: VideoItem) { add(video, to: playlistId(named: Self.watchLater)) }
    public func removeFromWatchLater(_ videoId: String) { remove(videoId: videoId, from: playlistId(named: Self.watchLater)) }

    // MARK: Suchverlauf

    public func recentSearches(limit: Int = 12) -> [String] {
        data.searches.enumerated().sorted { $0.element.searchedAt != $1.element.searchedAt ? $0.element.searchedAt > $1.element.searchedAt : $0.offset > $1.offset }
            .prefix(limit).map(\.element.query)
    }

    public func addSearch(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let entry = SearchHistoryEntry(query: normalized, searchedAt: nowMs())
        if let i = data.searches.firstIndex(where: { $0.query == normalized }) { data.searches[i] = entry } else { data.searches.append(entry) }
        if data.searches.count > Self.maxSearchHistory {
            data.searches = Array(data.searches.enumerated().sorted { $0.element.searchedAt != $1.element.searchedAt ? $0.element.searchedAt > $1.element.searchedAt : $0.offset > $1.offset }
                .prefix(Self.maxSearchHistory).map(\.element))
        }
        commit()
    }
    public func clearSearches() { data.searches = []; commit() }
}
