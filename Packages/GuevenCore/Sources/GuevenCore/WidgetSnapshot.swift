import Foundation

/// Daten des „Weiterschauen“-Widgets: die App schreibt sie, das Widget (eigener Prozess) liest sie.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let videoId: String
        public let title: String
        public let channelName: String?
        public init(videoId: String, title: String, channelName: String?) { self.videoId = videoId; self.title = title; self.channelName = channelName }
    }
    public static let maxEntries = 3
    public static let appGroup = "group.de.gueventube.app"
    public static let defaultsKey = "widget.snapshot"
    public static let widgetKind = "ContinueWatching"
    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    public init(continueWatching items: [VideoItem]) {
        self.init(entries: items.prefix(Self.maxEntries).map { Entry(videoId: $0.videoId, title: $0.title, channelName: $0.channelName) })
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Defekte oder fehlende Daten ergeben ein leeres Widget statt eines Fehlers.
    public static func decode(_ data: Data?) -> WidgetSnapshot {
        guard let data, let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot(entries: []) }
        return s
    }

    public func url(for entry: Entry) -> URL? {
        var c = URLComponents(); c.scheme = "gueventube"; c.host = "play"; c.queryItems = [URLQueryItem(name: "v", value: entry.videoId)]
        return c.url
    }
}
