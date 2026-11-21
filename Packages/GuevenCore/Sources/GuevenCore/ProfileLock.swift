import Foundation

/// Fehlversuche der PIN (rein, testbar). Nach `maxFailures` Fehlern folgt eine Sperre; jede weitere Sperre verdoppelt die
/// Dauer bis `maxLockMs`. Erst eine richtige PIN setzt alles zurück.
public struct PinAttempts: Equatable, Sendable {
    public static let maxFailures = 5
    public static let baseLockMs: Int64 = 30_000
    public static let maxLockMs: Int64 = 60 * 60 * 1000
    private static let maxLevel: Int64 = 64

    public var failures = 0
    public var lockouts = 0
    public var lockedUntilMs: Int64 = 0

    public init(failures: Int = 0, lockouts: Int = 0, lockedUntilMs: Int64 = 0) {
        self.failures = failures; self.lockouts = lockouts; self.lockedUntilMs = lockedUntilMs
    }

    public static func lockDurationMs(level: Int) -> Int64 {
        if level >= 8 { return maxLockMs }
        return min(baseLockMs << Int64(max(level - 1, 0)), maxLockMs)
    }

    /// Verbleibende Sperrzeit; höchstens die Dauer der aktuellen Stufe (zurückgestellte Uhr ≠ Dauersperre).
    public func remainingLockMs(now: Int64) -> Int64 {
        let cap = lockouts > 0 ? Self.lockDurationMs(level: lockouts) : 0
        return min(max(lockedUntilMs - now, 0), cap)
    }

    public func afterFailure(now: Int64) -> PinAttempts {
        let failed = failures + 1
        if failed < Self.maxFailures { var copy = self; copy.failures = failed; return copy }
        let level = lockouts + 1
        return PinAttempts(failures: 0, lockouts: level, lockedUntilMs: now + Self.lockDurationMs(level: level))
    }

    public func encode() -> String { "\(failures):\(lockouts):\(lockedUntilMs)" }

    /// Unlesbarer Zähler gilt nicht als „keine Fehler“: der nächste Fehlversuch sperrt (fail-closed).
    public static func decode(_ raw: String?) -> PinAttempts {
        guard let raw else { return PinAttempts() }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int64($0) }
        if parts.count != 3 || raw.split(separator: ":", omittingEmptySubsequences: false).count != 3 || parts.contains(where: { $0 < 0 }) {
            return PinAttempts(failures: maxFailures - 1)
        }
        return PinAttempts(failures: Int(min(parts[0], Int64(maxFailures))), lockouts: Int(min(parts[1], maxLevel)), lockedUntilMs: parts[2])
    }
}

/// Ablage für Profil-PIN und Zähler (iOS: Keychain für Geheimnisse, UserDefaults für den Rest).
public protocol ProfileLockStore: Sendable {
    /// `nil`, wenn der Eintrag fehlt **oder** nicht lesbar ist.
    func secret(_ key: String) async -> String?
    /// `true`, auch wenn der Eintrag gerade nicht lesbar ist.
    func hasSecretEntry(_ key: String) async -> Bool
    func putSecret(_ key: String, _ value: String) async
    func removeSecret(_ key: String) async
    func plain(_ key: String) async -> String?
    /// `nil`-Wert entfernt den Schlüssel.
    func putPlain(_ values: [String: String?]) async
}

