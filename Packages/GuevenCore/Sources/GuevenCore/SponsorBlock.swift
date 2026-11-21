import Foundation

public enum SkipMode: String, Codable, Sendable, CaseIterable {
    case autoSkip = "AUTO_SKIP", manualSkip = "MANUAL_SKIP", showInSeekbar = "SHOW_IN_SEEKBAR", disabled = "DISABLED"

    public var displayName: String {
        switch self {
        case .autoSkip: return "Automatisch überspringen"
        case .manualSkip: return "Überspringen-Knopf anzeigen"
        case .showInSeekbar: return "Nur in der Zeitleiste markieren"
        case .disabled: return "Deaktiviert"
        }
    }
}

/// SponsorBlock-Kategorien mit Seekbar-Farben (Grün = Sponsor, Cyan = Intro, Blau = Interaktion).
public enum SponsorCategory: String, Codable, Sendable, CaseIterable {
    case sponsor, intro, outro, selfpromo, interaction, music_offtopic, preview, filler

    public var apiKey: String { rawValue }

    public var displayName: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .intro: return "Intro"
        case .outro: return "Abspann"
        case .selfpromo: return "Eigenwerbung"
        case .interaction: return "Interaktionserinnerung"
        case .music_offtopic: return "Musik: Nicht-Musik-Teil"
        case .preview: return "Vorschau/Rückblick"
        case .filler: return "Füllmaterial"
        }
    }

    /// ARGB wie in Android.
    public var colorArgb: UInt32 {
        switch self {
        case .sponsor: return 0xFF00D400
        case .intro: return 0xFF00FFFF
        case .outro: return 0xFF8E24AA
        case .selfpromo: return 0xFFFFFF00
        case .interaction: return 0xFF2979FF
        case .music_offtopic: return 0xFFFF9900
        case .preview: return 0xFF008FD6
        case .filler: return 0xFF7300FF
        }
    }

    public var defaultMode: SkipMode {
        switch self {
        case .sponsor: return .autoSkip
        case .intro, .outro, .preview: return .showInSeekbar
        case .selfpromo, .interaction, .music_offtopic: return .manualSkip
        case .filler: return .disabled
        }
    }

    public static func fromApiKey(_ key: String) -> SponsorCategory? { SponsorCategory(rawValue: key) }
}

public struct SponsorSegment: Codable, Equatable, Hashable, Sendable {
    public var uuid: String
    public var category: SponsorCategory
    public var startMs: Int64
    public var endMs: Int64
    public init(uuid: String, category: SponsorCategory, startMs: Int64, endMs: Int64) {
        self.uuid = uuid; self.category = category; self.startMs = startMs; self.endMs = endMs
    }
}

/// Speicher für abgerufene Segmente (auf dem iPhone später SwiftData, hier austauschbar).
public protocol SponsorSegmentCache: Sendable {
    func get(_ videoId: String) async -> (segmentsJson: String, fetchedAt: Int64)?
    func put(_ videoId: String, segmentsJson: String, fetchedAt: Int64) async
    func deleteOlderThan(_ ms: Int64) async
}

public actor InMemorySponsorCache: SponsorSegmentCache {
    private var entries: [String: (segmentsJson: String, fetchedAt: Int64)] = [:]
    public init() {}
    public func get(_ videoId: String) -> (segmentsJson: String, fetchedAt: Int64)? { entries[videoId] }
    public func put(_ videoId: String, segmentsJson: String, fetchedAt: Int64) { entries[videoId] = (segmentsJson, fetchedAt) }
    public func deleteOlderThan(_ ms: Int64) { entries = entries.filter { $0.value.fetchedAt >= ms } }
}

public struct SponsorBlockHTTPError: Error, Equatable { public let code: Int }

