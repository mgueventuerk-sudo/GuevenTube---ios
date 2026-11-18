import XCTest
@testable import GuevenCore

/// Skript-Transport: liefert die vorbereiteten Antworten der Reihe nach und merkt sich alle Anfragen.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case response(HTTPResponse), failure }
    struct Failure: Error {}
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [HTTPRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let step: Step = lock.withLock { requests.append(request); return steps.isEmpty ? .response(HTTPResponse(code: 500)) : steps.removeFirst() }
        switch step { case .response(let r): return r; case .failure: throw Failure() }
    }
}

final class FakeAuth: AuthTokenProviding, @unchecked Sendable {
    var token: AuthToken?
    var refreshed: String? = "NEU"
    private(set) var refreshCalls = 0
    init(_ token: AuthToken? = nil) { self.token = token }
    func activeToken() async -> AuthToken? { token }
    func accessTokenOrNil() async -> String? { token?.accessToken }
    func forceRefresh(accessToken: String, accountId: String) async -> String? { refreshCalls += 1; return refreshed }
}

final class FakeSecrets: SecretStoring, @unchecked Sendable {
    var store: [String: String] = [:]
    func secret(_ key: String) async -> String? { store[key] }
    func setSecret(_ key: String, _ value: String) async throws { store[key] = value }
    func removeSecret(_ key: String) async throws { store[key] = nil }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ v: Int64) { lock.withLock { values.append(v) } }
    var all: [Int64] { lock.withLock { values } }
}

private func ok(_ json: String) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(json.utf8))) }
private func code(_ c: Int, retryAfter: Int64? = nil) -> FakeTransport.Step { .response(HTTPResponse(code: c, retryAfterSeconds: retryAfter)) }

final class InnerTubeServiceTests: XCTestCase {
    private let tvPage = #"<script>{"INNERTUBE_CLIENT_VERSION":"7.20270101.09.00"} <script src="/s/_/kabuki/_/js/k=x.y/am=z/m=base"></script>"#

    private func make(_ steps: [FakeTransport.Step], auth: FakeAuth = FakeAuth(), secrets: FakeSecrets = FakeSecrets(), sleeps: SleepLog = SleepLog(), withConfig: Bool = true)
        -> (InnerTubeService, FakeTransport) {
        // Die erste Anfrage jeder Sitzung ist der Konfigurationsabruf (TV-Seite); er steht immer vorn.
        let transport = FakeTransport((withConfig ? [.response(HTTPResponse(code: 200, body: Data(tvPage.utf8)))] : []) + steps)
        let config = InnerTubeConfigProvider(transport: transport)
        let service = InnerTubeService(transport: transport, config: config, auth: auth, secrets: secrets,
                                       sleepMs: { sleeps.add($0) }, locale: { ("de", "DE") })
        return (service, transport)
    }

    func testConfigReadsLiveVersionAndScriptAndFallsBack() async {
        let live = InnerTubeConfigProvider(transport: FakeTransport([.response(HTTPResponse(code: 200, body: Data(tvPage.utf8)))]))
        let c = await live.config()
        XCTAssertEqual(c.tvClientVersion, "7.20270101.09.00")
        XCTAssertEqual(c.tvScriptUrl, "https://www.youtube.com/s/_/kabuki/_/js/k=x.y/am=z/m=base")
        let v = await live.clientVersion(.tvhtml5)
        XCTAssertEqual(v, "7.20270101.09.00")

        let broken = InnerTubeConfigProvider(transport: FakeTransport([.failure]))
        let f = await broken.config()
        XCTAssertEqual(f.tvClientVersion, InnerTubeClient.tvhtml5.fallbackVersion)
        XCTAssertNil(f.tvScriptUrl)
    }

