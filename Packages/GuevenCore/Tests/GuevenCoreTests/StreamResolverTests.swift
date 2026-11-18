import XCTest
@testable import GuevenCore

final class FakeEndpoint: PlayerEndpoint, @unchecked Sendable {
    typealias Handler = @Sendable (PlayerClientProfile, Bool, Int?, String?) async throws -> JSON
    private let lock = NSLock()
    private var calls: [String] = []
    private var stsSeen: [Int?] = []
    var account = false
    let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }
    var callLabels: [String] { lock.withLock { calls } }
    var timestamps: [Int?] { lock.withLock { stsSeen } }
    func player(videoId: String, signatureTimestamp: Int?, poToken: String?, profile: PlayerClientProfile, useAccount: Bool) async throws -> JSON {
        lock.withLock { calls.append(profile.id + (useAccount ? "+acc" : "")); stsSeen.append(signatureTimestamp) }
        return try await handler(profile, useAccount, signatureTimestamp, poToken)
    }
    func hasAccount() async -> Bool { account }
    func currentVisitorData() async -> String? { "VD" }
    func resetVisitorData() async throws {}
}

struct FakeRegistry: ClientProfileProviding {
    var all = DefaultPlayerClients.all
    func profiles() async -> [PlayerClientProfile] { all.filter(\.enabled) }
}

final class FakeSolver: ChallengeSolving, @unchecked Sendable {
    var available = true
    var nMap: [String: String] = [:]
    var sigMap: [String: String] = [:]
    var failWith: String?
    private(set) var solveCalls = 0
    func isAvailable() async -> Bool { available }
    func status() async -> String { available ? "bereit" : "nicht verfügbar" }
    func solve(playerId: String, nChallenges: Set<String>, sigChallenges: Set<String>) async throws -> SolvedChallenges {
        solveCalls += 1
        if let failWith { throw SolverError(failWith) }
        return SolvedChallenges(n: nChallenges.reduce(into: [:]) { if let v = nMap[$1] { $0[$1] = v } },
                                sig: sigChallenges.reduce(into: [:]) { if let v = sigMap[$1] { $0[$1] = v } })
    }
}

final class FakeScripts: PlayerScriptProviding, @unchecked Sendable {
    var sts: Int? = 20000
    private(set) var stsCalls = 0
    func currentPlayerId() async throws -> String { "abcd1234" }
    func signatureTimestamp(playerId: String) async throws -> Int? { stsCalls += 1; return sts }
    func clear() async {}
}

struct FixedPoTokens: PoTokenProviding {
    var token: String?
    func tokens(videoId: String, visitorData: String?, generate: Bool) async -> PoTokens? { token.map { PoTokens(player: $0, streaming: $0, generated: false) } }
}

final class ResolverClock: @unchecked Sendable { var now: Int64 = 1_000_000 }
final class MemStore: PreferredRouteStore, @unchecked Sendable {
    var value: String?
    func preferred() -> String? { value }
    func setPreferred(_ label: String?) { value = label }
}

