import XCTest
@testable import GuevenCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var items: [DeviceAuthState] = []
    func add(_ s: DeviceAuthState) { lock.withLock { items.append(s) } }
    var states: [DeviceAuthState] { lock.withLock { items } }
}

private final class FakeOAuth: DeviceAuthOAuth, @unchecked Sendable {
    let lock = NSLock()
    var polls: [TokenPollResult]
    var codeError: Error?
    var pollCount = 0
    init(polls: [TokenPollResult], codeError: Error? = nil) { self.polls = polls; self.codeError = codeError }
    func clientCredentials() async throws -> OAuthClientCredentials { OAuthClientCredentials(clientId: "cid", clientSecret: "sec") }
    func requestDeviceCode(client: OAuthClientCredentials?) async throws -> DeviceCodeResponse {
        if let codeError { throw codeError }
        return DeviceCodeResponse(deviceCode: "dev", userCode: "ABC-DEF", verificationUrl: "https://www.google.com/device",
                                  expiresInSeconds: 600, intervalSeconds: 2)
    }
    func pollToken(deviceCode: String, client: OAuthClientCredentials?) async throws -> TokenPollResult {
        lock.withLock { pollCount += 1; return polls.isEmpty ? .pending : polls.removeFirst() }
    }
}

private struct FakeProfiles: DeviceAuthProfileSource {
    var info: AccountInfo?
    var fail = false
    func accountInfo(accessToken: String) async throws -> AccountInfo? {
        if fail { throw OAuthError(error: "x", message: "kaputt") }
        return info
    }
}

private actor FakeAccounts: DeviceAuthAccountStore {
    var saved: [AccountCredentials] = []
    var existing: AccountCredentials?
    var failSave = false
    func setExisting(_ a: AccountCredentials?) { existing = a }
    func credentialsForChannel(_ channelId: String) -> AccountCredentials? { existing?.channelId == channelId ? existing : nil }
    func saveActive(_ c: AccountCredentials) -> Bool { if failSave { return false }; saved.append(c); return true }
}

final class DeviceAuthFlowTests: XCTestCase {
    private let tokens = TokenResponse(accessToken: "at", expiresInSeconds: 3600, refreshToken: "rt", scope: "s")
    private let info = AccountInfo(displayName: "Max", byline: "max@example.com", avatarUrl: "https://a/x.png", channelId: "UC123")

    private func flow(_ oauth: FakeOAuth, profiles: FakeProfiles, store: FakeAccounts, clock: Clock = Clock()) -> DeviceAuthFlow {
        DeviceAuthFlow(oauth: oauth, profiles: profiles, store: store, nowMs: { clock.now }, sleepMs: { clock.advance($0) })
    }
    private final class Clock: @unchecked Sendable {
        let lock = NSLock(); private var t: Int64 = 1_000
        var now: Int64 { lock.withLock { t } }
        func advance(_ ms: Int64) { lock.withLock { t += ms } }
    }

