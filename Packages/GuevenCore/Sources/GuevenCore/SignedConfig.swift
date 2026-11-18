import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Verweis auf ein Entschlüssler-Skript; die Prüfsumme steht im signierten Paket.
public struct SolverRef: Equatable, Sendable, Decodable {
    public var url: String
    public var sha256: String
    public var version: String
}

/// Signiertes Fernkonfigurations-Paket: Abspielwege, Entschlüssler-Verweis und Notschalter ohne neue App-Version.
public struct SignedConfig: Equatable, Sendable {
    public var schema: Int
    /// Nie fallend (Rückspielschutz).
    public var version: Int64
    public var issuedAt: String?
    public var clients: [PlayerClientProfile]?
    public var solver: SolverRef?
    public var flags: [String: Bool]
    public func flag(_ name: String, default d: Bool = false) -> Bool { flags[name] ?? d }
}

public struct SignedConfigError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(_ m: String) { message = m }
}

/// Prüft eine ECDSA-P-256/SHA-256-Signatur (DER) über die exakten Bytes.
public protocol SignatureVerifying: Sendable {
    func isValid(signature: Data, for message: Data) -> Bool
}

#if canImport(CryptoKit)
/// Produktiver Prüfer auf Apple-Systemen (CryptoKit). Schlüssel: X.509/SPKI in Base64 – derselbe wie bei Android.
public struct CryptoKitSignatureVerifier: SignatureVerifying {
    private let key: P256.Signing.PublicKey
    public init?(spkiBase64: String) {
        guard let der = Data(base64Encoded: spkiBase64), let k = try? P256.Signing.PublicKey(derRepresentation: der) else { return nil }
        key = k
    }
    public func isValid(signature: Data, for message: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }
}
#endif

public enum SignedConfigFormat {
    public static let supportedSchema = 1
    public static let maxConfigBytes = 256 * 1024
    public static let maxSignatureBytes = 4 * 1024
    public static let minIntervalMs: Int64 = 6 * 60 * 60 * 1000
    /// Öffentlicher Schlüssel des Herausgebers (X.509/SPKI, P-256) – identisch mit Android.
    public static let publisherKeyBase64 = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXryfUbovl4zW3HT/jKxqudaR9dsK8v2aqHqdKdJDKfHb+5xyNbpYxUhT/UJtclToVr1nCb5wIoTL5fbqiwgR6w=="
}

/// Prüft Signatur, Schema und Version eines Pakets.
public struct SignedConfigVerifier: Sendable {
    private let signatures: SignatureVerifying
    public init(_ signatures: SignatureVerifying) { self.signatures = signatures }

    public func verify(_ configBytes: Data, signatureBase64: String, minimumVersion: Int64) throws -> SignedConfig {
        if configBytes.count > SignedConfigFormat.maxConfigBytes { throw SignedConfigError("Paket zu groß") }
        let compact = String(signatureBase64.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard let sig = Data(base64Encoded: compact) else { throw SignedConfigError("Signatur ist kein Base64") }
        guard signatures.isValid(signature: sig, for: configBytes) else { throw SignedConfigError("Signatur ungültig") }
        let config = try Self.decode(configBytes)
        if config.schema != SignedConfigFormat.supportedSchema { throw SignedConfigError("Unbekanntes Schema \(config.schema)") }
        if config.version < minimumVersion { throw SignedConfigError("Version \(config.version) älter als \(minimumVersion) (Rückspielschutz)") }
        if let ref = config.solver {
            if !ref.url.hasPrefix("https://") { throw SignedConfigError("Entschlüssler-URL ohne HTTPS") }
            let hex = ref.sha256.utf8
            if hex.count != 64 || !hex.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) { throw SignedConfigError("Ungültige Prüfsumme") }
        }
        return config
    }

    private struct Dto: Decodable {
        var schema: Int; var version: Int64; var issuedAt: String?
        var clients: [ProfileDto]?; var solver: SolverRef?; var flags: [String: Bool]?
    }
    private struct ProfileDto: Decodable {
        var id: String, label: String, clientName: String, clientNameId: Int, clientVersion: String, userAgent: String
        var referer: String?, deviceMake: String?, deviceModel: String?, osName: String?, osVersion: String?
        var platform: String?, clientScreen: String?, embedUrl: String?
        var supportsOAuth: Bool?, requiresPoToken: Bool?, requiresJsPlayer: Bool?, enabled: Bool?
        var profile: PlayerClientProfile {
            var p = PlayerClientProfile(id: id, label: label, clientName: clientName, clientNameId: clientNameId, clientVersion: clientVersion, userAgent: userAgent)
            if let referer { p.referer = referer }
            p.deviceMake = deviceMake; p.deviceModel = deviceModel; p.osName = osName; p.osVersion = osVersion
            p.platform = platform; p.clientScreen = clientScreen; p.embedUrl = embedUrl
            p.supportsOAuth = supportsOAuth ?? false; p.requiresPoToken = requiresPoToken ?? false
            p.requiresJsPlayer = requiresJsPlayer ?? true; p.enabled = enabled ?? true
            return p
        }
    }

