import Foundation

/// Crowdsourcing-Titel/-Vorschaubild; `nil`-Felder bedeuten: Original verwenden.
public struct Branding: Equatable, Codable, Sendable {
    public var title: String?
    public var thumbnailUrl: String?
    public init(title: String?, thumbnailUrl: String?) { self.title = title; self.thumbnailUrl = thumbnailUrl }
    public static let original = Branding(title: nil, thumbnailUrl: nil)
}

/// Dauerhafter Zwischenspeicher (auf dem iPhone später SwiftData).
public protocol BrandingDiskCache: Sendable {
    /// Eintrag, der nicht älter als `newerThan` ist.
    func get(_ videoId: String, newerThan: Int64) async -> Branding?
    func put(_ videoId: String, _ branding: Branding, at: Int64) async
    func deleteOlderThan(_ ms: Int64) async
}

public actor InMemoryBrandingCache: BrandingDiskCache {
    private var entries: [String: (Branding, Int64)] = [:]
    public init() {}
    public func get(_ videoId: String, newerThan: Int64) -> Branding? {
        guard let (b, at) = entries[videoId], at >= newerThan else { return nil }
        return b
    }
    public func put(_ videoId: String, _ branding: Branding, at: Int64) { entries[videoId] = (branding, at) }
    public func deleteOlderThan(_ ms: Int64) { entries = entries.filter { $0.value.1 >= ms } }
    public var count: Int { entries.count }
}

/// Begrenzt gleichzeitige Anfragen (FIFO-Warteschlange).
actor AsyncLimiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ permits: Int) { free = permits }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// DeArrow (Anti-Clickbait): `/api/branding?videoID=…` liefert Community-Titel und Zeitstempel für ungespoilerte
/// Vorschaubilder. Gibt es keinen Eintrag (HTTP 404) oder ist der Dienst nicht erreichbar, bleibt es beim
/// Original. Abweichung von Android: ein Netzfehler wird nicht gespeichert (dort hielt er 24 h auf der Platte vor).
public actor DeArrowClient {
    public static let apiBase = "https://sponsor.ajay.app"
    public static let thumbnailBase = "https://dearrow-thumb.ajay.app"
    public static let userAgent = "GuevenTube/1.2 (iOS)"
    public static let diskTtlMs: Int64 = 24 * 60 * 60 * 1000
    static let cacheSize = 512
    static let maxParallel = 4
    static let pruneEveryWrites = 200

    private let transport: HTTPTransport
    private let disk: BrandingDiskCache
    private let nowMs: @Sendable () -> Int64
    private var ram = LRUCache<Branding>(capacity: DeArrowClient.cacheSize)
    private let limiter = AsyncLimiter(DeArrowClient.maxParallel)
    private var writesSincePrune = 0

    public init(transport: HTTPTransport, disk: BrandingDiskCache = InMemoryBrandingCache(),
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport; self.disk = disk; self.nowMs = nowMs
    }

    /// Zwischengespeichertes Ergebnis ohne Netzzugriff (für sofortige Darstellung).
    public func cached(_ videoId: String) -> Branding? { ram.get(videoId) }

    /// RAM → Platte (24 h) → Netz.
    public func branding(_ videoId: String) async throws -> Branding {
        if let hit = ram.get(videoId) { return hit }
        let now = nowMs()
        if let stored = await disk.get(videoId, newerThan: now - Self.diskTtlMs) { ram.put(videoId, stored); return stored }
        await limiter.acquire()
        let outcome: Branding?
        do {
            if let hit = ram.get(videoId) { await limiter.release(); return hit }
            outcome = try await fetch(videoId)
        } catch {
            await limiter.release()
            throw error
        }
        await limiter.release()
        guard let result = outcome else { return .original }   // Fehler: nicht merken
        ram.put(videoId, result)
        await disk.put(videoId, result, at: now)
        writesSincePrune += 1
        if writesSincePrune >= Self.pruneEveryWrites {
            writesSincePrune = 0
            await disk.deleteOlderThan(now - Self.diskTtlMs)
        }
        return result
    }

    private struct BrandingDto: Decodable {
        struct Title: Decodable { let title: String; let original: Bool?; let votes: Int?; let locked: Bool? }
        struct Thumb: Decodable { let timestamp: Double?; let original: Bool?; let votes: Int?; let locked: Bool? }
        let titles: [Title]?
        let thumbnails: [Thumb]?
    }

    /// `nil` = Fehler (nicht speichern), sonst Ergebnis (auch „kein Eintrag“).
    private func fetch(_ videoId: String) async throws -> Branding? {
        var components = URLComponents(string: "\(Self.apiBase)/api/branding")!
        components.queryItems = [URLQueryItem(name: "videoID", value: videoId)]
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: components.url!, headers: ["User-Agent": Self.userAgent]))
        } catch is CancellationError {
            throw CancellationError()
        } catch { return nil }
        if response.code == 404 { return .original }
        guard response.isSuccessful else { return nil }
        return parse(videoId, response.body)
    }

    func parse(_ videoId: String, _ body: Data) -> Branding {
        guard let dto = try? JSONDecoder().decode(BrandingDto.self, from: body) else { return .original }
        func usable(_ locked: Bool?, _ votes: Int?, _ original: Bool?) -> Bool { ((locked ?? false) || (votes ?? 0) >= 0) && !(original ?? false) }
        var title = dto.titles?.first { usable($0.locked, $0.votes, $0.original) }?.title
        if title?.hasPrefix(">") == true { title?.removeFirst() }
        title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { title = nil }
        let time = dto.thumbnails?.first { usable($0.locked, $0.votes, $0.original) && $0.timestamp != nil }?.timestamp
        var thumbnailUrl: String?
        if let time {
            var c = URLComponents(string: "\(Self.thumbnailBase)/api/v1/getThumbnail")!
            c.queryItems = [URLQueryItem(name: "videoID", value: videoId), URLQueryItem(name: "time", value: "\(time)")]
            thumbnailUrl = c.url?.absoluteString
        }
        return Branding(title: title, thumbnailUrl: thumbnailUrl)
    }
}
