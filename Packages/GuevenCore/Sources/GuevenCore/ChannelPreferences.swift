import Foundation

/// Gemerkte Einstellungen eines Kanals, z. B. Podcasts immer mit 1,5×.
public struct ChannelPrefs: Equatable, Sendable {
    public var speed: Float?
    /// Höchste Auflösung (Zeilen), `nil` = automatisch.
    public var maxHeight: Int?
    public init(speed: Float? = nil, maxHeight: Int? = nil) { self.speed = speed; self.maxHeight = maxHeight }
}

/// Einfache Ablage eines Textwerts (iOS: UserDefaults).
public protocol StringValueStore: Sendable {
    func string(_ key: String) -> String?
    func setString(_ value: String, for key: String)
}

public final class InMemoryStringStore: StringValueStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    public init() {}
    public func string(_ key: String) -> String? { lock.withLock { values[key] } }
    public func setString(_ value: String, for key: String) { lock.withLock { values[key] = value } }
}

public final class ChannelPreferences: @unchecked Sendable {
    static let key = "channels"
    static let maxChannels = 300
    private let store: StringValueStore
    private let lock = NSLock()
    private var cache: [(id: String, prefs: ChannelPrefs)]?

    public init(store: StringValueStore) { self.store = store }

    public func get(_ channelId: String?) -> ChannelPrefs? {
        guard let channelId else { return nil }
        return lock.withLock { load().first { $0.id == channelId }?.prefs }
    }

    /// Leere Einstellungen entfernen den Kanal. Begrenzt auf 300 Kanäle (die zuletzt hinzugekommenen bleiben).
    public func update(_ channelId: String, _ transform: (ChannelPrefs) -> ChannelPrefs?) {
        lock.withLock {
            var all = load()
            let index = all.firstIndex { $0.id == channelId }
            let updated = transform(index.map { all[$0].prefs } ?? ChannelPrefs())
            if let updated, updated != ChannelPrefs() {
                if let index { all[index].prefs = updated } else { all.append((channelId, updated)) }   // Position bleibt (wie LinkedHashMap)
            } else if let index { all.remove(at: index) }
            if all.count > Self.maxChannels { all = Array(all.suffix(Self.maxChannels)) }
            store.setString(Self.encode(all), for: Self.key)
            cache = all
        }
    }

    public func clear() { lock.withLock { store.setString("{}", for: Self.key); cache = [] } }

    private func load() -> [(id: String, prefs: ChannelPrefs)] {
        if let cache { return cache }
        var result: [(String, ChannelPrefs)] = []
        if let raw = store.string(Self.key), let root = try? JSONParser.parse(raw), let object = root.objectValue {
            for (id, value) in object.entries where value.objectValue != nil {
                result.append((id, ChannelPrefs(speed: value.double("speed").map(Float.init), maxHeight: value.int("maxHeight"))))
            }
        }
        cache = result
        return result
    }

    private static func encode(_ all: [(id: String, prefs: ChannelPrefs)]) -> String {
        JSON.obj(all.map { entry in
            var fields: [(String, JSON)] = []
            if let s = entry.prefs.speed { fields.append(("speed", .number("\(s)"))) }
            if let h = entry.prefs.maxHeight { fields.append(("maxHeight", .number("\(h)"))) }
            return (entry.id, .obj(fields))
        }).serialized()
    }
}
