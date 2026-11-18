import Foundation

/// Zustände der Geräteanmeldung (Port von `DeviceAuthManager.kt`).
public enum DeviceAuthState: Equatable, Sendable {
    case idle, requestingCode
    case awaitingUser(userCode: String, verificationUrl: String, qrContent: String, expiresAtMs: Int64)
    case completing
    case success(accountId: String, displayName: String)
    case failed(String)
}

public protocol DeviceAuthOAuth: Sendable {
    func clientCredentials() async throws -> OAuthClientCredentials
    func requestDeviceCode(client: OAuthClientCredentials?) async throws -> DeviceCodeResponse
    func pollToken(deviceCode: String, client: OAuthClientCredentials?) async throws -> TokenPollResult
}
extension OAuthClient: DeviceAuthOAuth {}

public protocol DeviceAuthProfileSource: Sendable {
    /// Kontodaten zum frisch ausgestellten Token; `nil` oder Fehler: Konto wird ohne Profil gespeichert.
    func accountInfo(accessToken: String) async throws -> AccountInfo?
}

public protocol DeviceAuthAccountStore: Sendable {
    func credentialsForChannel(_ channelId: String) async -> AccountCredentials?
    func saveActive(_ credentials: AccountCredentials) async -> Bool
}

public struct DeviceAuthFlow: Sendable {
    public static let minIntervalSeconds: Int64 = 5
    public static let slowDownStepMs: Int64 = 5_000
    public static let defaultAccountName = "Google-Konto"
    /// Fehlercodes des Token-Endpunkts, bei denen Warten nichts ändert.
    static let terminalPollErrors: Set<String> = ["invalid_client", "unauthorized_client", "invalid_request", "unsupported_grant_type", "invalid_scope", "invalid_grant"]
    /// So viele Abfragen in Folge dürfen scheitern (Netz weg), bevor die Anmeldung mit der Ursache abbricht (ca. 1 Minute).
    static let maxConsecutivePollFailures = 12

    private let oauth: DeviceAuthOAuth
    private let profiles: DeviceAuthProfileSource
    private let store: DeviceAuthAccountStore
    private let nowMs: @Sendable () -> Int64
    private let sleepMs: @Sendable (Int64) async throws -> Void

