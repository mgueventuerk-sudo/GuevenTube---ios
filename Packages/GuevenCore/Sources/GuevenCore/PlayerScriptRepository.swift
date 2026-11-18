import Foundation

/// Aktuelles YouTube-Player-Skript (`base.js`, Variante „main“ wie bei yt-dlp): Player-ID aus `iframe_api`, Skript von
/// `/s/player/<id>/player_ias.vflset/en_US/base.js`. Die ID wird eine Stunde zwischengespeichert, das Skript (≈3 MB) im
/// Speicher und auf dem Gerät (die zwei neuesten Versionen) – ein Neustart lädt es nicht erneut.
public actor PlayerScriptRepository: PlayerScriptProviding {
    public static let iframeApiUrl = "https://www.youtube.com/iframe_api"
    static let idTtlMs: Int64 = 60 * 60 * 1000
    static let keepVersions = 2
    private static let playerIdPattern = try! NSRegularExpression(pattern: #"player\\?/([0-9a-fA-F]{8})\\?/"#)
    private static let playerIdFormat = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{8}$"#)
    private static let stsPattern = try! NSRegularExpression(pattern: #"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#)

    public static func scriptUrl(_ playerId: String) -> String { "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js" }

    private let transport: HTTPTransport
    private let directory: URL
    private let clock: @Sendable () -> Int64
    private let gate = AsyncLimiter(1)
    private var cachedId: String?
    private var cachedIdAt: Int64 = 0
    private var cachedScript: (id: String, text: String)?

    /// `clock` = monotone Uhr in ms (nicht die Wanduhr).
    public init(transport: HTTPTransport, directory: URL, clock: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }) {
        self.transport = transport; self.directory = directory; self.clock = clock
    }

    public func currentPlayerId() async throws -> String { try await currentPlayerId(forceRefresh: false) }

    /// ID des aktuellen Players, z. B. `c271e571`.
    public func currentPlayerId(forceRefresh: Bool) async throws -> String {
        await gate.acquire()
        do { let v = try await idLocked(forceRefresh); await gate.release(); return v } catch { await gate.release(); throw error }
    }

    private func idLocked(_ force: Bool) async throws -> String {
        let now = clock()
        if !force, let id = cachedId, now - cachedIdAt < Self.idTtlMs { return id }
        let page = try await fetch(Self.iframeApiUrl)
        guard let m = Self.playerIdPattern.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)), let r = Range(m.range(at: 1), in: page) else {
            throw SolverError("Player-ID nicht in iframe_api gefunden")
        }
        cachedId = String(page[r]); cachedIdAt = now
        return cachedId!
    }

    /// Das Skript selbst (für den Entschlüssler).
    public func script(_ playerId: String) async throws -> String {
        await gate.acquire()
        do { let v = try await scriptLocked(playerId); await gate.release(); return v } catch { await gate.release(); throw error }
    }

    private func scriptLocked(_ playerId: String) async throws -> String {
        guard Self.playerIdFormat.firstMatch(in: playerId, range: NSRange(playerId.startIndex..., in: playerId)) != nil else { throw SolverError("Ungültige Player-ID") }
        if let c = cachedScript, c.id == playerId { return c.text }
        let file = directory.appendingPathComponent("\(playerId).js")
        let text: String
        if let stored = try? String(contentsOf: file, encoding: .utf8) { text = stored }
        else {
            let fetched = try await fetch(Self.scriptUrl(playerId))
            if !fetched.contains("signatureTimestamp") && !fetched.contains("sts") { throw SolverError("Antwort ist kein Player-Skript") }
            store(file, fetched)
            text = fetched
        }
        cachedScript = (playerId, text)
        return text
    }

    /// `signatureTimestamp` für den `/player`-Aufruf (Regex wie yt-dlp).
    public func signatureTimestamp(playerId: String) async throws -> Int? {
        let s = try await script(playerId)
        guard let m = Self.stsPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    public func clear() { cachedId = nil; cachedScript = nil }

    private func store(_ file: URL, _ text: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let js = files.filter { $0.pathExtension == "js" }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a != b ? a > b : $0.lastPathComponent > $1.lastPathComponent
            }
            for old in js.dropFirst(Self.keepVersions) { try? FileManager.default.removeItem(at: old) }
        } catch { /* nicht speicherbar: nächster Start lädt neu */ }
    }

    private func fetch(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw SolverError("Ungültige URL") }
        let r = try await transport.send(HTTPRequest(url: u, headers: ["User-Agent": HTTPConstants.desktopUserAgent]))
        guard r.isSuccessful else { throw SolverError("HTTP \(r.code)") }
        return r.text
    }
}
