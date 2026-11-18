import XCTest
@testable import GuevenCore

private func account(_ id: String, created: Int64 = 1) -> AccountCredentials {
    try! AccountCredentials(accountId: id, displayName: "A", accessToken: "acc", accessTokenExpiresAtEpochMs: 10, refreshToken: "ref",
                            createdAtEpochMs: created, updatedAtEpochMs: created)
}

final class SecretStorageTests: XCTestCase {
    func testSecretStoreRoundTripAndRemove() async throws {
        let store = BackendSecretStore(backend: InMemorySecretBackend())
        let missing = await store.secret("k")
        XCTAssertNil(missing)
        try await store.setSecret("k", "wert äö")
        let got = await store.secret("k")
        XCTAssertEqual(got, "wert äö")
        try await store.removeSecret("k")
        let gone = await store.secret("k")
        XCTAssertNil(gone)
    }

    func testUnreadableSecretCountsAsAbsentForPlainStore() async {
        let backend = InMemorySecretBackend()
        try? backend.write("k", Data("x".utf8))
        backend.unreadableKeys = ["k"]
        let value = await BackendSecretStore(backend: backend).secret("k")
        XCTAssertNil(value)
    }

    func testAccountsUpsertActiveSwitchAndRemove() async {
        let store = KeychainAccountStore(backend: InMemorySecretBackend(), clock: { 777 })
        let none = await store.activeCredentials()
        XCTAssertNil(none, "Gast ohne aktives Konto")
        await store.upsert(account("konto-b", created: 20))
        await store.upsert(account("konto-a", created: 10), makeActive: false)
        let active = await store.activeAccountId()
        XCTAssertEqual(active, "konto-b")
        let all = await store.allAccounts().map(\.accountId)
        XCTAssertEqual(all, ["konto-a", "konto-b"], "nach Anlagezeitpunkt")
        let switched = await store.setActive("konto-a"), unknown = await store.setActive("gibt-es-nicht")
        XCTAssertTrue(switched); XCTAssertFalse(unknown)
        let nowActive = await store.activeCredentials()
        XCTAssertEqual(nowActive?.accountId, "konto-a")
        await store.remove("konto-a")
        let afterRemove = await store.activeCredentials()
        XCTAssertNil(afterRemove, "aktives Konto entfernt → Gast")
        let remaining = await store.allAccounts().map(\.accountId)
        XCTAssertEqual(remaining, ["konto-b"])
    }

    func testUpdateTokensKeepsRefreshTokenClearsReauthAndStampsTime() async {
        let store = KeychainAccountStore(backend: InMemorySecretBackend(), clock: { 777 })
        await store.upsert(account("k1"))
        let marked = await store.markNeedsReauth(accountId: "k1")
        XCTAssertTrue(marked)
        let ok = await store.updateTokens(accountId: "k1", accessToken: "neu", expiresAtMs: 99, refreshToken: nil, scope: "s")
        XCTAssertTrue(ok)
        let a = await store.credentials(accountId: "k1")!
        XCTAssertEqual(a.accessToken, "neu"); XCTAssertEqual(a.refreshToken, "ref"); XCTAssertEqual(a.scope, "s")
        XCTAssertFalse(a.needsReauth); XCTAssertEqual(a.updatedAtEpochMs, 777)
        let missing = await store.updateTokens(accountId: "nix", accessToken: "x", expiresAtMs: 1, refreshToken: nil, scope: nil)
        XCTAssertFalse(missing)
    }

    func testFailedWriteDoesNotClaimSuccess() async {
        let backend = InMemorySecretBackend()
        let store = KeychainAccountStore(backend: backend)
        backend.failWrites = true
        let saved = await store.upsert(account("k1"))
        XCTAssertFalse(saved)
        let all = await store.allAccounts()
        XCTAssertTrue(all.isEmpty)
    }

    func testCorruptAccountEntryIsSkippedNotCrashing() async {
        let backend = InMemorySecretBackend()
        let store = KeychainAccountStore(backend: backend)
        await store.upsert(account("k1")); await store.upsert(account("k2"), makeActive: false)
        try? backend.write("accounts.cred.k1", Data("kaputt".utf8))
        let active = await store.activeCredentials()
        XCTAssertNil(active)
        let all = await store.allAccounts().map(\.accountId)
        XCTAssertEqual(all, ["k2"])
    }

    func testProfileLockStoreFailClosedOnUnreadablePin() async throws {
        let backend = InMemorySecretBackend()
        let store = BackendProfileLockStore(backend: backend, plain: InMemoryStringStore())
        let lock = ProfileLock(store: store, iterations: 10)
        let before = await lock.hasPin()
        XCTAssertFalse(before)
        try await lock.setPin("1234")
        let v1 = await lock.verify("1234"), v2 = await lock.verify("0000")
        XCTAssertEqual(v1, .ok); XCTAssertEqual(v2, .wrong)
        // PIN-Eintrag wird unlesbar → weiterhin „PIN gesetzt“, nie „ohne PIN“.
        backend.unreadableKeys = ["profile.pin"]
        let still = await lock.hasPin()
        XCTAssertTrue(still)
        let v3 = await lock.verify("1234")
        XCTAssertNotEqual(v3, .ok)
        backend.unreadableKeys = []
        await lock.removePin()
        let after = await lock.hasPin()
        XCTAssertFalse(after)
    }

    func testPlainValuesAndRemovalViaNil() async {
        let store = BackendProfileLockStore(backend: InMemorySecretBackend(), plain: InMemoryStringStore())
        await store.putPlain(["a": "1", "b": "2"])
        await store.putPlain(["a": nil])
        let a = await store.plain("a"), b = await store.plain("b")
        XCTAssertNil(a); XCTAssertEqual(b, "2")
    }
}