    public init(oauth: DeviceAuthOAuth, profiles: DeviceAuthProfileSource, store: DeviceAuthAccountStore,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleepMs: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }) {
        self.oauth = oauth; self.profiles = profiles; self.store = store; self.nowMs = nowMs; self.sleepMs = sleepMs
    }

    /// QR-Inhalt: Bestätigungsadresse mit vorausgefülltem Code.
    static func qrContent(_ verificationUrl: String, userCode: String) -> String {
        guard var c = URLComponents(string: verificationUrl) else { return verificationUrl }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "user_code", value: userCode)]
        return c.string ?? verificationUrl
    }

    /// Führt die Anmeldung aus und meldet jeden Zustand. Abbruch = Task abbrechen; dann wird nichts gespeichert (Rückgabe `.idle`).
    @discardableResult
    public func run(_ report: @Sendable (DeviceAuthState) -> Void) async -> DeviceAuthState {
        func finish(_ s: DeviceAuthState) -> DeviceAuthState { report(s); return s }
        report(.requestingCode)
        let client: OAuthClientCredentials, code: DeviceCodeResponse
        do {
            client = try await oauth.clientCredentials()
            code = try await oauth.requestDeviceCode(client: client)
        } catch is CancellationError { return finish(.idle) }
        catch { return finish(.failed("Anmeldecode konnte nicht angefordert werden: \((error as? OAuthError)?.message ?? error.localizedDescription)")) }

        let expiresAt = nowMs() + code.expiresInSeconds * 1000
        report(.awaitingUser(userCode: code.userCode, verificationUrl: code.verificationUrl,
                             qrContent: Self.qrContent(code.verificationUrl, userCode: code.userCode), expiresAtMs: expiresAt))
        var intervalMs = max(code.intervalSeconds, Self.minIntervalSeconds) * 1000
        var consecutiveFailures = 0
        while nowMs() < expiresAt {
            do { try await sleepMs(intervalMs) } catch { return finish(.idle) }
            let result: TokenPollResult
            do { result = try await oauth.pollToken(deviceCode: code.deviceCode, client: client) } catch { return finish(.idle) }
            switch result {
            case .pending: consecutiveFailures = 0
            case .failure(let reason):
                // Früher wurde jeder Fehler still ignoriert: der Nutzer sah dann bis zum Ablauf nur „warte“ und nie die Ursache.
                if Self.terminalPollErrors.contains(reason) {
                    return finish(.failed("Google hat die Anmeldung abgelehnt (\(reason)). Bitte später erneut versuchen."))
                }
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maxConsecutivePollFailures {
                    return finish(.failed("Anmeldung nicht möglich: \(reason). Prüfe die Internetverbindung."))
                }
            case .slowDown: consecutiveFailures = 0; intervalMs += Self.slowDownStepMs
            case .expired: return finish(.failed("Der Code ist abgelaufen. Bitte neu starten."))
            case .denied: return finish(.failed("Die Anmeldung wurde abgelehnt."))
            case .success(let tokens): return await complete(tokens, client: client, report: report)
            }
        }
        return finish(.failed("Der Code ist abgelaufen. Bitte neu starten."))
    }

    private func complete(_ tokens: TokenResponse, client: OAuthClientCredentials, report: @Sendable (DeviceAuthState) -> Void) async -> DeviceAuthState {
        func finish(_ s: DeviceAuthState) -> DeviceAuthState { report(s); return s }
        report(.completing)
        guard let refresh = tokens.refreshToken, !refresh.trimmingCharacters(in: .whitespaces).isEmpty else {
            return finish(.failed("Google hat keinen Refresh-Token geliefert."))
        }
        let info = (try? await profiles.accountInfo(accessToken: tokens.accessToken)) ?? nil
        // Erneute Anmeldung desselben Kanals ersetzt das bestehende Konto statt eine Kopie anzulegen.
        var existing: AccountCredentials?
        if let channel = info?.channelId { existing = await store.credentialsForChannel(channel) }
        let accountId = existing?.accountId ?? AccountCredentials.newAccountId()
        let name = info?.displayName ?? Self.defaultAccountName
        do {
            let credentials = try tokens.toCredentials(accountId: accountId, displayName: name, email: info?.byline,
                                                       avatarUrl: info?.avatarUrl, channelId: info?.channelId, client: client,
                                                       nowMs: nowMs(), createdAtMs: existing?.createdAtEpochMs)
            // Abbruch-Wettlauf: nach Abbruch wird nichts gespeichert.
            if Task.isCancelled { return finish(.idle) }
            guard await store.saveActive(credentials) else { return finish(.failed("Konto konnte nicht gespeichert werden.")) }
            return finish(.success(accountId: accountId, displayName: name))
        } catch {
            return finish(.failed("Konto konnte nicht gespeichert werden: \((error as? OAuthError)?.message ?? error.localizedDescription)"))
        }
    }
}

extension KeychainAccountStore: DeviceAuthAccountStore {
    public func credentialsForChannel(_ channelId: String) -> AccountCredentials? { allAccounts().first { $0.channelId == channelId } }
    public func saveActive(_ credentials: AccountCredentials) -> Bool { upsert(credentials, makeActive: true) }
}

/// Kontodaten über `account/accounts_list` mit explizitem Token.
public struct InnerTubeProfileSource: DeviceAuthProfileSource {
    private let service: InnerTubeService
    public init(service: InnerTubeService) { self.service = service }
    public func accountInfo(accessToken: String) async throws -> AccountInfo? {
        InnerTubeParser.parseAccount(try await service.accountsList(explicitAccessToken: accessToken))
    }
}
