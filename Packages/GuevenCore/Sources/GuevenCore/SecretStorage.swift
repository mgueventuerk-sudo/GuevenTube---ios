import Foundation
#if canImport(Security)
import Security
#endif

// Sicherer Speicher: ein kleines Backend (Keychain auf Apple, Speicher/Datei für Tests) und die Adapter darauf, die die
// Protokolle der Kernlogik erfüllen. Die Adapter sind plattformunabhängig und unter Linux getestet.

public enum SecretRead: Equatable, Sendable {
    case value(Data)
    case missing
    /// Eintrag vorhanden, aber nicht lesbar (Keychain gesperrt/beschädigt). Fail-closed behandeln.
    case unreadable
}

public protocol SecretBackend: Sendable {
    func read(_ key: String) -> SecretRead
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String)
}

public struct SecretStorageError: Error, Equatable { public let status: Int32; public init(_ s: Int32) { status = s } }

public final class InMemorySecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public var unreadableKeys: Set<String> = []
    public var failWrites = false
    public init() {}
    public func read(_ key: String) -> SecretRead {
        lock.lock(); defer { lock.unlock() }
        if unreadableKeys.contains(key) { return .unreadable }
        return values[key].map { .value($0) } ?? .missing
    }
    public func write(_ key: String, _ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw SecretStorageError(-1) }
        values[key] = value
    }
    public func delete(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

#if canImport(Security)
/// Keychain (generisches Passwort). **Ungetestet bis zum ersten Mac-Lauf.**
/// - `AfterFirstUnlockThisDeviceOnly`: lesbar auch bei gesperrtem Gerät (Hintergrundwiedergabe löst Streams auf),
///   nie in Sicherungen oder auf anderen Geräten.
public struct KeychainSecretBackend: SecretBackend {
    public let service: String
    public init(service: String = "de.gueventube.app") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> SecretRead {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: if let data = out as? Data { return .value(data) } else { return .unreadable }
        case errSecItemNotFound: return .missing
        default: return .unreadable
        }
    }

    public func write(_ key: String, _ value: Data) throws {
        let update: [String: Any] = [kSecValueData as String: value]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { throw SecretStorageError(status) }
    }

    public func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
#endif

// MARK: Adapter

/// `SecretStoring` (visitorData, Kopplungen) auf dem Backend. Unlesbare Einträge zählen als „nicht vorhanden“.
public struct BackendSecretStore: SecretStoring {
    private let backend: SecretBackend
    public init(backend: SecretBackend) { self.backend = backend }
    public func secret(_ key: String) async -> String? {
        if case .value(let d) = backend.read(key) { return String(data: d, encoding: .utf8) }
        return nil
    }
    public func setSecret(_ key: String, _ value: String) async throws { try backend.write(key, Data(value.utf8)) }
    public func removeSecret(_ key: String) async throws { backend.delete(key) }
}

/// `ProfileLockStore`: Geheimnisse im Backend, einfache Werte in einer `StringValueStore` (UserDefaults).
/// Fail-closed: ein unlesbarer PIN-Eintrag zählt als vorhanden.
public struct BackendProfileLockStore: ProfileLockStore {
    private let backend: SecretBackend
    private let plainStore: StringValueStore
    public init(backend: SecretBackend, plain: StringValueStore) { self.backend = backend; self.plainStore = plain }

    public func secret(_ key: String) async -> String? {
        if case .value(let d) = backend.read(key) { return String(data: d, encoding: .utf8) }
        return nil
    }
    public func hasSecretEntry(_ key: String) async -> Bool { backend.read(key) != .missing }
    public func putSecret(_ key: String, _ value: String) async { try? backend.write(key, Data(value.utf8)) }
    public func removeSecret(_ key: String) async { backend.delete(key) }
    /// `StringValueStore` kennt kein Löschen: ein leerer Wert gilt als entfernt.
    public func plain(_ key: String) async -> String? { plainStore.string(key).flatMap { $0.isEmpty ? nil : $0 } }
    public func putPlain(_ values: [String: String?]) async {
        for (k, v) in values { plainStore.setString(v ?? "", for: k) }
    }
}

/// Konten im Backend (Port von `SecurePreferencesRepository`): je Konto ein JSON-Eintrag, dazu Index und aktive ID.
/// Änderungen laufen nacheinander (Actor), damit parallele Token-Erneuerungen nichts überschreiben.
public actor KeychainAccountStore: AccountCredentialStore {
    static let keyIds = "accounts.ids", keyActive = "accounts.active"
    static func key(_ id: String) -> String { "accounts.cred.\(id)" }

    private let backend: SecretBackend
    private let clock: @Sendable () -> Int64

    public init(backend: SecretBackend, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.backend = backend; self.clock = clock
    }

    public func activeCredentials() -> AccountCredentials? {
        guard let id = text(Self.keyActive), !id.isEmpty else { return nil }
        return load(id)
    }
    public func credentials(accountId: String) -> AccountCredentials? { load(accountId) }

    /// Alle Konten, nach Anlagezeitpunkt (unlesbare werden übersprungen).
    public func allAccounts() -> [AccountCredentials] {
        ids().compactMap(load).sorted { $0.createdAtEpochMs < $1.createdAtEpochMs }
    }
    public func activeAccountId() -> String? { text(Self.keyActive).flatMap { $0.isEmpty ? nil : $0 } }

    @discardableResult
    public func upsert(_ credentials: AccountCredentials, makeActive: Bool = true) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials), (try? backend.write(Self.key(credentials.accountId), data)) != nil else { return false }
        var list = ids()
        if !list.contains(credentials.accountId) { list.append(credentials.accountId); saveIds(list) }
        if makeActive { try? backend.write(Self.keyActive, Data(credentials.accountId.utf8)) }
        return true
    }

    @discardableResult
    public func updateTokens(accountId: String, accessToken: String, expiresAtMs: Int64, refreshToken: String?, scope: String?) -> Bool {
        modify(accountId) { a in
            a.accessToken = accessToken; a.accessTokenExpiresAtEpochMs = expiresAtMs
            a.refreshToken = refreshToken ?? a.refreshToken; a.scope = scope ?? a.scope; a.needsReauth = false
        }
    }
    @discardableResult
    public func markNeedsReauth(accountId: String) -> Bool { modify(accountId) { $0.needsReauth = true } }
    @discardableResult
    public func updateProfile(accountId: String, displayName: String, email: String?, avatarUrl: String?, channelId: String?) -> Bool {
        modify(accountId) { $0.displayName = displayName; $0.email = email; $0.avatarUrl = avatarUrl; $0.channelId = channelId }
    }
    @discardableResult
    public func updateSapisid(accountId: String, sapisid: String?) -> Bool { modify(accountId) { $0.sapisid = sapisid } }

    /// `nil` = Gast. `false`, wenn die ID unbekannt ist.
    @discardableResult
    public func setActive(_ accountId: String?) -> Bool {
        guard let accountId else { backend.delete(Self.keyActive); return true }
        guard ids().contains(accountId), load(accountId) != nil else { return false }
        return (try? backend.write(Self.keyActive, Data(accountId.utf8))) != nil
    }

    /// War das Konto aktiv, fällt die App in den Gast-Modus zurück.
    public func remove(_ accountId: String) {
        backend.delete(Self.key(accountId))
        saveIds(ids().filter { $0 != accountId })
        if text(Self.keyActive) == accountId { backend.delete(Self.keyActive) }
    }

    // MARK: intern

    private func modify(_ accountId: String, _ change: (inout AccountCredentials) -> Void) -> Bool {
        guard var a = load(accountId) else { return false }
        change(&a)
        a.updatedAtEpochMs = clock()
        guard let data = try? JSONEncoder().encode(a) else { return false }
        return (try? backend.write(Self.key(accountId), data)) != nil
    }
    private func load(_ id: String) -> AccountCredentials? {
        guard AccountCredentials.isValidAccountId(id), case .value(let d) = backend.read(Self.key(id)) else { return nil }
        return try? JSONDecoder().decode(AccountCredentials.self, from: d)
    }
    private func text(_ key: String) -> String? {
        if case .value(let d) = backend.read(key) { return String(data: d, encoding: .utf8) }
        return nil
    }
    private func ids() -> [String] {
        guard case .value(let d) = backend.read(Self.keyIds), let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list
    }
    private func saveIds(_ list: [String]) {
        if let d = try? JSONEncoder().encode(list) { try? backend.write(Self.keyIds, d) }
    }
}