final class StreamResolverTests: XCTestCase {
    // Player-Antworten
    private func playable(formats: String, expires: Int = 21540, extra: String = "") -> JSON {
        try! JSONParser.parse(#"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"vid12345678","title":"T","author":"A","lengthSeconds":"60"},"streamingData":{"expiresInSeconds":"\#(expires)","adaptiveFormats":[\#(formats)]\#(extra)}}"#)
    }
    private func unplayable(_ status: String, _ reason: String) -> JSON {
        try! JSONParser.parse(#"{"playabilityStatus":{"status":"\#(status)","reason":"\#(reason)"}}"#)
    }
    private let direct = #"{"itag":18,"url":"https://rr1.googlevideo.com/videoplayback?id=1&n=NALT","mimeType":"video/mp4; codecs=\"avc1\"","bitrate":1000}"#
    private let directNoN = #"{"itag":18,"url":"https://rr1.googlevideo.com/videoplayback?id=1","mimeType":"video/mp4; codecs=\"avc1\"","bitrate":1000}"#
    private let cipher = #"{"itag":22,"signatureCipher":"s=SIGALT&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fvideoplayback%3Fid%3D2%26n%3DNALT","mimeType":"video/mp4; codecs=\"avc1\"","bitrate":2000}"#

    private struct Setup {
        var resolver: StreamResolver
        var endpoint: FakeEndpoint
        var solver: FakeSolver
        var scripts: FakeScripts
        var clock: ResolverClock
        var store: MemStore
    }

    private func make(_ handler: @escaping FakeEndpoint.Handler, solver: FakeSolver = FakeSolver(), poToken: String? = nil,
                      timings: ResolverTimings = { var t = ResolverTimings(); t.hedgeDelayMs = 20; t.routeTimeoutMs = 2_000; t.totalTimeoutMs = 5_000; t.warmTotalTimeoutMs = 3_000; return t }(),
                      account: Bool = false) -> Setup {
        let endpoint = FakeEndpoint(handler)
        endpoint.account = account
        let scripts = FakeScripts()
        let clock = ResolverClock()
        let store = MemStore()
        let resolver = StreamResolver(endpoint: endpoint, registry: FakeRegistry(), solver: solver, scripts: scripts, poTokens: FixedPoTokens(token: poToken),
                                      health: RouteHealth(store: store) { clock.now }, timings: timings, nowMs: { clock.now })
        return Setup(resolver: resolver, endpoint: endpoint, solver: solver, scripts: scripts, clock: clock, store: store)
    }

    func testJsFreeRouteWinsWithoutPlayerScriptAndAppendsPoToken() async throws {
        let direct = self.direct
        let s = make({ _, _, _, _ in self.playable(formats: direct) }, poToken: "POT+1")
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(r.clientLabel, "visionOS")
        XCTAssertTrue(r.summary.contains("ohne Player-Skript"), r.summary)
        XCTAssertEqual(s.scripts.stsCalls, 0, "Skript wird für Wege ohne JavaScript nicht geladen")
        XCTAssertEqual(s.solver.solveCalls, 0)
        XCTAssertEqual(r.adaptiveFormats.first?.url, "https://rr1.googlevideo.com/videoplayback?id=1&n=NALT&pot=POT%2B1", "n bleibt bei Wegen ohne JS unverändert")
        XCTAssertEqual(r.userAgent, DefaultPlayerClients.visionOS.userAgent)
        XCTAssertFalse(r.throttlingUnsolved)
        XCTAssertEqual(s.store.value, "visionOS", "Erfolg wird als bevorzugter Weg gemerkt")
    }

    func testCacheAndExpiry() async throws {
        let direct = self.direct
        let s = make({ _, _, _, _ in self.playable(formats: direct, expires: 3600) })
        _ = try await s.resolver.resolve("vid12345678")
        _ = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(s.endpoint.callLabels.count, 1, "zweiter Aufruf kommt aus dem Speicher")
        let hit = await s.resolver.cached("vid12345678")
        XCTAssertNotNil(hit)
        let advance: Int64 = 3_600_000 - 300_000 + 1 // 5 Minuten Sicherheitsabstand vor Ablauf
        s.clock.now += advance
        let expired = await s.resolver.cached("vid12345678")
        XCTAssertNil(expired)
        _ = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(s.endpoint.callLabels.count, 2)
        _ = try await s.resolver.resolve("vid12345678", forceRefresh: true)
        XCTAssertEqual(s.endpoint.callLabels.count, 3)
    }

    func testFallsBackToTvRouteAndSolvesSignatureAndN() async throws {
        let cipher = self.cipher
        let solver = FakeSolver()
        solver.nMap = ["NALT": "NNEU"]; solver.sigMap = ["SIGALT": "SIGNEU"]
        let s: Setup = make({ (profile: PlayerClientProfile, _: Bool, sts: Int?, _: String?) -> JSON in
            if profile.id == "visionos" { return self.unplayable("UNPLAYABLE", "gesperrt") }
            XCTAssertEqual(sts, 20000, "JS-Wege senden den signatureTimestamp")
            return self.playable(formats: cipher)
        }, solver: solver)
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(r.clientLabel, "TV (Samsung) · ohne Anmeldung")
        XCTAssertEqual(r.adaptiveFormats.first?.url, "https://rr1.googlevideo.com/videoplayback?id=2&n=NNEU&sig=SIGNEU")
        XCTAssertNil(r.adaptiveFormats.first?.signatureCipher)
        let hasSig = r.summary.contains("Signatur entschlüsselt")
        let hasN = r.summary.contains("n-Parameter entschlüsselt")
        XCTAssertTrue(hasSig, r.summary)
        XCTAssertTrue(hasN, r.summary)
        XCTAssertFalse(r.throttlingUnsolved)
        XCTAssertEqual(s.solver.solveCalls, 1, "alle Herausforderungen in einem Lauf")
        XCTAssertTrue(r.attempts.contains { $0.label == "visionOS" && $0.outcome == .failed })
    }

    func testUnsolvedNFallsBackToThrottledStreamsAsLastResort() async throws {
        let direct = self.direct
        let s = make({ profile, _, _, _ in
            profile.id == "visionos" ? self.unplayable("UNPLAYABLE", "gesperrt") : self.playable(formats: direct)
        }, solver: { let f = FakeSolver(); f.failWith = "Skript geändert"; return f }())
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertTrue(r.throttlingUnsolved)
        XCTAssertTrue(r.summary.contains("n-Parameter NICHT entschlüsselt (Skript geändert)"), r.summary)
        XCTAssertEqual(r.adaptiveFormats.first?.url, "https://rr1.googlevideo.com/videoplayback?id=1&n=NALT")
    }

    func testEnhancedExceptResultCountsAsUnsolved() async throws {
        let direct = self.direct
        let solver = FakeSolver()
        solver.nMap = ["NALT": "enhanced_except_abc_NALT"]
        let s = make({ profile, _, _, _ in
            profile.id == "visionos" ? self.unplayable("UNPLAYABLE", "gesperrt") : self.playable(formats: direct)
        }, solver: solver)
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertTrue(r.throttlingUnsolved, "Fehlerwert der n-Funktion ist keine Entschlüsselung")
        XCTAssertEqual(r.adaptiveFormats.first?.url, "https://rr1.googlevideo.com/videoplayback?id=1&n=NALT")
    }

    func testSolverUnavailableIsExplained() async throws {
        let direct = self.direct
        let s = make({ profile, _, _, _ in
            profile.id == "visionos" ? self.unplayable("UNPLAYABLE", "x") : self.playable(formats: direct)
        }, solver: { let f = FakeSolver(); f.available = false; return f }())
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertTrue(r.summary.contains("Entschlüssler-Sandbox auf diesem Gerät nicht verfügbar"), r.summary)
    }

    func testStreamsWithoutNResolveFullyEvenWithoutSolver() async throws {
        let noN = directNoN
        let s = make({ profile, _, _, _ in
            profile.id == "visionos" ? self.unplayable("UNPLAYABLE", "x") : self.playable(formats: noN)
        }, solver: { let f = FakeSolver(); f.available = false; return f }())
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertFalse(r.throttlingUnsolved)
    }

    func testConcurrentResolvesShareOneRequest() async throws {
        let direct = self.direct
        var slow = ResolverTimings(); slow.hedgeDelayMs = 5_000
        let s = make({ _, _, _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return self.playable(formats: direct)
        }, timings: slow)
        async let a = s.resolver.resolve("vid12345678")
        async let b = s.resolver.resolve("vid12345678")
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra, rb)
        XCTAssertEqual(s.endpoint.callLabels.count, 1)
    }

    func testRejectedRouteIsSkippedNextTime() async throws {
        let direct = self.direct
        let s = make({ _, _, _, _ in self.playable(formats: direct) })
        let first = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(first.clientLabel, "visionOS")
        await s.resolver.rejectRoute(videoId: "vid12345678", routeLabel: "visionOS")
        let second = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(second.clientLabel, "TV (Samsung) · ohne Anmeldung")
        XCTAssertFalse(s.endpoint.callLabels.last!.hasPrefix("visionos"))
    }

    func testAllRoutesFailingReportsReasonProtocolAndKinds() async {
        let s = make({ profile, _, _, _ in
            if profile.id == "visionos" { return self.unplayable("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot") }
            throw InnerTubeError(statusCode: 403, message: "x")
        })
        do {
            _ = try await s.resolver.resolve("vid12345678")
            XCTFail()
        } catch let e as PlaybackUnavailableError {
            XCTAssertEqual(e.status, "LOGIN_REQUIRED")
            XCTAssertTrue(e.message.contains("bot"))
            XCTAssertEqual(e.attempts.count, 3)
            XCTAssertTrue(e.kinds.contains(.botCheck) && e.kinds.contains(.technical))
            XCTAssertEqual(FailureKind.summary(Array(e.kinds)), "bot+technik")
        } catch { XCTFail("\(error)") }
    }

    func testSabrOnlyResponseIsReportedAsSabrKind() async {
        let s = make({ _, _, _, _ in
            self.playable(formats: #"{"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","bitrate":1}"#, extra: #","serverAbrStreamingUrl":"https://sabr""#)
        })
        do { _ = try await s.resolver.resolve("vid12345678"); XCTFail() }
        catch let e as PlaybackUnavailableError { XCTAssertTrue(e.kinds.contains(.sabrOnly), "\(e.kinds)") }
        catch { XCTFail("\(error)") }
    }

    func testTotalTimeoutReportsConnectionHint() async {
        var t = ResolverTimings(); t.routeTimeoutMs = 10_000; t.totalTimeoutMs = 150; t.minRetryMs = 150; t.hedgeDelayMs = 10_000
        let s = make({ _, _, _, _ in try await Task.sleep(nanoseconds: 10_000_000_000); return self.unplayable("UNPLAYABLE", "x") }, timings: t)
        do { _ = try await s.resolver.resolve("vid12345678"); XCTFail() }
        catch let e as PlaybackUnavailableError {
            XCTAssertEqual(e.status, "TIMEOUT")
            XCTAssertTrue(e.message.hasPrefix("Zeitüberschreitung"))
            XCTAssertTrue(e.kinds.contains(.technical))
        } catch { XCTFail("\(error)") }
    }

    func testAccountRoutesComeFirstForOAuthProfiles() async throws {
        let direct = self.direct
        let s = make({ profile, acc, _, _ in
            if profile.id == "visionos" { return self.unplayable("UNPLAYABLE", "x") }
            return self.playable(formats: direct)
        }, account: true)
        let r = try await s.resolver.resolve("vid12345678")
        XCTAssertEqual(r.clientLabel, "TV (Samsung) · mit Konto")
        XCTAssertTrue(s.endpoint.callLabels.contains("tv_samsung+acc"))
    }

    func testDiagnoseTriesEveryRoute() async throws {
        let direct = self.direct
        let s = make({ profile, _, _, _ in profile.id == "tv_samsung" ? self.unplayable("UNPLAYABLE", "x") : self.playable(formats: direct) })
        let lines = try await s.resolver.diagnose("vid12345678")
        XCTAssertEqual(lines[0].label, "Player-Skript")
        XCTAssertEqual(lines[1].label, "Entschlüssler")
        XCTAssertTrue(lines.contains { $0.label == "Web" && $0.outcome == .skipped && $0.detail == "nur mit PO-Token" })
        XCTAssertEqual(lines.first { $0.label == "visionOS" }?.outcome, .ok)
        XCTAssertEqual(lines.first { $0.label.hasPrefix("TV (Samsung)") }?.outcome, .failed)
        XCTAssertEqual(lines.first { $0.label == "Web (eingebettet)" }?.outcome, .failed, "n-Parameter ungelöst (Solver ohne Mapping) zählt im Test als Fehlschlag")
    }
}
