import XCTest
@testable import GuevenCore

private actor FakeStore: AccountCredentialStore {
    var account: AccountCredentials?
    private(set) var updates = 0
    private(set) var reauthMarks = 0
    init(_ account: AccountCredentials?) { self.account = account }
    func activeCredentials() -> AccountCredentials? { account }
    func credentials(accountId: String) -> AccountCredentials? { account?.accountId == accountId ? account : nil }
    func updateTokens(accountId: String, accessToken: String, expiresAtMs: Int64, refreshToken: String?, scope: String?) -> Bool {
        guard var a = account, a.accountId == accountId else { return false }
        a.accessToken = accessToken; a.accessTokenExpiresAtEpochMs = expiresAtMs
        a.refreshToken = refreshToken ?? a.refreshToken; a.scope = scope ?? a.scope; a.needsReauth = false
        account = a; updates += 1; return true
    }
    func markNeedsReauth(accountId: String) -> Bool { account?.needsReauth = true; reauthMarks += 1; return true }
}

final class AuthCredentialsTests: XCTestCase {
    func testOldAccountsWithoutNewFieldsStillDecode() throws {
        let old = #"{"accountId":"konto1","displayName":"A","accessToken":"a","accessTokenExpiresAtEpochMs":1,"refreshToken":"r","createdAtEpochMs":1,"updatedAtEpochMs":1}"#
        let decoded = try JSONDecoder().decode(AccountCredentials.self, from: Data(old.utf8))
        XCTAssertNil(decoded.oauthClientId)
        XCTAssertFalse(decoded.needsReauth)
        XCTAssertEqual(decoded.tokenType, "Bearer")
        XCTAssertNil(decoded.oauthClient(), "alte Konten nutzen den aktuell ermittelten Client")
    }

