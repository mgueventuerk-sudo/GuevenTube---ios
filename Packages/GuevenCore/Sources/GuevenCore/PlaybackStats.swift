import Foundation

/// Eine Wiedergabe-Sitzung (ein gestartetes Video). Enthält keine Titel, URLs oder Konten.
public struct PlaybackSession: Codable, Equatable, Sendable {
    public var atMs: Int64
    public var route: String?
    /// Zeit vom Antippen bis zum ersten Bild; `nil` = nie gestartet.
    public var startupMs: Int64?
    public var rebuffers: Int
    public var rebufferMs: Int64
    public var watchedMs: Int64
    public var error: String?

    public init(atMs: Int64, route: String? = nil, startupMs: Int64? = nil, rebuffers: Int = 0, rebufferMs: Int64 = 0,
                watchedMs: Int64 = 0, error: String? = nil) {
        self.atMs = atMs; self.route = route; self.startupMs = startupMs; self.rebuffers = rebuffers
        self.rebufferMs = rebufferMs; self.watchedMs = watchedMs; self.error = error
    }

    // Fehlende Felder älterer Dateien bekommen Standardwerte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        atMs = try c.decode(Int64.self, forKey: .atMs)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        startupMs = try c.decodeIfPresent(Int64.self, forKey: .startupMs)
        rebuffers = try c.decodeIfPresent(Int.self, forKey: .rebuffers) ?? 0
        rebufferMs = try c.decodeIfPresent(Int64.self, forKey: .rebufferMs) ?? 0
        watchedMs = try c.decodeIfPresent(Int64.self, forKey: .watchedMs) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Zusammenfassung für Einstellungen → Diagnose.
public struct PlaybackStatsSummary: Equatable, Sendable {
    public var sessions: Int
    public var started: Int
    public var medianStartupMs: Int64?
    public var p90StartupMs: Int64?
    /// Hänger pro Stunde Wiedergabe.
    public var rebuffersPerHour: Double?
    public var topRoutes: [RouteCount]
    public var recentErrors: [String]

    public struct RouteCount: Equatable, Sendable { public var route: String; public var count: Int }

    public var successRate: Double? { sessions == 0 ? nil : Double(started) / Double(sessions) }

    public static func of(_ sessions: [PlaybackSession]) -> PlaybackStatsSummary {
        let startups = sessions.compactMap(\.startupMs).sorted()
        let watchedHours = Double(sessions.reduce(Int64(0)) { $0 + $1.watchedMs }) / 3_600_000.0
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in sessions where s.startupMs != nil {
            guard let route = s.route else { continue }
            if counts[route] == nil { order.append(route) }
            counts[route, default: 0] += 1
        }
        let top = order.enumerated().sorted { counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset }
            .prefix(3).map { RouteCount(route: $0.element, count: counts[$0.element]!) }
        var errors: [String] = []
        for e in sessions.reversed().compactMap(\.error) where !errors.contains(e) { errors.append(e) }
        return PlaybackStatsSummary(
            sessions: sessions.count, started: startups.count,
            medianStartupMs: startups.indices.contains(startups.count / 2) ? startups[startups.count / 2] : nil,
            p90StartupMs: startups.isEmpty ? nil : startups[Int(Double(startups.count - 1) * 0.9)],
            rebuffersPerHour: watchedHours >= 0.05 ? Double(sessions.reduce(0) { $0 + $1.rebuffers }) / watchedHours : nil,
            topRoutes: Array(top), recentErrors: Array(errors.prefix(3)))
    }
}

/// Wiedergabe-Statistik, nur lokal: die letzten 300 Sitzungen als JSON-Zeilen. Nichts davon verlässt das Gerät.
public actor PlaybackStatsStore {
    public static let maxSessions = 300
    private let file: URL
    private var loaded: [PlaybackSession]?

    public init(file: URL) { self.file = file }

    @discardableResult
    public func record(_ session: PlaybackSession) -> PlaybackStatsSummary {
        var sessions = load()
        sessions.append(session)
        if sessions.count > Self.maxSessions { sessions.removeFirst(sessions.count - Self.maxSessions) }
        loaded = sessions
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            var data = Data()
            for s in sessions { data.append(try encoder.encode(s)); data.append(0x0A) }
            try data.write(to: file, options: .atomic)
        } catch { /* nicht speicherbar: Statistik ist nur Beiwerk */ }
        return PlaybackStatsSummary.of(sessions)
    }

    public func refresh() -> PlaybackStatsSummary { PlaybackStatsSummary.of(load()) }

    public func clear() {
        loaded = []
        try? FileManager.default.removeItem(at: file)
    }

    private func load() -> [PlaybackSession] {
        if let loaded { return loaded }
        var sessions: [PlaybackSession] = []
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) {
                if let s = try? decoder.decode(PlaybackSession.self, from: Data(line)) { sessions.append(s) }   // kaputte Zeilen auslassen
            }
        }
        sessions = Array(sessions.suffix(Self.maxSessions))
        loaded = sessions
        return sessions
    }
}
