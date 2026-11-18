import Foundation

/// Schutz der Kopplung: Nach 5 gescheiterten Versuchen innerhalb von 10 Minuten wird die Adresse 5 Minuten gesperrt.
/// Gekoppelte Geräte, die sich normal verbinden, sind nicht betroffen.
public final class PairingGuard: @unchecked Sendable {
    public static let maxFailures = 5
    public static let windowMs: Int64 = 10 * 60 * 1000
    public static let lockMs: Int64 = 5 * 60 * 1000
    private let lock = NSLock()
    private let nowMs: @Sendable () -> Int64
    private var failures: [String: [Int64]] = [:]
    private var lockedUntil: [String: Int64] = [:]
    public init(nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.nowMs = nowMs }

    public func allowed(_ address: String) -> Bool {
        lock.withLock {
            guard let until = lockedUntil[address] else { return true }
            if nowMs() >= until { lockedUntil[address] = nil; return true }
            return false
        }
    }
    /// `true`, wenn die Adresse durch diesen Fehlschlag gesperrt wurde.
    @discardableResult
    public func recordFailure(_ address: String) -> Bool {
        lock.withLock {
            let now = nowMs()
            var list = (failures[address] ?? []) + [now]
            list.removeAll { now - $0 > Self.windowMs }
            if list.count >= Self.maxFailures { lockedUntil[address] = now + Self.lockMs; failures[address] = []; return true }
            failures[address] = list; return false
        }
    }
    public func recordSuccess(_ address: String) { lock.withLock { failures[address] = nil } }
}

/// Protokoll der Kopplungen und Verbindungsversuche: die letzten 30, nur lokal.
public final class LinkAuditLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable { public var atMs: Int64; public var text: String }
    static let key = "link_audit", maxEntries = 30, maxText = 120
    private let store: StringValueStore
    private let nowMs: @Sendable () -> Int64
    private let lock = NSLock()
    public init(store: StringValueStore, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.store = store; self.nowMs = nowMs }

    public func entries() -> [Entry] { lock.withLock { load() } }
    public func add(_ text: String) {
        lock.withLock {
            let updated = Array(([Entry(atMs: nowMs(), text: String(text.prefix(Self.maxText)))] + load()).prefix(Self.maxEntries))
            if let d = try? JSONEncoder().encode(updated) { store.setString(String(decoding: d, as: UTF8.self), for: Self.key) }
        }
    }
    public func clear() { lock.withLock { store.setString("[]", for: Self.key) } }
    private func load() -> [Entry] { store.string(Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: Data($0.utf8)) } ?? [] }
}

/// Gespeicherte Kopplungen und die eigene Geräte-ID im sicheren Speicher (iOS: Keychain).
public actor LinkStore {
    static let keyDevices = "link.devices", keyDeviceId = "link.device_id", maxDevices = 8
    private let secrets: SecretStoring
    private let model: String
    public init(secrets: SecretStoring, deviceModel: String) { self.secrets = secrets; self.model = deviceModel }

    public func deviceId() async -> String {
        if let id = await secrets.secret(Self.keyDeviceId), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? await secrets.setSecret(Self.keyDeviceId, id)
        return id
    }
    public func deviceName() -> String { model.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone" : model }

    public func load() async -> [PairedDevice] {
        await secrets.secret(Self.keyDevices).flatMap { try? JSONDecoder().decode([PairedDevice].self, from: Data($0.utf8)) } ?? []
    }
    /// Ersetzt ein Gerät mit gleicher ID; behält höchstens 8 (die zuletzt gespeicherten).
    public func save(_ device: PairedDevice) async throws {
        let updated = Array((await load().filter { $0.id != device.id } + [device]).suffix(Self.maxDevices))
        try await persist(updated)
    }
    public func remove(_ deviceId: String) async throws { try await persist(await load().filter { $0.id != deviceId }) }
    private func persist(_ d: [PairedDevice]) async throws { try await secrets.setSecret(Self.keyDevices, String(decoding: try JSONEncoder().encode(d), as: UTF8.self)) }
}