    static func decode(_ bytes: Data) throws -> SignedConfig {
        guard let d = try? JSONDecoder().decode(Dto.self, from: bytes) else { throw SignedConfigError("Paket nicht lesbar") }
        return SignedConfig(schema: d.schema, version: d.version, issuedAt: d.issuedAt, clients: d.clients?.map(\.profile), solver: d.solver, flags: d.flags ?? [:])
    }
}

public struct SignedConfigStatus: Equatable, Sendable {
    public var config: SignedConfig?
    public var lastCheckMs: Int64 = 0
    public var error: String?
}

/// Lädt das Paket, prüft es und hält die zuletzt gültige Fassung vor. Auch die gespeicherte Kopie wird bei jedem Laden erneut
/// geprüft; eine veränderte Datei wird verworfen. Fehler (offline, Signatur falsch) lassen die gespeicherte Fassung unberührt.
public actor SignedConfigRepository {
    private let directory: URL
    private let transport: HTTPTransport
    private let verifier: SignedConfigVerifier
    private let sourceUrl: @Sendable () async -> String?
    private let nowMs: @Sendable () -> Int64
    private var status = SignedConfigStatus()
    private var loaded = false
    private var currentBytes: Data?
    private var versionFloor: Int64 = 0

    public init(directory: URL, transport: HTTPTransport, verifier: SignedConfigVerifier,
                sourceUrl: @escaping @Sendable () async -> String?,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.directory = directory; self.transport = transport; self.verifier = verifier; self.sourceUrl = sourceUrl; self.nowMs = nowMs
    }

    private var bundleFile: URL { directory.appendingPathComponent("config.bundle") }
    private var floorFile: URL { directory.appendingPathComponent("version.floor") }

    public func current() -> SignedConfig? { ensureLoaded(); return status.config }
    public func currentStatus() -> SignedConfigStatus { ensureLoaded(); return status }

    /// Höchstens alle 6 Stunden, mit `force` sofort.
    @discardableResult
    public func refresh(force: Bool = false) async -> SignedConfigStatus {
        ensureLoaded()
        let now = nowMs(); let previous = status
        if !force && now - previous.lastCheckMs < SignedConfigFormat.minIntervalMs && previous.lastCheckMs > 0 { return previous }
        func fail(_ m: String, checked: Bool = false) -> SignedConfigStatus {
            var s = previous; s.error = m; if checked { s.lastCheckMs = now }; status = s; return s
        }
        guard let url = (await sourceUrl())?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return fail("Keine Paket-Quelle eingestellt") }
        guard let configUrl = URL(string: url), let sigUrl = URL(string: url + ".sig"), configUrl.host != nil else { return fail("Paket-Quelle ist keine gültige URL") }
        guard configUrl.scheme?.lowercased() == "https" else { return fail("Paket-Quelle muss mit https:// beginnen") }
        do {
            let bytes = try await download(configUrl, max: SignedConfigFormat.maxConfigBytes)
            let sig = String(decoding: try await download(sigUrl, max: SignedConfigFormat.maxSignatureBytes), as: UTF8.self)
            let floor = max(versionFloor, previous.config?.version ?? 0)
            let config = try verifier.verify(bytes, signatureBase64: sig, minimumVersion: floor)
            if config.version == previous.config?.version, let known = currentBytes, known != bytes {
                throw SignedConfigError("Version \(config.version) mit anderem Inhalt (Rückspielschutz)")
            }
            if currentBytes != bytes {
                persist(bytes, signature: sig, version: config.version)
                currentBytes = bytes; versionFloor = max(versionFloor, config.version)
            }
            status = SignedConfigStatus(config: config, lastCheckMs: now, error: nil)
        } catch let e as SignedConfigError { return fail(e.message, checked: true) }
        catch { return fail("Nicht erreichbar", checked: true) }
        return status
    }

    private struct DownloadError: Error {}
    private func download(_ url: URL, max: Int) async throws -> Data {
        let r = try await transport.send(HTTPRequest(url: url))
        guard r.isSuccessful else { throw DownloadError() }
        guard r.body.count <= max else { throw DownloadError() }
        return r.body
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        versionFloor = (try? String(contentsOf: floorFile, encoding: .utf8)).flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { max($0, 0) } ?? 0
        guard let raw = try? Data(contentsOf: bundleFile), let nl = raw.firstIndex(of: 0x0A), nl > raw.startIndex else { return }
        let sig = String(decoding: raw[raw.startIndex..<nl], as: UTF8.self)
        let bytes = Data(raw[(nl + 1)...])
        do {
            let config = try verifier.verify(bytes, signatureBase64: sig, minimumVersion: versionFloor)
            currentBytes = bytes; versionFloor = max(versionFloor, config.version); status.config = config
        } catch { try? FileManager.default.removeItem(at: bundleFile) }
    }

    /// Zuerst die Untergrenze, dann Signatur+Paket als ein Bündel (atomar): nie ein gemischtes Paar.
    private func persist(_ bytes: Data, signature: String, version: Int64) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(String(max(versionFloor, version)).utf8).write(to: floorFile, options: .atomic)
            let compact = String(signature.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            try (Data(compact.utf8) + Data([0x0A]) + bytes).write(to: bundleFile, options: .atomic)
        } catch { /* nicht speicherbar: bleibt im Speicher */ }
    }
}
