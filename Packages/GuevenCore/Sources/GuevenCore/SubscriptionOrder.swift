import Foundation

public enum SubscriptionSort: String, Codable, Sendable, CaseIterable {
    /// Reihenfolge, die YouTube liefert.
    case youtube = "YOUTUBE"
    /// Zuletzt abonnierte Kanäle oben.
    case recentlySubscribed = "RECENTLY_SUBSCRIBED"
    case alphabetical = "ALPHABETICAL"

    public var label: String {
        switch self {
        case .youtube: return "Wie bei YouTube"
        case .recentlySubscribed: return "Zuletzt abonniert"
        case .alphabetical: return "A–Z"
        }
    }

    public func next() -> SubscriptionSort {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Sortiert die Kanalliste; bei Gleichstand bleibt die Reihenfolge von YouTube erhalten.
public func sortSubscribedChannels(_ channels: [SubscribedChannel], sort: SubscriptionSort, firstSeen: [String: Int64],
                                   locale: Locale = .current) -> [SubscribedChannel] {
    switch sort {
    case .youtube:
        return channels
    case .alphabetical:
        // Entspricht `Collator` mit Stärke PRIMARY: ohne Groß-/Kleinschreibung und Akzente.
        return channels.enumerated().sorted { a, b in
            let r = a.element.name.compare(b.element.name, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale)
            return r != .orderedSame ? r == .orderedAscending : a.offset < b.offset
        }.map(\.element)
    case .recentlySubscribed:
        return channels.enumerated().sorted { a, b in
            let ta = firstSeen[a.element.channelId] ?? 0, tb = firstSeen[b.element.channelId] ?? 0
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)
    }
}

public struct InvalidAccountKey: Error, Equatable {}

/// Merkt sich pro Konto, wann die App einen Kanal zum ersten Mal in der Aboliste gesehen hat. YouTube gibt das
/// Abo-Datum nicht heraus; für „Zuletzt abonniert“ zählt der erste Auftritt. Beim ersten Start vorhandene Abos
/// behalten untereinander die Reihenfolge von YouTube.
public actor SubscriptionDatesStore {
    private let directory: URL
    private let nowMs: @Sendable () -> Int64

    public init(directory: URL, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.directory = directory; self.nowMs = nowMs
    }

    /// Erster Auftritt je Kanal; nicht mehr abonnierte Kanäle werden dabei vergessen.
    public func firstSeen(accountKey: String, channelIds: [String], now: Int64? = nil) throws -> [String: Int64] {
        guard accountKey.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw InvalidAccountKey() }
        let now = now ?? nowMs()
        let file = directory.appendingPathComponent("\(accountKey).json")
        let known = read(file)
        var result: [String: Int64] = [:]
        for id in channelIds { result[id] = known[id] ?? now }
        if result != known { write(file, result) }
        return result
    }

    private func read(_ file: URL) -> [String: Int64] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]   // beschädigt: neu beginnen
    }

    private func write(_ file: URL, _ data: [String: Int64]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: file, options: .atomic)
        } catch { /* nicht speicherbar: nächster Aufruf versucht es erneut */ }
    }
}