/// Profil-PIN und Kindermodus. Die PIN wird nie gespeichert, nur ein gesalzener PBKDF2-Hash (120 000 Runden). Nach 5
/// Fehlversuchen Sperre mit wachsender Dauer (30 s … 1 h); Zähler und Sperrzeit überstehen einen Neustart.
/// Fail-closed: Ist ein PIN-Eintrag vorhanden, aber nicht lesbar, gilt das Profil als gesperrt – nie als „ohne PIN“.
public actor ProfileLock {
    public enum VerifyResult: Equatable, Sendable { case ok, wrong, locked(seconds: Int64) }
    public struct InvalidPin: Error, Equatable {}
    /// Der Schlüsselbund hat die PIN nicht gespeichert.
    public struct StorageFailed: Error, Equatable { public init() {} }

    static let keyPin = "profile.pin"
    static let keyPinConfigured = "profile.pin.configured"
    static let keyAttempts = "profile.pin.attempts"
    static let flagSet = "1"
    public static let defaultIterations = 120_000
    static let unreadableRetrySeconds: Int64 = 30

    private let store: ProfileLockStore
    private let clock: @Sendable () -> Int64
    private let gate = AsyncLimiter(1)
    private let iterations: Int

    public init(store: ProfileLockStore, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                iterations: Int = ProfileLock.defaultIterations) {
        self.store = store; self.clock = clock; self.iterations = iterations
    }

    /// Auch ein gerade nicht entschlüsselbarer Eintrag zählt als gesetzte PIN.
    public func hasPin() async -> Bool {
        if await store.plain(Self.keyPinConfigured) == Self.flagSet { return true }
        return await store.hasSecretEntry(Self.keyPin)
    }

    public func setPin(_ pin: String) async throws {
        guard (4...8).contains(pin.utf8.count), pin.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw InvalidPin() }
        var rng = SystemRandomNumberGenerator()
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let hash = derive(pin, salt)
        await gate.acquire()
        await store.putSecret(Self.keyPin, "\(Self.hex(salt)):\(Self.hex(hash))")
        // `putSecret` meldet Schreibfehler nicht: ohne Nachprüfung stünde „PIN gesetzt“, aber kein Hash im Speicher.
        guard await store.hasSecretEntry(Self.keyPin) else { await gate.release(); throw StorageFailed() }
        await store.putPlain([Self.keyPinConfigured: Self.flagSet, Self.keyAttempts: nil])
        await gate.release()
    }

    public func removePin() async {
        await gate.acquire()
        await store.removeSecret(Self.keyPin)
        await store.putPlain([Self.keyPinConfigured: nil, Self.keyAttempts: nil])
        await gate.release()
    }

    /// Prüft die PIN. Ohne gesetzte PIN `ok`; unlesbare oder beschädigte PIN ergibt `locked` (fail-closed).
    public func verify(_ pin: String) async -> VerifyResult {
        await gate.acquire()
        let result = await verifyLocked(pin)
        await gate.release()
        return result
    }

    private func verifyLocked(_ pin: String) async -> VerifyResult {
        guard let stored = await store.secret(Self.keyPin) else {
            if await store.hasSecretEntry(Self.keyPin) { return .locked(seconds: Self.unreadableRetrySeconds) }
            if await store.plain(Self.keyPinConfigured) == Self.flagSet {
                // Eintrag fehlt trotz Markierung (Schlüsselverlust): Markierung aufräumen, PIN neu setzen lassen.
                await store.putPlain([Self.keyPinConfigured: nil, Self.keyAttempts: nil])
            }
            return .ok
        }
        let now = clock()
        let attempts = PinAttempts.decode(await store.plain(Self.keyAttempts))
        let remaining = attempts.remainingLockMs(now: now)
        if remaining > 0 { return .locked(seconds: remaining / 1000 + 1) }
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let salt = Self.unhex(parts[0]), let expected = Self.unhex(parts[1]), !salt.isEmpty, !expected.isEmpty else {
            return .locked(seconds: Self.unreadableRetrySeconds)
        }
        if Self.constantTimeEqual(derive(pin, salt), expected) {
            if attempts != PinAttempts() { await store.putPlain([Self.keyAttempts: nil]) }
            return .ok
        }
        await store.putPlain([Self.keyAttempts: attempts.afterFailure(now: now).encode()])
        return .wrong
    }

    private nonisolated func derive(_ pin: String, _ salt: [UInt8]) -> [UInt8] {
        Pbkdf2.deriveKey(password: Array(pin.utf8), salt: salt, iterations: iterations)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0, chars.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }) else { return nil }
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(decoding: chars[$0...$0 + 1], as: UTF8.self), radix: 16)! }
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
