import XCTest
@testable import GuevenCore

final class Pbkdf2Tests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { ProfileLock.hex(b) }

    func testHmacMatchesReferenceIncludingLongKey() {
        XCTAssertEqual(hex(Pbkdf2.hmacSHA256(key: Array("key".utf8), message: Array("The quick brown fox jumps over the lazy dog".utf8))),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        XCTAssertEqual(hex(Pbkdf2.hmacSHA256(key: [UInt8](repeating: UInt8(ascii: "k"), count: 100), message: Array("hello".utf8))),
                       "3fd578d761a4f6703009e92d2e8a0aea22ab9ab50d4ad250dc95d8c369dec3f5")
    }

    func testPbkdf2MatchesReferenceVectors() {
        XCTAssertEqual(hex(Pbkdf2.pureSwift(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, length: 64)),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        XCTAssertEqual(hex(Pbkdf2.deriveKey(password: Array("Password".utf8), salt: Array("NaCl".utf8), iterations: 1000)),
                       "c27dad0abae39af4ebb9965719d584e8b4eb2ee69e1fc9f8f4784d1ca68696e2")
    }

    func testProductionIterationCountMatchesReference() {
        XCTAssertEqual(hex(Pbkdf2.deriveKey(password: Array("1234".utf8), salt: Array(0..<16), iterations: ProfileLock.defaultIterations)),
                       "5070321ca34dbdafe9b25371d1c0f83bcafe073fbae1f2274f00a6d6c68e9899")
    }
}

final class PinAttemptsTests: XCTestCase {
    private func fail(_ s: PinAttempts, _ n: Int, now: Int64) -> PinAttempts { (0..<n).reduce(s) { a, _ in a.afterFailure(now: now) } }

    func testFiveFailuresLockAndLockGrows() {
        let first = fail(PinAttempts(), PinAttempts.maxFailures, now: 0)
        XCTAssertEqual(first.remainingLockMs(now: 0), PinAttempts.baseLockMs)
        let second = fail(first, PinAttempts.maxFailures, now: PinAttempts.baseLockMs)
        XCTAssertEqual(second.remainingLockMs(now: PinAttempts.baseLockMs), 2 * PinAttempts.baseLockMs)
        XCTAssertEqual(PinAttempts.lockDurationMs(level: 30), PinAttempts.maxLockMs)
        XCTAssertEqual(PinAttempts.lockDurationMs(level: 7), min(PinAttempts.baseLockMs << 6, PinAttempts.maxLockMs))
    }
    func testSurvivesEncodeDecode() {
        let s = fail(PinAttempts(), 7, now: 1_000)
        XCTAssertEqual(PinAttempts.decode(s.encode()), s)
    }
    func testCorruptCounterIsNotTreatedAsClean() {
        for raw in ["kaputt", "1:2", "1:2:3:4", "-1:0:0", "a:b:c"] {
            XCTAssertGreaterThan(PinAttempts.decode(raw).afterFailure(now: 0).remainingLockMs(now: 0), 0, raw)
        }
        XCTAssertEqual(PinAttempts.decode(nil), PinAttempts())
    }
    func testClockSetBackDoesNotLockForever() {
        let locked = fail(PinAttempts(), PinAttempts.maxFailures, now: 10_000_000)
        XCTAssertEqual(locked.remainingLockMs(now: 0), PinAttempts.baseLockMs)
    }
}

private actor FakeLockStore: ProfileLockStore {
    var secrets: [String: String] = [:]
    var plains: [String: String] = [:]
    var unreadable = false
    func secret(_ key: String) -> String? { unreadable ? nil : secrets[key] }
    func hasSecretEntry(_ key: String) -> Bool { secrets[key] != nil }
    func putSecret(_ key: String, _ value: String) { secrets[key] = value }
    func removeSecret(_ key: String) { secrets[key] = nil }
    func plain(_ key: String) -> String? { plains[key] }
    func putPlain(_ values: [String: String?]) { for (k, v) in values { plains[k] = v } }
    func setUnreadable(_ v: Bool) { unreadable = v }
    func corruptPin(_ value: String) { secrets["profile.pin"] = value }
    func dropPinEntry() { secrets["profile.pin"] = nil }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64
    init(_ v: Int64) { value = v }
    var now: Int64 { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

final class ProfileLockTests: XCTestCase {
    private func make(_ store: FakeLockStore = FakeLockStore(), clock: MutableClock = MutableClock(1_000_000)) -> (ProfileLock, FakeLockStore, MutableClock) {
        (ProfileLock(store: store, clock: { clock.now }, iterations: 5), store, clock)
    }

    func testWithoutPinEverythingIsOpen() async {
        let (lock, _, _) = make()
        let has = await lock.hasPin(); let r = await lock.verify("0000")
        XCTAssertFalse(has); XCTAssertEqual(r, .ok)
    }

    func testSetVerifyAndPinIsNeverStoredInClear() async throws {
        let (lock, store, _) = make()
        try await lock.setPin("4711")
        let has = await lock.hasPin(); let ok = await lock.verify("4711"); let bad = await lock.verify("0000")
        XCTAssertTrue(has); XCTAssertEqual(ok, .ok); XCTAssertEqual(bad, .wrong)
        let stored = await store.secrets["profile.pin"]
        // Salt und Hash sind zufällig/gehasht: „4711“ kann zufällig als Teilfolge vorkommen, darf aber nie ein ganzes Feld sein.
        XCTAssertFalse(stored!.split(separator: ":").contains("4711"))
        XCTAssertEqual(stored!.split(separator: ":").count, 2)
    }

    func testInvalidPinsAreRejected() async {
        let (lock, _, _) = make()
        for pin in ["123", "123456789", "12a4", "", "１２３４"] {
            do { try await lock.setPin(pin); XCTFail(pin) } catch { XCTAssertEqual(error as? ProfileLock.InvalidPin, ProfileLock.InvalidPin()) }
        }
    }

    func testFiveFailuresLockThenExpireAndCorrectPinResets() async throws {
        let (lock, store, clock) = make()
        try await lock.setPin("4711")
        for _ in 0..<4 { let r = await lock.verify("0000"); XCTAssertEqual(r, .wrong) }
        let fifth = await lock.verify("0000")
        XCTAssertEqual(fifth, .wrong)
        let locked = await lock.verify("4711")   // auch die richtige PIN ist gesperrt
        XCTAssertEqual(locked, .locked(seconds: 31))
        clock.now += 31_000
        let after = await lock.verify("4711")
        XCTAssertEqual(after, .ok)
        let counter = await store.plains["profile.pin.attempts"]
        XCTAssertNil(counter, "richtige PIN setzt den Zähler zurück")
    }

    func testLockoutSurvivesRestart() async throws {
        let store = FakeLockStore(); let clock = MutableClock(5_000)
        let (a, _, _) = make(store, clock: clock)
        try await a.setPin("4711")
        for _ in 0..<5 { _ = await a.verify("0000") }
        let (b, _, _) = make(store, clock: clock)   // neuer Prozess, gleicher Speicher
        let r = await b.verify("4711")
        if case .locked = r {} else { XCTFail("Sperre muss den Neustart überstehen: \(r)") }
    }

    func testUnreadableOrMalformedPinFailsClosed() async throws {
        let (lock, store, _) = make()
        try await lock.setPin("4711")
        await store.setUnreadable(true)
        let a = await lock.verify("4711"); XCTAssertEqual(a, .locked(seconds: 30))
        let has = await lock.hasPin(); XCTAssertTrue(has)
        await store.setUnreadable(false)
        for broken in ["kaputt", "zz:zz", "abcd:", ":abcd", "abc:def", "00:11:22"] {
            await store.corruptPin(broken)
            let r = await lock.verify("4711")
            XCTAssertEqual(r, .locked(seconds: 30), broken)
        }
    }

    func testLostKeyCleansMarkerAndOpensSoPinCanBeSetAgain() async throws {
        let (lock, store, _) = make()
        try await lock.setPin("4711")
        await store.dropPinEntry()
        let r = await lock.verify("0000")
        XCTAssertEqual(r, .ok)
        let marker = await store.plains["profile.pin.configured"]
        XCTAssertNil(marker)
        let has = await lock.hasPin()
        XCTAssertFalse(has)
    }

    func testRemovePinOpensProfileAndClearsCounters() async throws {
        let (lock, store, _) = make()
        try await lock.setPin("4711"); _ = await lock.verify("0000")
        await lock.removePin()
        let has = await lock.hasPin(); let r = await lock.verify("irgendwas")
        XCTAssertFalse(has); XCTAssertEqual(r, .ok)
        let counter = await store.plains["profile.pin.attempts"]
        XCTAssertNil(counter)
    }
}

final class KidsTimeTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }
    private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int64 {
        Int64(cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970 * 1000)
    }

    func testInactiveWithoutKidsModeOrLimits() {
        XCTAssertNil(KidsTimeGuard.evaluate(KidsSettings(kidsMode: false, kidsBedtimeHour: 20, kidsDailyLimitMinutes: 1), nowMs: ms(2026, 11, 18, 23), usedSeconds: 9999, unlockedUntil: 0, calendar: cal))
        XCTAssertNil(KidsTimeGuard.evaluate(KidsSettings(kidsMode: true), nowMs: ms(2026, 11, 18, 23), usedSeconds: 9999, unlockedUntil: 0, calendar: cal))
    }

    func testBedtimeWindowWrapsAroundMidnightUntilSeven() {
        let s = KidsSettings(kidsMode: true, kidsBedtimeHour: 20)
        func block(_ h: Int) -> KidsBlock? { KidsTimeGuard.evaluate(s, nowMs: ms(2026, 11, 18, h), usedSeconds: 0, unlockedUntil: 0, calendar: cal) }
        XCTAssertNil(block(19)); XCTAssertNil(block(7)); XCTAssertNil(block(12))
        XCTAssertEqual(block(20)?.reason, "Schlafenszeit – bis 7 Uhr ist Pause.")
        XCTAssertNotNil(block(23)); XCTAssertNotNil(block(0)); XCTAssertNotNil(block(6))
    }

    func testDailyLimitReachedAndUnlockWindow() {
        let s = KidsSettings(kidsMode: true, kidsDailyLimitMinutes: 30)
        let now = ms(2026, 11, 18, 15)
        XCTAssertNil(KidsTimeGuard.evaluate(s, nowMs: now, usedSeconds: 1799, unlockedUntil: 0, calendar: cal))
        XCTAssertEqual(KidsTimeGuard.evaluate(s, nowMs: now, usedSeconds: 1800, unlockedUntil: 0, calendar: cal)?.reason, "Die Zeit für heute (30 Minuten) ist aufgebraucht.")
        XCTAssertNil(KidsTimeGuard.evaluate(s, nowMs: now, usedSeconds: 1800, unlockedUntil: now + 1, calendar: cal))
        XCTAssertNotNil(KidsTimeGuard.evaluate(s, nowMs: now, usedSeconds: 1800, unlockedUntil: now, calendar: cal))
    }

    func testDayKeyDistinguishesDaysAndYears() {
        XCTAssertNotEqual(KidsTimeGuard.dayKey(ms(2026, 11, 18, 10), calendar: cal), KidsTimeGuard.dayKey(ms(2026, 11, 19, 10), calendar: cal))
        XCTAssertEqual(KidsTimeGuard.dayKey(ms(2026, 1, 1, 0, 5), calendar: cal), 2026 * 1000 + 1)
        XCTAssertNotEqual(KidsTimeGuard.dayKey(ms(2025, 5, 5, 10), calendar: cal), KidsTimeGuard.dayKey(ms(2026, 5, 5, 10), calendar: cal))
    }

    func testTickCountsOnlyWhilePlayingInKidsModeAndResetsNextDay() async {
        let lock = ProfileLock(store: FakeLockStore(), iterations: 1)
        let guardian = KidsTimeGuard(usage: InMemoryKidsUsageStore(), profileLock: lock, calendar: cal, nowMs: { 0 })
        let s = KidsSettings(kidsMode: true, kidsDailyLimitMinutes: 1)
        let day1 = ms(2026, 11, 18, 15)
        for _ in 0..<3 { await guardian.tick(settings: s, playing: false, at: day1) }
        var b = await guardian.tick(settings: s, playing: true, at: day1)   // 15 s
        XCTAssertNil(b)
        for _ in 0..<3 { b = await guardian.tick(settings: s, playing: true, at: day1) }   // 60 s
        XCTAssertNotNil(b)
        let notKids = await guardian.tick(settings: KidsSettings(kidsMode: false, kidsDailyLimitMinutes: 1), playing: true, at: day1)
        XCTAssertNil(notKids)
        let nextDay = await guardian.tick(settings: s, playing: false, at: ms(2026, 11, 19, 15))
        XCTAssertNil(nextDay, "neuer Tag: Zähler bei 0")
    }

    func testUnlockWithPinClearsBlockAndReportsErrors() async throws {
        let store = FakeLockStore(); let clock = MutableClock(1_000_000)
        let lock = ProfileLock(store: store, clock: { clock.now }, iterations: 3)
        try await lock.setPin("4711")
        let guardian = KidsTimeGuard(usage: InMemoryKidsUsageStore(), profileLock: lock, calendar: cal, nowMs: { clock.now })
        let s = KidsSettings(kidsMode: true, kidsDailyLimitMinutes: 1)
        let now = ms(2026, 11, 18, 15)
        for _ in 0..<4 { await guardian.tick(settings: s, playing: true, at: now) }
        let blocked = await guardian.block
        XCTAssertNotNil(blocked)
        let wrong = await guardian.unlock(pin: "0000")
        XCTAssertEqual(wrong, "Falsche PIN.")
        let ok = await guardian.unlock(pin: "4711")
        XCTAssertNil(ok)
        let cleared = await guardian.block
        XCTAssertNil(cleared)
        for _ in 0..<5 { _ = await guardian.unlock(pin: "0000") }
        let locked = await guardian.unlock(pin: "4711")
        XCTAssertEqual(locked, "Zu viele Versuche – bitte 31 s warten.")
    }
}

final class SubscriptionImportTests: XCTestCase {
    private let a = "UC" + String(repeating: "a", count: 22)
    private let b = "UC" + String(repeating: "B_-1", count: 5) + "xy"

    func testTakeoutCsvWithHeaderBomAndQuotedTitle() {
        let csv = "\u{FEFF}Kanal-ID,Kanal-URL,Kanaltitel\n\(a),http://www.youtube.com/channel/\(a),Einfach\n\(b),http://www.youtube.com/channel/\(b),\"Mit, Komma und \"\"Zitat\"\"\"\n\(a),http://www.youtube.com/channel/\(a),Doppelt\n"
        XCTAssertEqual(SubscriptionImport.parse(csv), [.init(channelId: a, name: "Einfach"), .init(channelId: b, name: "Mit, Komma und \"Zitat\"")])
    }
    func testCrLfLinesAndMissingTitleFallsBackToId() {
        let csv = "\(a),http://x\r\n\(b),http://y,\r\n"
        XCTAssertEqual(SubscriptionImport.parse(csv).map(\.name), [a, b])
    }
    func testNewPipeJson() {
        let json = #"{"app_version":"0.27","subscriptions":[{"service_id":0,"url":"https://www.youtube.com/channel/\#(a)","name":"Kanal A"},{"url":"https://example.org/x","name":"Kaputt"}]}"#
        XCTAssertEqual(SubscriptionImport.parse(json), [.init(channelId: a, name: "Kanal A")])
    }
    func testFallbackFindsBareIds() {
        XCTAssertEqual(SubscriptionImport.parse("irgendwas \(a)\nund \(b)").map(\.channelId), [a, b])
    }
    func testGarbageGivesEmptyList() {
        XCTAssertEqual(SubscriptionImport.parse("{kaputt"), [])
        XCTAssertEqual(SubscriptionImport.parse(""), [])
        XCTAssertEqual(SubscriptionImport.parse(#"{"subscriptions":[{"url":{"x":1},"name":"A"}]}"#), [])
    }
}

final class ChannelPreferencesTests: XCTestCase {
    func testStoresSpeedAndHeightAndPersists() {
        let store = InMemoryStringStore()
        let p = ChannelPreferences(store: store)
        p.update("UC1") { var x = $0; x.speed = 1.5; return x }
        p.update("UC1") { var x = $0; x.maxHeight = 720; return x }
        XCTAssertEqual(p.get("UC1"), ChannelPrefs(speed: 1.5, maxHeight: 720))
        XCTAssertEqual(ChannelPreferences(store: store).get("UC1"), ChannelPrefs(speed: 1.5, maxHeight: 720))
        XCTAssertNil(p.get("UC2")); XCTAssertNil(p.get(nil))
    }
    func testEmptyPrefsRemoveTheChannel() {
        let p = ChannelPreferences(store: InMemoryStringStore())
        p.update("UC1") { var x = $0; x.speed = 2; return x }
        p.update("UC1") { _ in ChannelPrefs() }
        XCTAssertNil(p.get("UC1"))
        p.update("UC1") { _ in nil }
        XCTAssertNil(p.get("UC1"))
    }
    func testKeepsMostRecentlyAddedThreeHundred() {
        let p = ChannelPreferences(store: InMemoryStringStore())
        for i in 0..<310 { p.update("UC\(i)") { var x = $0; x.maxHeight = 480; return x } }
        XCTAssertNil(p.get("UC0")); XCTAssertNil(p.get("UC9")); XCTAssertNotNil(p.get("UC10")); XCTAssertNotNil(p.get("UC309"))
    }
    func testClearAndCorruptStorage() {
        let store = InMemoryStringStore()
        store.setString("{kaputt", for: "channels")
        let p = ChannelPreferences(store: store)
        XCTAssertNil(p.get("UC1"))
        p.update("UC1") { var x = $0; x.speed = 1.25; return x }
        p.clear()
        XCTAssertNil(p.get("UC1"))
        XCTAssertNil(ChannelPreferences(store: store).get("UC1"))
    }
}
