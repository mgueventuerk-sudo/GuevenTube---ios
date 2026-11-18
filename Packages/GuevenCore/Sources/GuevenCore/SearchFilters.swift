import Foundation

/// Suchfilter wie in der YouTube-Suche.
public struct SearchFilters: Equatable, Sendable {
    public enum Sort: Sendable { case relevance, date, views, rating
        var code: Int? { switch self { case .relevance: nil; case .date: 2; case .views: 3; case .rating: 1 } } }
    public enum UploadDate: Sendable { case any, hour, today, week, month, year
        var code: Int? { switch self { case .any: nil; case .hour: 1; case .today: 2; case .week: 3; case .month: 4; case .year: 5 } } }
    public enum Kind: Sendable { case any, video, channel, playlist
        var code: Int? { switch self { case .any: nil; case .video: 1; case .channel: 2; case .playlist: 3 } } }
    public enum Duration: Sendable { case any, short, medium, long
        var code: Int? { switch self { case .any: nil; case .short: 1; case .medium: 3; case .long: 2 } } }

    public var sort: Sort = .relevance
    public var date: UploadDate = .any
    public var type: Kind = .any
    public var duration: Duration = .any
    public var liveOnly = false

    public init(sort: Sort = .relevance, date: UploadDate = .any, type: Kind = .any, duration: Duration = .any, liveOnly: Bool = false) {
        self.sort = sort; self.date = date; self.type = type; self.duration = duration; self.liveOnly = liveOnly
    }

    public var isDefault: Bool { self == SearchFilters() }

    /// `params` der InnerTube-Suche: Protobuf `{1: Sortierung, 2: {1: Datum, 2: Typ, 3: Dauer, 8: Live}}`, Base64.
    public func toParams() -> String? {
        if isDefault { return nil }
        var filters: [UInt8] = []
        if let c = date.code { Self.varintField(1, c, &filters) }
        if let c = type.code { Self.varintField(2, c, &filters) }
        if let c = duration.code { Self.varintField(3, c, &filters) }
        if liveOnly { Self.varintField(8, 1, &filters) }
        var root: [UInt8] = []
        if let c = sort.code { Self.varintField(1, c, &root) }
        if !filters.isEmpty {
            root.append(UInt8((2 << 3) | 2))
            Self.writeVarint(filters.count, &root)
            root += filters
        }
        return Data(root).base64EncodedString()
    }

    private static func varintField(_ field: Int, _ value: Int, _ out: inout [UInt8]) {
        out.append(UInt8(field << 3))
        writeVarint(value, &out)
    }

    private static func writeVarint(_ value: Int, _ out: inout [UInt8]) {
        var v = value
        while v >= 0x80 { out.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        out.append(UInt8(v))
    }
}