    func testIssuingClientIsStoredAndSecretNotLogged() throws {
        let client = OAuthClientCredentials(clientId: "id.apps.googleusercontent.com", clientSecret: "geheim123")
        let c = try TokenResponse(accessToken: "a", refreshToken: "r").toCredentials(accountId: "konto1", displayName: "A", email: nil, avatarUrl: nil,
                                                                                      channelId: "UC1", client: client, nowMs: 100, createdAtMs: 42)
        XCTAssertEqual(c.oauthClient(), client)
        XCTAssertEqual(c.createdAtEpochMs, 42)
        XCTAssertEqual(c.accessTokenExpiresAtEpochMs, 100 + 3_600_000)
        let round = try JSONDecoder().decode(AccountCredentials.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(round.oauthClient(), client)
        for text in [c.description, "\(c)", String(reflecting: c.description)] {
            XCTAssertFalse(text.contains("geheim123")); XCTAssertFalse(text.contains("\"a\"")); XCTAssertTrue(text.contains("<redacted>"))
        }
    }

    func testMissingRefreshTokenAndBadAccountIdAreRejected() {
        XCTAssertThrowsError(try TokenResponse(accessToken: "a").toCredentials(accountId: "ok", displayName: "A", email: nil, avatarUrl: nil, channelId: nil, nowMs: 1))
        XCTAssertThrowsError(try TokenResponse(accessToken: "a", refreshToken: "r").toCredentials(accountId: "../x", displayName: "A", email: nil, avatarUrl: nil, channelId: nil, nowMs: 1))
        XCTAssertThrowsError(try JSONDecoder().decode(AccountCredentials.self, from: Data(#"{"accountId":"a b","displayName":"A","accessToken":"a","accessTokenExpiresAtEpochMs":1,"refreshToken":"r","createdAtEpochMs":1,"updatedAtEpochMs":1}"#.utf8)))
    }

    func testClientErrorsRequireReauthentication() {
        for e in ["invalid_grant", "invalid_client", "unauthorized_client"] { XCTAssertTrue(OAuthError(error: e, message: e).requiresReauthentication, e) }
        for e in ["temporarily_unavailable", "slow_down", "server_error"] { XCTAssertFalse(OAuthError(error: e, message: e).requiresReauthentication, e) }
    }

    func testExpiryUsesSafetyMargin() throws {
        let c = try AccountCredentials(accountId: "a", displayName: "A", accessToken: "t", accessTokenExpiresAtEpochMs: 100_000, refreshToken: "r", createdAtEpochMs: 0, updatedAtEpochMs: 0)
        XCTAssertFalse(c.isAccessTokenExpired(nowMs: 39_999))
        XCTAssertTrue(c.isAccessTokenExpired(nowMs: 40_000))
        XCTAssertFalse(c.isAccessTokenExpired(nowMs: 99_999, safetyMarginMs: 0))
        XCTAssertEqual(c.authorizationHeader(), "Bearer t")
    }
}

final class OAuthClientTests: XCTestCase {
    private func ok(_ json: String, code: Int = 200) -> FakeTransport.Step { .response(HTTPResponse(code: code, body: Data(json.utf8))) }
    private let client = OAuthClientCredentials(clientId: "cid", clientSecret: "sec")
    /// Eigene Rückfall-Kennung: Tests hängen nicht von den Build-Secrets ab.
    private static let testFallback = OAuthClientCredentials(clientId: "test-fallback.apps.googleusercontent.com", clientSecret: "test-secret")
    private func make(_ steps: [FakeTransport.Step], script: String? = nil) -> (OAuthClient, FakeTransport) {
        let t = FakeTransport(steps)
        return (OAuthClient(transport: t, tvScriptUrl: { script }, fallback: Self.testFallback), t)
    }
    private func bodyOf(_ r: HTTPRequest) -> JSON { try! JSONParser.parse(r.body!) }

    func testDeviceCodeRequestAndDefaults() async throws {
        let (o, t) = make([ok(#"{"device_code":"DC","user_code":"ABCD-EFGH"}"#)])
        let r = try await o.requestDeviceCode(client: client)
        XCTAssertEqual(r, DeviceCodeResponse(deviceCode: "DC", userCode: "ABCD-EFGH", verificationUrl: "https://www.google.com/device", expiresInSeconds: 1800, intervalSeconds: 5))
        let req = t.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://www.youtube.com/o/oauth2/device/code")
        XCTAssertEqual(bodyOf(req).str("client_id"), "cid")
        XCTAssertEqual(bodyOf(req).str("device_model"), "ytlr::")
        XCTAssertEqual(req.headers["Origin"], "https://www.youtube.com")
    }

    func testDeviceCodeErrorAndGarbageThrow() async {
        let (a, _) = make([ok(#"{"error":"invalid_client"}"#, code: 400)])
        do { _ = try await a.requestDeviceCode(client: client); XCTFail() } catch { XCTAssertEqual((error as? OAuthError)?.error, "invalid_client") }
        let (b, _) = make([ok("<html>")])
        do { _ = try await b.requestDeviceCode(client: client); XCTFail() } catch { XCTAssertEqual((error as? OAuthError)?.error, "invalid_response") }
        let (c, _) = make([ok(#"{"user_code":"X"}"#)])
        do { _ = try await c.requestDeviceCode(client: client); XCTFail() } catch { XCTAssertEqual((error as? OAuthError)?.error, "invalid_response") }
    }

    func testPollMapsEveryOutcome() async throws {
        let cases: [(String, TokenPollResult)] = [
            (#"{"error":"authorization_pending"}"#, .pending), (#"{"error":"slow_down"}"#, .slowDown),
            (#"{"error":"expired_token"}"#, .expired), (#"{"error":"access_denied"}"#, .denied),
            (#"{"error":"boom"}"#, .failure("boom")),
            (#"{"access_token":"AT","refresh_token":"RT","expires_in":1800,"scope":"s"}"#, .success(TokenResponse(accessToken: "AT", expiresInSeconds: 1800, refreshToken: "RT", scope: "s"))),
            (#"{"expires_in":5}"#, .failure("Token-Antwort unvollständig")),
        ]
        for (body, expected) in cases {
            let (o, t) = make([ok(body, code: 428)])
            let r = try await o.pollToken(deviceCode: "DC", client: client)
            XCTAssertEqual(r, expected, body)
            XCTAssertEqual(bodyOf(t.requests[0]).str("code"), "DC")
            XCTAssertEqual(bodyOf(t.requests[0]).str("grant_type"), "http://oauth.net/grant_type/device/1.0")
        }
        let (broken, _) = make([.failure])
        let r = try await broken.pollToken(deviceCode: "DC", client: client)
        if case .failure = r {} else { XCTFail("Netzfehler muss .failure liefern") }
    }

    func testRefreshSuccessAndError() async throws {
        let (o, t) = make([ok(#"{"access_token":"NEU","expires_in":3599}"#), ok(#"{"error":"invalid_grant"}"#, code: 400)])
        let tokens = try await o.refresh(refreshToken: "RT", client: client)
        XCTAssertEqual(tokens.accessToken, "NEU"); XCTAssertEqual(tokens.expiresInSeconds, 3599); XCTAssertNil(tokens.refreshToken)
        XCTAssertEqual(bodyOf(t.requests[0]).str("refresh_token"), "RT")
        XCTAssertEqual(bodyOf(t.requests[0]).str("client_secret"), "sec")
        do { _ = try await o.refresh(refreshToken: "RT", client: client); XCTFail() }
        catch { XCTAssertTrue((error as? OAuthError)?.requiresReauthentication == true) }
    }

    func testRevokeSendsTokenInBodyNotUrl() async throws {
        let (o, t) = make([.response(HTTPResponse(code: 200)), .response(HTTPResponse(code: 400))])
        let first = try await o.revoke(token: "a+b&c=d")
        XCTAssertTrue(first)
        XCTAssertFalse(t.requests[0].url.absoluteString.contains("a+b"))
        XCTAssertEqual(String(decoding: t.requests[0].body!, as: UTF8.self), "token=a%2Bb%26c%3Dd")
        let second = try await o.revoke(token: "x")
        XCTAssertFalse(second)
    }

    func testCredentialsAreReadFromScriptAndCached() async throws {
        let script = #"var a={clientId:"123-abc.apps.googleusercontent.com",clientSecret_x:"SECRET-1_x"};"#
        let (o, t) = make([ok(script)], script: "https://www.youtube.com/s/tv/base.js")
        let c1 = try await o.clientCredentials(), c2 = try await o.clientCredentials()
        XCTAssertEqual(c1, OAuthClientCredentials(clientId: "123-abc.apps.googleusercontent.com", clientSecret: "SECRET-1_x"))
        XCTAssertEqual(c1, c2)
        XCTAssertEqual(t.requests.count, 1)
    }

    func testCredentialsFallBackWhenScriptMissingBrokenOrUnreachable() async throws {
        for (steps, script) in [([FakeTransport.Step](), String?.none), ([ok("nichts passendes")], "https://x/s.js"), ([.failure], "https://x/s.js")] {
            let (o, _) = make(steps, script: script)
            let c = try await o.clientCredentials()
            XCTAssertTrue(c.clientId.hasSuffix(".apps.googleusercontent.com")); XCTAssertFalse(c.clientSecret.isEmpty)
        }
    }

    func testRequestWithoutExplicitClientDiscoversOnce() async throws {
        let script = #"{clientId:"9-z.apps.googleusercontent.com",k:"S"}"#
        let (o, t) = make([ok(script), ok(#"{"error":"authorization_pending"}"#), ok(#"{"error":"authorization_pending"}"#)], script: "https://x/s.js")
        _ = try await o.pollToken(deviceCode: "D"); _ = try await o.pollToken(deviceCode: "D")
        XCTAssertEqual(t.requests.count, 3)
        XCTAssertEqual(bodyOf(t.requests[1]).str("client_id"), "9-z.apps.googleusercontent.com")
    }
}

final class AuthTokenManagerTests: XCTestCase {
    private let now: Int64 = 1_000_000
    private func account(expiresIn: Int64 = 3_600_000, client: OAuthClientCredentials? = nil, reauth: Bool = false) -> AccountCredentials {
        try! AccountCredentials(accountId: "konto1", displayName: "A", accessToken: "ALT", accessTokenExpiresAtEpochMs: 1_000_000 + expiresIn,
                                refreshToken: "RT", createdAtEpochMs: 0, updatedAtEpochMs: 0, oauthClientId: client?.clientId,
                                oauthClientSecret: client?.clientSecret, needsReauth: reauth)
    }
    private func make(_ acc: AccountCredentials?, _ steps: [FakeTransport.Step]) -> (AuthTokenManager, FakeStore, FakeTransport) {
        let t = FakeTransport(steps)
        let store = FakeStore(acc)
        let oauth = OAuthClient(transport: t, tvScriptUrl: { nil }, fallback: OAuthClientCredentials(clientId: "test-fallback.apps.googleusercontent.com", clientSecret: "test-secret"))
        return (AuthTokenManager(store: store, oauth: oauth, nowMs: { [now] in now }), store, t)
    }
    private func tokenStep(_ token: String = "NEU") -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(#"{"access_token":"\#(token)","expires_in":3600}"#.utf8))) }
    private func errStep(_ e: String) -> FakeTransport.Step { .response(HTTPResponse(code: 400, body: Data(#"{"error":"\#(e)"}"#.utf8))) }

    func testValidTokenIsReturnedWithoutNetwork() async {
        let (m, _, t) = make(account(), [])
        let token = await m.activeToken()
        XCTAssertEqual(token, AuthToken(accessToken: "ALT", accountId: "konto1"))
        XCTAssertEqual(t.requests.count, 0)
    }

    func testGuestModeHasNoToken() async {
        let (m, _, _) = make(nil, [])
        let token = await m.accessTokenOrNil()
        XCTAssertNil(token)
    }

    func testExpiredTokenIsRefreshedAndStored() async {
        let (m, s, t) = make(account(expiresIn: 30_000), [tokenStep()])   // innerhalb der 60-s-Marge
        let token = await m.accessTokenOrNil()
        XCTAssertEqual(token, "NEU")
        let stored = await s.account
        XCTAssertEqual(stored?.accessToken, "NEU")
        XCTAssertEqual(stored?.accessTokenExpiresAtEpochMs, now + 3_600_000)
        XCTAssertEqual(stored?.refreshToken, "RT", "ohne neuen Refresh-Token bleibt der alte")
        XCTAssertEqual(t.requests.count, 1)
    }

    func testRefreshUsesIssuingClientOfTheAccount() async throws {
        let issuing = OAuthClientCredentials(clientId: "alt-client", clientSecret: "alt-secret")
        let (m, _, t) = make(account(expiresIn: -1, client: issuing), [tokenStep()])
        _ = await m.accessTokenOrNil()
        let body = try JSONParser.parse(t.requests[0].body!)
        XCTAssertEqual(body.str("client_id"), "alt-client")
        XCTAssertEqual(body.str("client_secret"), "alt-secret")
    }

    func testParallelCallersShareOneRefresh() async {
        let (m, s, t) = make(account(expiresIn: -1), [tokenStep("EINS"), tokenStep("ZWEI")])
        let results = await withTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<8 { group.addTask { await m.accessTokenOrNil() } }
            var all: [String?] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.compactMap { $0 }, Array(repeating: "EINS", count: 8))
        XCTAssertEqual(t.requests.count, 1, "nur ein Abruf des Token-Endpunkts")
        let updates = await s.updates
        XCTAssertEqual(updates, 1)
    }

    func testInvalidGrantMarksAccountAndStopsFurtherRefreshes() async {
        let (m, s, t) = make(account(expiresIn: -1), [errStep("invalid_grant")])
        var token = await m.accessTokenOrNil()
        XCTAssertNil(token)
        let marks = await s.reauthMarks
        XCTAssertEqual(marks, 1)
        let reauth = await m.reauthenticationRequired()
        XCTAssertEqual(reauth, "konto1")
        let before = t.requests.count
        token = await m.accessTokenOrNil()
        XCTAssertNil(token)
        XCTAssertEqual(t.requests.count, before, "kein weiterer Abruf nach endgültiger Ablehnung")
        await m.acknowledgeReauthentication()
        let cleared = await m.reauthenticationRequired()
        XCTAssertNil(cleared)
    }

    func testTransientServerErrorDoesNotMarkReauth() async {
        let (m, s, _) = make(account(expiresIn: -1), [errStep("temporarily_unavailable")])
        let token = await m.accessTokenOrNil()
        XCTAssertNil(token)
        let marks = await s.reauthMarks
        XCTAssertEqual(marks, 0)
    }

    func testNetworkFailureKeepsOldTokenOnlyWhileFormallyValid() async {
        let (a, _, _) = make(account(expiresIn: 30_000), [.failure])   // läuft in 30 s ab: Marge verletzt, formal noch gültig
        let kept = await a.accessTokenOrNil()
        XCTAssertEqual(kept, "ALT")
        let (b, _, _) = make(account(expiresIn: -5_000), [.failure])
        let dropped = await b.accessTokenOrNil()
        XCTAssertNil(dropped)
    }

    func testForceRefreshAfter401() async {
        let (m, _, t) = make(account(), [tokenStep()])
        let refreshed = await m.forceRefresh(accessToken: "ALT", accountId: "konto1")
        XCTAssertEqual(refreshed, "NEU")
        XCTAssertEqual(t.requests.count, 1)
    }

    func testForceRefreshWithStaleTokenReturnsAlreadyRenewedOne() async {
        let (m, _, t) = make(account(), [])
        let r = await m.forceRefresh(accessToken: "VERALTET", accountId: "konto1")
        XCTAssertEqual(r, "ALT", "ein paralleler Aufruf hat schon erneuert")
        XCTAssertEqual(t.requests.count, 0)
    }

    func testForceRefreshStaysWithRequestedAccount() async {
        let (m, _, _) = make(account(), [])
        let r = await m.forceRefresh(accessToken: "ALT", accountId: "anderes")
        XCTAssertNil(r)
    }

    func testAccountNeedingReauthYieldsNoToken() async {
        let (m, _, t) = make(account(reauth: true), [])
        let token = await m.activeToken()
        XCTAssertNil(token)
        let id = await m.reauthenticationRequired()
        XCTAssertEqual(id, "konto1")
        XCTAssertEqual(t.requests.count, 0)
    }
}