/// SponsorBlock-Segmente mit k-Anonymität: Gesendet werden nur die ersten 4 Hex-Zeichen des SHA-256 der
/// Video-ID (`/api/skipSegments/{prefix}`); die passende Video-ID wird lokal herausgefiltert. Ergebnisse (alle
/// Kategorien) liegen 30 Minuten im Cache, Einstellungsänderungen brauchen daher keinen neuen Abruf.
public actor SponsorBlockClient {
    public static let apiBase = "https://sponsor.ajay.app"
    public static let userAgent = "GuevenTube/1.2 (iOS)"
    public static let cacheTtlMs: Int64 = 30 * 60 * 1000
    public static let cacheRetentionMs: Int64 = 24 * 60 * 60 * 1000
    static let hashPrefixLength = 4

    private let transport: HTTPTransport
    private let cache: SponsorSegmentCache
    private let nowMs: @Sendable () -> Int64
    private var highlights = LRUCache<Int64>(capacity: 32)
    private var noHighlight = LRUCache<Bool>(capacity: 64)

    public init(transport: HTTPTransport, cache: SponsorSegmentCache = InMemorySponsorCache(),
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport; self.cache = cache; self.nowMs = nowMs
    }

    /// SHA-256 der Video-ID als Hex (Kleinbuchstaben), gekürzt auf die ersten 4 Zeichen.
    public static func sha256Prefix(_ videoId: String) -> String { String(SHA256Hash.hex(videoId).prefix(hashPrefixLength)) }

    /// Segmente für [videoId], gefiltert auf [categories] und nach Startzeit sortiert.
    public func segments(_ videoId: String, categories: Set<SponsorCategory>) async throws -> [SponsorSegment] {
        if categories.isEmpty { return [] }
        return try await allSegments(videoId).filter { categories.contains($0.category) }.sorted { $0.startMs < $1.startMs }
    }

    private func allSegments(_ videoId: String) async throws -> [SponsorSegment] {
        let now = nowMs()
        let cached = await cache.get(videoId)
        if let cached, now - cached.fetchedAt < Self.cacheTtlMs, let decoded = Self.decode(cached.segmentsJson) { return decoded }
        do {
            let fresh = try await fetch(videoId)
            if let data = try? JSONEncoder().encode(fresh) {
                await cache.put(videoId, segmentsJson: String(decoding: data, as: UTF8.self), fetchedAt: now)
            }
            await cache.deleteOlderThan(now - Self.cacheRetentionMs)
            return fresh
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Nicht erreichbar: lieber veraltete Segmente als keine.
            return cached.flatMap { Self.decode($0.segmentsJson) } ?? []
        }
    }

    private struct VideoDto: Decodable {
        let videoID: String
        let segments: [SegmentDto]?
    }
    private struct SegmentDto: Decodable {
        let category: String
        let actionType: String?
        let segment: [Double]
        let UUID: String
    }

    private func request(_ videoId: String, categories: String, actionTypes: String) -> HTTPRequest {
        var components = URLComponents(string: "\(Self.apiBase)/api/skipSegments/\(Self.sha256Prefix(videoId))")!
        components.queryItems = [URLQueryItem(name: "categories", value: categories), URLQueryItem(name: "actionTypes", value: actionTypes)]
        return HTTPRequest(url: components.url!, headers: ["User-Agent": Self.userAgent])
    }

    private func fetch(_ videoId: String) async throws -> [SponsorSegment] {
        let categories = "[" + SponsorCategory.allCases.map { "\"\($0.apiKey)\"" }.joined(separator: ",") + "]"
        let response = try await transport.send(request(videoId, categories: categories, actionTypes: "[\"skip\"]"))
        if response.code == 404 { return [] }
        guard response.isSuccessful else { throw SponsorBlockHTTPError(code: response.code) }
        let videos = try JSONDecoder().decode([VideoDto].self, from: response.body)
        guard let match = videos.first(where: { $0.videoID == videoId }) else { return [] }
        return (match.segments ?? []).compactMap { dto in
            guard (dto.actionType ?? "skip") == "skip", dto.segment.count >= 2, let category = SponsorCategory.fromApiKey(dto.category) else { return nil }
            guard let start = Self.ms(dto.segment[0]), let end = Self.ms(dto.segment[1]) else { return nil }
            guard end > start else { return nil }
            return SponsorSegment(uuid: dto.UUID, category: category, startMs: start, endMs: end)
        }
    }

    /// Höhepunkt eines Videos (Kategorie „poi_highlight“) in ms oder `nil`. Fehlschläge werden – anders als
    /// auf Android – nicht als „kein Höhepunkt“ gemerkt, damit ein Netzaussetzer ihn nicht für die Sitzung unterdrückt.
    public func highlight(_ videoId: String) async throws -> Int64? {
        if let hit = highlights.get(videoId) { return hit }
        if noHighlight.get(videoId) == true { return nil }
        let response: HTTPResponse
        do {
            response = try await transport.send(request(videoId, categories: "[\"poi_highlight\"]", actionTypes: "[\"poi\"]"))
        } catch is CancellationError {
            throw CancellationError()
        } catch { return nil }
        guard response.isSuccessful || response.code == 404 else { return nil }
        var result: Int64?
        if response.isSuccessful, let videos = try? JSONDecoder().decode([VideoDto].self, from: response.body) {
            result = videos.first(where: { $0.videoID == videoId })?.segments?
                .first(where: { $0.category == "poi_highlight" && !$0.segment.isEmpty }).flatMap { Self.ms($0.segment[0]) }
        }
        if let result { highlights.put(videoId, result) } else { noHighlight.put(videoId, true) }
        return result
    }

    /// Sekunden → ms; `nil` bei unsinnigen Werten (negativ, NaN, riesig), die `Int64(_:)` sonst zum Absturz brächten.
    static func ms(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { return nil }
        return Int64(seconds * 1000)
    }

    private static func decode(_ json: String) -> [SponsorSegment]? { try? JSONDecoder().decode([SponsorSegment].self, from: Data(json.utf8)) }
}
