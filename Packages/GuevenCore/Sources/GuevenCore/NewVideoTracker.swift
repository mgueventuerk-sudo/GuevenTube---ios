import Foundation

/// Erkennt neue Abo-Videos für Benachrichtigungen (Port der Logik aus `NewVideosWorker.kt`).
/// Der erste Lauf merkt sich nur den Stand, damit keine Flut alter Videos gemeldet wird.
public struct NewVideoTracker: Sendable {
    public static let maxSeen = 600
    public static let maxNotifications = 3
    static let keySeen = "newvideos.seen"
    static let separator = "\n"

    private let store: StringValueStore
    public init(store: StringValueStore) { self.store = store }

    /// Aktueller Feed zuerst (wird nie verdrängt, sonst käme beim nächsten Lauf dieselbe Meldung erneut), danach
    /// ältere IDs in bisheriger Reihenfolge, gekürzt auf [max].
    public static func nextSeen(_ currentIds: [String], _ seen: [String], max: Int = maxSeen) -> [String] {
        var result: [String] = []
        var present = Set<String>()
        for id in currentIds where present.insert(id).inserted { result.append(id) }
        for id in seen where present.insert(id).inserted { result.append(id) }
        return Array(result.prefix(max))
    }

    /// Verarbeitet den Feed und liefert die zu meldenden Videos (höchstens `maxNotifications`, neueste zuerst).
    /// Shorts fallen weg, doppelte IDs auch. Speichert den neuen Stand.
    public func process(_ feed: [VideoItem]) -> [VideoItem] {
        var seenIds = Set<String>()
        let videos = feed.filter { !$0.isShort && seenIds.insert($0.videoId).inserted }
        let stored = store.string(Self.keySeen)
        let previous = stored?.split(separator: Character(Self.separator), omittingEmptySubsequences: true).map(String.init)
        let known = previous.map(Set.init)
        let fresh = known.map { k in videos.filter { !k.contains($0.videoId) } } ?? []
        store.setString(Self.nextSeen(videos.map(\.videoId), previous ?? []).joined(separator: Self.separator), for: Self.keySeen)
        return Array(fresh.prefix(Self.maxNotifications))
    }
}
