import Foundation

/// Woher die aktiven Profile stammen (für die Einstellungen).
public struct ClientProfileStatus: Equatable, Sendable {
    public var source: String
    public var profiles: [PlayerClientProfile]
    public var error: String?
    public init(source: String, profiles: [PlayerClientProfile], error: String? = nil) { self.source = source; self.profiles = profiles; self.error = error }
}

/// Verwaltet die aktiven Player-Profile: eingebaut, aus dem signierten Paket oder – falls in den Einstellungen eine URL
/// hinterlegt ist – von dort geladen (Vorrang vor allem anderen). Die zuletzt gültige Datei wird lokal gespeichert, damit ein
/// Ausfall der URL die Wiedergabe nicht beeinträchtigt.
public actor PlayerClientRegistry: ClientProfileProviding {
    static let sourceBuiltIn = "Eingebaut"
    private let transport: HTTPTransport
    private let cacheFile: URL
    private let profilesUrl: @Sendable () async -> String?
    private let signedConfig: @Sendable () async -> SignedConfig?
    private let gate = AsyncLimiter(1)
    private var loaded = false
    private var status = ClientProfileStatus(source: PlayerClientRegistry.sourceBuiltIn, profiles: DefaultPlayerClients.all)

    public init(transport: HTTPTransport, cacheFile: URL, profilesUrl: @escaping @Sendable () async -> String?, signedConfig: @escaping @Sendable () async -> SignedConfig?) {
        self.transport = transport; self.cacheFile = cacheFile; self.profilesUrl = profilesUrl; self.signedConfig = signedConfig
    }

    public func currentStatus() -> ClientProfileStatus { status }

    /// Aktive, eingeschaltete Profile in Prüfreihenfolge.
    public func profiles() async -> [PlayerClientProfile] {
        if !loaded { await reload(fetchRemote: false) }
        return status.profiles.filter(\.enabled)
    }

    /// Mit `fetchRemote` wird eine hinterlegte URL erneut abgerufen, sonst genügt die lokal gespeicherte Kopie.
    @discardableResult
    public func reload(fetchRemote: Bool = true) async -> ClientProfileStatus {
        await gate.acquire()
        let url = (await profilesUrl())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ClientProfileStatus
        if let url, !url.isEmpty { result = await loadFromUrl(url, fetchRemote: fetchRemote) }
        else { result = await signedProfiles() ?? ClientProfileStatus(source: Self.sourceBuiltIn, profiles: DefaultPlayerClients.all) }
        status = result; loaded = true
        await gate.release()
        return result
    }

    private func loadFromUrl(_ url: String, fetchRemote: Bool) async -> ClientProfileStatus {
        if fetchRemote || !FileManager.default.fileExists(atPath: cacheFile.path) {
            do {
                let data = try await download(url)
                let profiles = try PlayerClientProfileParser.parse(String(decoding: data, as: UTF8.self))
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
                return ClientProfileStatus(source: "URL (\(url))", profiles: profiles)
            } catch {
                let message = "URL nicht nutzbar (\((error as? SolverError)?.message ?? (error as? ProfileFileError)?.message ?? String(describing: type(of: error))))"
                if let cached = readCache() { return ClientProfileStatus(source: "Gespeicherte Kopie der URL", profiles: cached, error: message) }
                return ClientProfileStatus(source: Self.sourceBuiltIn, profiles: DefaultPlayerClients.all, error: message)
            }
        }
        if let cached = readCache() { return ClientProfileStatus(source: "Gespeicherte Kopie der URL", profiles: cached) }
        return ClientProfileStatus(source: Self.sourceBuiltIn, profiles: DefaultPlayerClients.all, error: "Keine gespeicherte Kopie vorhanden")
    }

    /// Profile aus dem signierten Paket (Vorrang vor den eingebauten, nicht vor einer eigenen URL).
    private func signedProfiles() async -> ClientProfileStatus? {
        guard let config = await signedConfig(), let clients = config.clients else { return nil }
        let valid = clients.filter { [$0.id, $0.clientName, $0.clientVersion, $0.userAgent].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard valid.contains(where: \.enabled) else { return nil }
        return ClientProfileStatus(source: "Signiertes Paket v\(config.version)", profiles: valid)
    }

    private func readCache() -> [PlayerClientProfile]? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? PlayerClientProfileParser.parse(String(decoding: data, as: UTF8.self))
    }

    private func download(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw SolverError("Ungültige URL") }
        let r = try await transport.send(HTTPRequest(url: u))
        guard r.isSuccessful else { throw SolverError("HTTP \(r.code)") }
        return r.body
    }
}