    func testSuccessAfterPendingSavesActiveAccountWithProfile() async {
        let store = FakeAccounts(); let log = Log()
        let result = await flow(FakeOAuth(polls: [.pending, .success(tokens)]), profiles: FakeProfiles(info: info), store: store).run(log.add)
        guard case .success(let id, let name) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(name, "Max")
        let saved = await store.saved
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].accountId, id)
        XCTAssertEqual(saved[0].channelId, "UC123")
        XCTAssertEqual(saved[0].email, "max@example.com")
        XCTAssertEqual(saved[0].oauthClientId, "cid")
        XCTAssertEqual(log.states.first, .requestingCode)
        XCTAssertTrue(log.states.contains(.completing))
        guard case .awaitingUser(let code, _, let qr, _) = log.states[1] else { return XCTFail() }
        XCTAssertEqual(code, "ABC-DEF")
        XCTAssertEqual(qr, "https://www.google.com/device?user_code=ABC-DEF")
    }

    func testPendingCodeIsPublishedAndClearedAndCanBeResumed() async {
        // 1) Ein neuer Code wird zum Speichern gemeldet und nach Abschluss wieder gelöscht.
        final class Pending: @unchecked Sendable { let lock = NSLock(); var values: [PendingDeviceAuth?] = []; func add(_ p: PendingDeviceAuth?) { lock.withLock { values.append(p) } } }
        let pending = Pending()
        let first = await flow(FakeOAuth(polls: [.success(tokens)]), profiles: FakeProfiles(info: info), store: FakeAccounts())
            .run(resume: nil, onPending: pending.add, report: { _ in })
        guard case .success = first else { return XCTFail("\(first)") }
        XCTAssertEqual(pending.values.count, 2)
        XCTAssertEqual(pending.values[0]?.deviceCode, "dev"); XCTAssertEqual(pending.values[0]?.clientId, "cid")
        XCTAssertNil(pending.values[1], "nach Erfolg gelöscht")

        // 2) Nach einem App-Neustart wird der gespeicherte Code fortgesetzt, ohne einen neuen anzufordern (hier würde das scheitern).
        let saved = PendingDeviceAuth(deviceCode: "dev", userCode: "ABC-DEF", verificationUrl: "https://www.google.com/device",
                                      expiresAtMs: 600_000, intervalSeconds: 5, clientId: "cid", clientSecret: "sec")
        let oauth = FakeOAuth(polls: [.pending, .success(tokens)], codeError: OAuthError(error: "e", message: "darf nicht aufgerufen werden"))
        let log = Log()
        let resumed = await flow(oauth, profiles: FakeProfiles(info: info), store: FakeAccounts())
            .run(resume: saved, onPending: { _ in }, report: log.add)
        guard case .success = resumed else { return XCTFail("\(resumed)") }
        guard case .awaitingUser(let code, _, _, _) = log.states[1] else { return XCTFail() }
        XCTAssertEqual(code, "ABC-DEF")

        // 3) Ein abgelaufener gespeicherter Code wird verworfen und ein neuer angefordert.
        let expired = PendingDeviceAuth(deviceCode: "alt", userCode: "OLD", verificationUrl: "https://www.google.com/device",
                                        expiresAtMs: 10, intervalSeconds: 5, clientId: "cid", clientSecret: "sec")
        let fresh = await flow(FakeOAuth(polls: [.success(tokens)]), profiles: FakeProfiles(info: info), store: FakeAccounts())
            .run(resume: expired, onPending: { _ in }, report: { _ in })
        guard case .success = fresh else { return XCTFail("\(fresh)") }
    }

    func testSameChannelReplacesExistingAccount() async throws {
        let store = FakeAccounts()
        let old = try AccountCredentials(accountId: "alt", displayName: "Alt", channelId: "UC123", accessToken: "o", accessTokenExpiresAtEpochMs: 0,
                                         refreshToken: "or", tokenType: "Bearer", scope: nil, createdAtEpochMs: 42, updatedAtEpochMs: 42)
        await store.setExisting(old)
        let result = await flow(FakeOAuth(polls: [.success(tokens)]), profiles: FakeProfiles(info: info), store: store).run { _ in }
        XCTAssertEqual(result, .success(accountId: "alt", displayName: "Max"))
        let saved = await store.saved
        XCTAssertEqual(saved.first?.createdAtEpochMs, 42)
    }

    func testProfileFailureStillSavesWithDefaultName() async {
        let store = FakeAccounts()
        let result = await flow(FakeOAuth(polls: [.success(tokens)]), profiles: FakeProfiles(fail: true), store: store).run { _ in }
        guard case .success(_, let name) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(name, "Google-Konto")
    }

    func testMissingRefreshTokenFails() async {
        let store = FakeAccounts()
        let result = await flow(FakeOAuth(polls: [.success(TokenResponse(accessToken: "at"))]), profiles: FakeProfiles(info: info), store: store).run { _ in }
        XCTAssertEqual(result, .failed("Google hat keinen Refresh-Token geliefert."))
        let saved = await store.saved
        XCTAssertTrue(saved.isEmpty)
    }

    func testDeniedExpiredAndTimeout() async {
        let s = FakeAccounts()
        let denied = await flow(FakeOAuth(polls: [.denied]), profiles: FakeProfiles(), store: s).run { _ in }
        XCTAssertEqual(denied, .failed("Die Anmeldung wurde abgelehnt."))
        let expired = await flow(FakeOAuth(polls: [.expired]), profiles: FakeProfiles(), store: s).run { _ in }
        XCTAssertEqual(expired, .failed("Der Code ist abgelaufen. Bitte neu starten."))
        // Nie bestätigt: läuft nach 600 s ab, Fehlschläge beim Pollen werden toleriert.
        let oauth = FakeOAuth(polls: Array(repeating: .failure("netz"), count: 5))
        let timeout = await flow(oauth, profiles: FakeProfiles(), store: s).run { _ in }
        XCTAssertEqual(timeout, .failed("Der Code ist abgelaufen. Bitte neu starten."))
        XCTAssertGreaterThan(oauth.pollCount, 5)
    }

    func testPermanentPollErrorsAreReportedInsteadOfWaiting() async {
        let rejected = await flow(FakeOAuth(polls: [.failure("invalid_client")]), profiles: FakeProfiles(), store: FakeAccounts()).run { _ in }
        XCTAssertEqual(rejected, .failed("Google hat die Anmeldung abgelehnt (invalid_client). Bitte später erneut versuchen."))
        let offline = FakeOAuth(polls: Array(repeating: .failure("URLError"), count: 12))
        let result = await flow(offline, profiles: FakeProfiles(), store: FakeAccounts()).run { _ in }
        XCTAssertEqual(result, .failed("Anmeldung nicht möglich: URLError. Prüfe die Internetverbindung."))
        XCTAssertEqual(offline.pollCount, 12)
    }

    func testSlowDownLengthensInterval() async {
        let oauth = FakeOAuth(polls: [.slowDown, .slowDown])
        // Intervall: max(2,5)=5 s → 10 s → 15 s …; 600 s Gesamtzeit ergibt weniger Abfragen als bei konstanten 5 s (120).
        _ = await flow(oauth, profiles: FakeProfiles(), store: FakeAccounts()).run { _ in }
        XCTAssertLessThan(oauth.pollCount, 120)
    }

    func testCodeRequestFailureAndCancellation() async {
        let failed = await flow(FakeOAuth(polls: [], codeError: OAuthError(error: "e", message: "offline")), profiles: FakeProfiles(), store: FakeAccounts()).run { _ in }
        XCTAssertEqual(failed, .failed("Anmeldecode konnte nicht angefordert werden: offline"))
        let cancelled = await flow(FakeOAuth(polls: [], codeError: CancellationError()), profiles: FakeProfiles(), store: FakeAccounts()).run { _ in }
        XCTAssertEqual(cancelled, .idle)
    }

    func testSaveFailureReported() async {
        let store = FakeAccounts()
        await store.setFailSave()
        let result = await flow(FakeOAuth(polls: [.success(tokens)]), profiles: FakeProfiles(info: info), store: store).run { _ in }
        XCTAssertEqual(result, .failed("Konto konnte nicht gespeichert werden."))
    }
}

private extension FakeAccounts { func setFailSave() { failSave = true } }
