import Foundation

public struct SelfTestResult: Equatable, Codable, Sendable {
    public var atMs: Int64
    public var ok: Bool
    public var route: String?
    public var detail: String
    public init(atMs: Int64, ok: Bool, route: String?, detail: String) { self.atMs = atMs; self.ok = ok; self.route = route; self.detail = detail }
}

/// Selbsttest auf dem Gerät: höchstens einmal täglich im Leerlauf ein öffentliches Video über die Abspielwege auflösen und
/// 1 KB vom Videoserver laden. So passt sich die Wegereihenfolge an, bevor der Nutzer ein Video startet, und ein Totalausfall
/// fällt sofort auf. (SABR gibt es in der iOS-Fassung nicht; eine reine SABR-Antwort erscheint als Frühwarnung im Fehlertext.)
public actor PlaybackSelfTest {
    /// „Me at the zoo“ – öffentlich, seit 2005 unverändert.
    public static let testVideoId = "jNQXAC9IVRw"
    public static let intervalMs: Int64 = 24 * 60 * 60 * 1000
    static let storeKey = "self_test"

    private let resolve: @Sendable (String) async throws -> ResolvedPlayback
    private let transport: HTTPTransport
    private let store: StringValueStore
    private let nowMs: @Sendable () -> Int64
    private var last: SelfTestResult?
    private var running = false
    private let gate = AsyncLimiter(1)

    public init(resolve: @escaping @Sendable (String) async throws -> ResolvedPlayback, transport: HTTPTransport, store: StringValueStore,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.resolve = resolve; self.transport = transport; self.store = store; self.nowMs = nowMs
        last = store.string(Self.storeKey).flatMap { try? JSONDecoder().decode(SelfTestResult.self, from: Data($0.utf8)) }
    }

    public func lastResult() -> SelfTestResult? { last }
    public func isRunning() -> Bool { running }
    public func isDue() -> Bool { nowMs() - (last?.atMs ?? 0) >= Self.intervalMs }

    /// Läuft nie doppelt: ein zweiter Aufruf wartet und liefert danach sein eigenes Ergebnis.
    @discardableResult
    public func run(videoId: String = PlaybackSelfTest.testVideoId) async -> SelfTestResult {
        await gate.acquire()
        running = true
        let result = await perform(videoId)
        running = false
        await gate.release()
        return result
    }

    private func perform(_ videoId: String) async -> SelfTestResult {
        do {
            let r = try await resolve(videoId)
            guard let format = (r.adaptiveFormats + r.muxedFormats).first(where: { !($0.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty }), let url = format.url.flatMap(URL.init(string:)) else {
                return save(SelfTestResult(atMs: nowMs(), ok: false, route: r.clientLabel, detail: "Keine abspielbaren Formate"))
            }
            let response = try await transport.send(HTTPRequest(url: url, headers: ["User-Agent": r.userAgent, "Range": "bytes=0-1023"]))
            let ok = (200...299).contains(response.code)
            let detail = ok ? "Videoserver antwortet (HTTP \(response.code))" + (r.throttlingUnsolved ? " – gedrosselt" : "") : "Videoserver lehnt ab (HTTP \(response.code))"
            return save(SelfTestResult(atMs: nowMs(), ok: ok, route: r.clientLabel, detail: detail))
        } catch is CancellationError {
            return last ?? SelfTestResult(atMs: 0, ok: false, route: nil, detail: "Abgebrochen")   // Abbruch wird nicht gespeichert
        } catch let e as PlaybackUnavailableError {
            let warn = e.kinds.filter { $0 == .sabrOnly || $0 == .botCheck }.sorted()
            let prefix = warn.isEmpty ? "" : "Frühwarnung (\(FailureKind.summary(warn))): "
            return save(SelfTestResult(atMs: nowMs(), ok: false, route: nil, detail: prefix + String((e.message.isEmpty ? "Kein Abspielweg" : e.message).prefix(160))))
        } catch {
            return save(SelfTestResult(atMs: nowMs(), ok: false, route: nil, detail: "Netzwerkfehler (\(String(describing: type(of: error))))"))
        }
    }

    private func save(_ r: SelfTestResult) -> SelfTestResult {
        if let d = try? JSONEncoder().encode(r) { store.setString(String(decoding: d, as: UTF8.self), for: Self.storeKey) }
        last = r
        return r
    }
}