    func testBrowseSendsClientContextHeadersAndStoresVisitorData() async throws {
        let secrets = FakeSecrets()
        let (service, transport) = make([ok(#"{"responseContext":{"visitorData":"VD1"},"x":1}"#)], secrets: secrets)
        let root = try await service.browse(browseId: "FEsubscriptions")
        XCTAssertEqual(root.int("x"), 1)
        let req = transport.requests[1]
        XCTAssertEqual(req.url.absoluteString, "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["X-YouTube-Client-Name"], "7")
        XCTAssertEqual(req.headers["X-YouTube-Client-Version"], "7.20270101.09.00")
        XCTAssertNil(req.headers["Authorization"])
        let body = try JSONParser.parse(try XCTUnwrap(req.body))
        XCTAssertEqual(body.str("browseId"), "FEsubscriptions")
        XCTAssertEqual(body.path("context", "client").str("hl"), "de")
        XCTAssertEqual(secrets.store[InnerTubeService.secretVisitorData], "VD1")
        let vd = await service.currentVisitorData()
        XCTAssertEqual(vd, "VD1")
    }

    func testBackoffOn429And5xxUsesRetryAfterAndGivesUp() async throws {
        let sleeps = SleepLog()
        let (service, transport) = make([code(429, retryAfter: 3), code(503), .failure, ok("{}")], sleeps: sleeps)
        _ = try await service.search(query: "x")
        XCTAssertEqual(sleeps.all, [3_000, 2_000, 4_000], "Retry-After, dann 2 s und 4 s (Backoff 1 s << Versuch)")
        XCTAssertEqual(transport.requests.count, 5, "1 Konfiguration + 4 Versuche")

        let (failing, _) = make([code(500), code(500), code(500), code(500), code(500)], sleeps: SleepLog())
        do { _ = try await failing.search(query: "x"); XCTFail() } catch let e as InnerTubeError { XCTAssertEqual(e.statusCode, 500) }
    }

    func testRetryAfterIsCapped() async throws {
        let sleeps = SleepLog()
        let (service, _) = make([code(429, retryAfter: 999), ok("{}")], sleeps: sleeps)
        _ = try await service.search(query: "x")
        XCTAssertEqual(sleeps.all, [8_000])
    }

    func testExtremeOrNegativeRetryAfterIsHarmless() async throws {
        // Früher: Int64.max * 1000 lief über (Absturz), ein negativer Wert ergab eine negative Wartezeit.
        for value: Int64 in [Int64.max, -5] {
            let sleeps = SleepLog()
            let (service, _) = make([code(429, retryAfter: value), ok("{}")], sleeps: sleeps)
            _ = try await service.search(query: "x")
            XCTAssertEqual(sleeps.all, [value > 0 ? 8_000 : 0])
        }
    }

    func test401RefreshesTokenOnceAndRetries() async throws {
        let auth = FakeAuth(AuthToken(accessToken: "ALT", accountId: "acc"))
        let (service, transport) = make([code(401), ok("{}")], auth: auth)
        _ = try await service.next(videoId: "abc")
        XCTAssertEqual(auth.refreshCalls, 1)
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer ALT")
        XCTAssertEqual(transport.requests[2].headers["Authorization"], "Bearer NEU")
    }

    func testPlayerUsesProfileAndOnlySendsAccountWhenSupported() async throws {
        let auth = FakeAuth(AuthToken(accessToken: "T", accountId: "a"))
        let (service, transport) = make([ok("{}")], auth: auth, withConfig: false)
        _ = try await service.player(videoId: "vid", signatureTimestamp: 20000, poToken: "PO", profile: DefaultPlayerClients.visionOS, useAccount: true)
        XCTAssertNil(transport.requests[0].headers["Authorization"], "visionOS unterstützt kein OAuth")
        let body = try JSONParser.parse(try XCTUnwrap(transport.requests[0].body))
        XCTAssertEqual(body.str("videoId"), "vid")
        XCTAssertEqual(body.path("playbackContext", "contentPlaybackContext").int("signatureTimestamp"), 20000)
        XCTAssertEqual(body.path("serviceIntegrityDimensions").str("poToken"), "PO")
        XCTAssertEqual(body.path("context", "client").str("clientName"), "VISIONOS")
        XCTAssertEqual(transport.requests[0].headers["X-YouTube-Client-Name"], "101")
    }

    func testMusicFallsBackToAnonymousWhenTokenRejectedAndKeepsVisitorData() async throws {
        let auth = FakeAuth(AuthToken(accessToken: "T", accountId: "a"))
        let secrets = FakeSecrets()
        secrets.store[InnerTubeService.secretVisitorData] = "SHARED"
        let (service, transport) = make([code(400), ok(#"{"responseContext":{"visitorData":"ANDERS"}}"#)], auth: auth, secrets: secrets)
        let accepted = Box()
        _ = try await service.music("browse", withAccount: true, accountAccepted: { accepted.value = $0 }, payload: [("browseId", "FEmusic_home")])
        XCTAssertEqual(accepted.value, false)
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer T")
        XCTAssertNil(transport.requests[2].headers["Authorization"])
        XCTAssertTrue(transport.requests[1].url.absoluteString.hasPrefix("https://music.youtube.com/youtubei/v1/browse"))
        XCTAssertEqual(secrets.store[InnerTubeService.secretVisitorData], "SHARED", "Music überschreibt die gemeinsame visitorData nicht")
    }

    func testInvalidJsonAndHttpErrorsThrow() async {
        let (service, _) = make([ok("kein json")])
        do { _ = try await service.search(query: "x"); XCTFail() } catch let e as InnerTubeError { XCTAssertTrue(e.message.contains("ungültiges JSON")) } catch { XCTFail() }
        let (service2, _) = make([code(403)])
        do { _ = try await service2.search(query: "x"); XCTFail() } catch let e as InnerTubeError { XCTAssertEqual(e.statusCode, 403) } catch { XCTFail() }
    }

    func testResetVisitorDataClearsStore() async throws {
        let secrets = FakeSecrets()
        secrets.store[InnerTubeService.secretVisitorData] = "X"
        let (service, _) = make([], secrets: secrets)
        try await service.resetVisitorData()
        XCTAssertNil(secrets.store[InnerTubeService.secretVisitorData])
        let vd = await service.currentVisitorData()
        XCTAssertNil(vd)
    }

    final class Box: @unchecked Sendable { var value: Bool? }
}
