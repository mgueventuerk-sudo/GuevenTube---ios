import Foundation

/// Öffentliche Kennung des OAuth-Clients, der die Tokens eines Kontos ausgestellt hat.
public struct OAuthClientCredentials: Equatable, Codable, Sendable {
    public var clientId: String
    public var clientSecret: String
    public init(clientId: String, clientSecret: String) { self.clientId = clientId; self.clientSecret = clientSecret }
}

/// Zugangsdaten eines Kontos. Tokens erscheinen nie in Logs oder Absturzberichten.
public struct AccountCredentials: Equatable, Codable, Sendable, CustomStringConvertible {
    public static let defaultExpiryMarginMs: Int64 = 60_000

    public var accountId: String
    public var displayName: String
    public var email: String?
    public var avatarUrl: String?
    public var channelId: String?
    public var accessToken: String
    public var accessTokenExpiresAtEpochMs: Int64
    public var refreshToken: String
    public var tokenType: String
    public var scope: String?
    public var sapisid: String?
    public var createdAtEpochMs: Int64
    public var updatedAtEpochMs: Int64
    public var oauthClientId: String?
    public var oauthClientSecret: String?
    public var needsReauth: Bool

    public struct InvalidAccountId: Error, Equatable {}

    public static func isValidAccountId(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }
    public static func newAccountId() -> String { UUID().uuidString.lowercased() }

    public init(accountId: String, displayName: String, email: String? = nil, avatarUrl: String? = nil, channelId: String? = nil,
                accessToken: String, accessTokenExpiresAtEpochMs: Int64, refreshToken: String, tokenType: String = "Bearer",
                scope: String? = nil, sapisid: String? = nil, createdAtEpochMs: Int64, updatedAtEpochMs: Int64,
                oauthClientId: String? = nil, oauthClientSecret: String? = nil, needsReauth: Bool = false) throws {
        guard Self.isValidAccountId(accountId) else { throw InvalidAccountId() }
        self.accountId = accountId; self.displayName = displayName; self.email = email; self.avatarUrl = avatarUrl
        self.channelId = channelId; self.accessToken = accessToken; self.accessTokenExpiresAtEpochMs = accessTokenExpiresAtEpochMs
        self.refreshToken = refreshToken; self.tokenType = tokenType; self.scope = scope; self.sapisid = sapisid
        self.createdAtEpochMs = createdAtEpochMs; self.updatedAtEpochMs = updatedAtEpochMs
        self.oauthClientId = oauthClientId; self.oauthClientSecret = oauthClientSecret; self.needsReauth = needsReauth
    }

    // Alte gespeicherte Konten ohne die neueren Felder bleiben lesbar.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .accountId)
        guard Self.isValidAccountId(id) else { throw InvalidAccountId() }
        accountId = id
        displayName = try c.decode(String.self, forKey: .displayName)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        accessTokenExpiresAtEpochMs = try c.decode(Int64.self, forKey: .accessTokenExpiresAtEpochMs)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        sapisid = try c.decodeIfPresent(String.self, forKey: .sapisid)
        createdAtEpochMs = try c.decode(Int64.self, forKey: .createdAtEpochMs)
        updatedAtEpochMs = try c.decode(Int64.self, forKey: .updatedAtEpochMs)
        oauthClientId = try c.decodeIfPresent(String.self, forKey: .oauthClientId)
        oauthClientSecret = try c.decodeIfPresent(String.self, forKey: .oauthClientSecret)
        needsReauth = try c.decodeIfPresent(Bool.self, forKey: .needsReauth) ?? false
    }

    /// `true`, wenn der Access-Token abgelaufen ist oder innerhalb von [safetyMarginMs] abläuft.
    public func isAccessTokenExpired(nowMs: Int64, safetyMarginMs: Int64 = AccountCredentials.defaultExpiryMarginMs) -> Bool {
        nowMs + safetyMarginMs >= accessTokenExpiresAtEpochMs
    }

    public func authorizationHeader() -> String { "\(tokenType) \(accessToken)" }

    /// Ausstellender OAuth-Client; `nil` bei alten Konten (dann gilt der aktuell ermittelte Client).
    public func oauthClient() -> OAuthClientCredentials? {
        guard let id = oauthClientId, !id.trimmingCharacters(in: .whitespaces).isEmpty,
              let secret = oauthClientSecret, !secret.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return OAuthClientCredentials(clientId: id, clientSecret: secret)
    }

    public var description: String {
        "AccountCredentials(accountId=\(accountId), displayName=\(displayName), channelId=\(channelId ?? "nil"), accessToken=<redacted>, "
            + "refreshToken=<redacted>, sapisid=\(sapisid == nil ? "nil" : "<redacted>"), oauthClientId=\(oauthClientId ?? "nil"), "
            + "oauthClientSecret=\(oauthClientSecret == nil ? "nil" : "<redacted>"), needsReauth=\(needsReauth), expiresAt=\(accessTokenExpiresAtEpochMs))"
    }
}

public struct DeviceCodeResponse: Equatable, Sendable {
    public static let defaultVerificationUrl = "https://www.google.com/device"
    public var deviceCode: String
    public var userCode: String
    public var verificationUrl: String
    public var expiresInSeconds: Int64
    public var intervalSeconds: Int64
}

public struct TokenResponse: Equatable, Sendable {
    public var accessToken: String
    public var expiresInSeconds: Int64
    public var refreshToken: String?
    public var scope: String?
    public var tokenType: String
    public init(accessToken: String, expiresInSeconds: Int64 = 3600, refreshToken: String? = nil, scope: String? = nil, tokenType: String = "Bearer") {
        self.accessToken = accessToken; self.expiresInSeconds = expiresInSeconds; self.refreshToken = refreshToken
        self.scope = scope; self.tokenType = tokenType
    }

    /// Neue Zugangsdaten aus einer erfolgreichen Geräteanmeldung.
    public func toCredentials(accountId: String, displayName: String, email: String?, avatarUrl: String?, channelId: String?,
                              client: OAuthClientCredentials? = nil, nowMs: Int64, createdAtMs: Int64? = nil) throws -> AccountCredentials {
        guard let refreshToken else { throw OAuthError(error: "missing_refresh_token", message: "Geräteanmeldung lieferte keinen Refresh-Token") }
        return try AccountCredentials(accountId: accountId, displayName: displayName, email: email, avatarUrl: avatarUrl, channelId: channelId,
                                      accessToken: accessToken, accessTokenExpiresAtEpochMs: nowMs + expiresInSeconds * 1000,
                                      refreshToken: refreshToken, tokenType: tokenType, scope: scope, createdAtEpochMs: createdAtMs ?? nowMs,
                                      updatedAtEpochMs: nowMs, oauthClientId: client?.clientId, oauthClientSecret: client?.clientSecret)
    }
}

public enum TokenPollResult: Equatable, Sendable {
    case success(TokenResponse), pending, slowDown, expired, denied, failure(String)
}

public struct OAuthError: Error, Equatable, Sendable {
    public static let reauthErrors: Set<String> = ["invalid_grant", "invalid_client", "unauthorized_client"]
    public let error: String
    public let message: String
    public init(error: String, message: String) { self.error = error; self.message = message }
    /// Endgültig: Token widerrufen bzw. Client passt nicht mehr – nur eine neue Anmeldung hilft.
    public var requiresReauthentication: Bool { Self.reauthErrors.contains(error) }
}

/// HTTP-Schicht des OAuth-2.0-Geräte-Codes, wie ihn die YouTube-TV-App verwendet. Client-ID und -Secret werden live aus
/// deren Skript gelesen, damit Rotationen ohne App-Update ankommen; die eingebauten Werte sind nur der Rückfall.
public actor OAuthClient {
    static let deviceCodeURL = URL(string: "https://www.youtube.com/o/oauth2/device/code")!
    static let tokenURL = URL(string: "https://www.youtube.com/o/oauth2/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let deviceGrantType = "http://oauth.net/grant_type/device/1.0"
    static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    static let deviceModel = "ytlr::"
    /// Öffentliche Kennung der YouTube-TV-Web-App (Stand Oktober 2026).
    static let fallbackClientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    static let fallbackClientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    static let credentialsPattern = #"clientId:"([0-9a-z-]+\.apps\.googleusercontent\.com)",[A-Za-z0-9_$]+:"([A-Za-z0-9_-]+)""#

    private let transport: HTTPTransport
    private let tvScriptUrl: @Sendable () async -> String?
    private var credentialsTask: Task<OAuthClientCredentials, Error>?
    /// Stabile Geräte-ID für die Code-Anforderung (pro Prozess).
    private let deviceId = UUID().uuidString.lowercased()

    public init(transport: HTTPTransport, tvScriptUrl: @escaping @Sendable () async -> String?) {
        self.transport = transport; self.tvScriptUrl = tvScriptUrl
    }

    public func clientCredentials() async throws -> OAuthClientCredentials {
        if let credentialsTask { return try await credentialsTask.value }
        let task = Task { try await self.discoverCredentials() }
        credentialsTask = task
        do { return try await task.value } catch { credentialsTask = nil; throw error }   // Abbruch: nicht dauerhaft merken
    }

    public func requestDeviceCode(client: OAuthClientCredentials? = nil) async throws -> DeviceCodeResponse {
        let credentials = try await resolve(client)
        let body: JSON = .obj([("client_id", .string(credentials.clientId)), ("scope", .string(Self.scope)),
                               ("device_id", .string(deviceId)), ("device_model", .string(Self.deviceModel))])
        let element = try parseObject(try await postJson(Self.deviceCodeURL, body))
        if let code = Self.errorCode(element) { throw OAuthError(error: code, message: "Gerätecode abgelehnt: \(code)") }
        guard let deviceCode = element.str("device_code"), let userCode = element.str("user_code") else {
            throw OAuthError(error: "invalid_response", message: "Gerätecode-Antwort unvollständig")
        }
        return DeviceCodeResponse(deviceCode: deviceCode, userCode: userCode,
                                  verificationUrl: element.str("verification_url") ?? DeviceCodeResponse.defaultVerificationUrl,
                                  expiresInSeconds: element.long("expires_in") ?? 1800, intervalSeconds: element.long("interval") ?? 5)
    }

    public func pollToken(deviceCode: String, client: OAuthClientCredentials? = nil) async throws -> TokenPollResult {
        let credentials = try await resolve(client)
        let body: JSON = .obj([("client_id", .string(credentials.clientId)), ("client_secret", .string(credentials.clientSecret)),
                               ("code", .string(deviceCode)), ("grant_type", .string(Self.deviceGrantType))])
        do {
            let element = try parseObject(try await postJson(Self.tokenURL, body))
            switch Self.errorCode(element) {
            case nil:
                guard let token = Self.tokenResponse(element) else { return .failure("Token-Antwort unvollständig") }
                return .success(token)
            case "authorization_pending"?: return .pending
            case "slow_down"?: return .slowDown
            case "expired_token"?: return .expired
            case "access_denied"?: return .denied
            case let other?: return .failure(other)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure((error as? OAuthError)?.message ?? String(describing: type(of: error)))
        }
    }

    /// Erneuert den Access-Token. [client] = der Client, der den Refresh-Token ausgestellt hat. Wirft `OAuthError`,
    /// z. B. `invalid_grant` bei widerrufenem Zugriff.
    public func refresh(refreshToken: String, client: OAuthClientCredentials? = nil) async throws -> TokenResponse {
        let credentials = try await resolve(client)
        let body: JSON = .obj([("client_id", .string(credentials.clientId)), ("client_secret", .string(credentials.clientSecret)),
                               ("refresh_token", .string(refreshToken)), ("grant_type", .string("refresh_token"))])
        let element = try parseObject(try await postJson(Self.tokenURL, body))
        if let code = Self.errorCode(element) { throw OAuthError(error: code, message: "Token-Erneuerung fehlgeschlagen: \(code)") }
        guard let token = Self.tokenResponse(element) else { throw OAuthError(error: "invalid_response", message: "Token-Antwort unvollständig") }
        return token
    }

    /// Widerruft die Berechtigung bei Google (Refresh-Token widerruft die ganze Freigabe). Der Token steht im Body, nie in der URL.
    public func revoke(token: String) async throws -> Bool {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        let request = HTTPRequest(url: Self.revokeURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: Data("token=\(encoded)".utf8))
        return try await transport.send(request).isSuccessful
    }

    // MARK: intern

    private func resolve(_ client: OAuthClientCredentials?) async throws -> OAuthClientCredentials {
        if let client { return client }
        return try await clientCredentials()
    }

    /// OAuth-Fehler kommen je nach Endpunkt mit HTTP 200, 400 oder 428 – der Body ist maßgeblich.
    private func postJson(_ url: URL, _ body: JSON) async throws -> String {
        let request = HTTPRequest(url: url, method: "POST", headers: [
            "User-Agent": HTTPConstants.tvUserAgent, "Origin": HTTPConstants.youtubeOrigin, "Referer": HTTPConstants.youtubeTvReferer,
            "Content-Type": HTTPConstants.jsonContentType,
        ], body: Data(body.serialized().utf8))
        return try await transport.send(request).text
    }

    private func parseObject(_ text: String) throws -> JSON {
        guard let json = try? JSONParser.parse(text), json.objectValue != nil else {
            throw OAuthError(error: "invalid_response", message: "Antwort ist kein JSON-Objekt")
        }
        return json
    }

    private static func errorCode(_ element: JSON) -> String? {
        guard case .string(let s)? = element.objectValue?["error"], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func tokenResponse(_ element: JSON) -> TokenResponse? {
        guard let access = element.str("access_token") else { return nil }
        return TokenResponse(accessToken: access, expiresInSeconds: element.long("expires_in") ?? 3600, refreshToken: element.str("refresh_token"),
                             scope: element.str("scope"), tokenType: element.str("token_type") ?? "Bearer")
    }

    private func discoverCredentials() async throws -> OAuthClientCredentials {
        do {
            if let scriptUrl = await tvScriptUrl(), let url = URL(string: scriptUrl) {
                let response = try await transport.send(HTTPRequest(url: url, headers: ["User-Agent": HTTPConstants.tvUserAgent]))
                let script = response.text
                if let regex = try? NSRegularExpression(pattern: Self.credentialsPattern),
                   let m = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                   let id = Range(m.range(at: 1), in: script), let secret = Range(m.range(at: 2), in: script) {
                    return OAuthClientCredentials(clientId: String(script[id]), clientSecret: String(script[secret]))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch { /* eingebaute Kennung */ }
        return OAuthClientCredentials(clientId: Self.fallbackClientId, clientSecret: Self.fallbackClientSecret)
    }
}

/// Ablage der Konten (iOS: Keychain).
public protocol AccountCredentialStore: Sendable {
    func activeCredentials() async -> AccountCredentials?
    func credentials(accountId: String) async -> AccountCredentials?
    @discardableResult
    func updateTokens(accountId: String, accessToken: String, expiresAtMs: Int64, refreshToken: String?, scope: String?) async -> Bool
    @discardableResult
    func markNeedsReauth(accountId: String) async -> Bool
}

/// Liefert einen gültigen Access-Token für das aktive Konto und erneuert ihn bei Bedarf. Parallele Anfragen teilen sich
/// eine einzige Erneuerung. Lehnt Google endgültig ab, wird das Konto als „neu anmelden“ markiert und nicht mehr erneuert,
/// bis eine neue Anmeldung neue Tokens speichert.
public actor AuthTokenManager: AuthTokenProviding {
    private let store: AccountCredentialStore
    private let oauth: OAuthClient
    private let nowMs: @Sendable () -> Int64
    private let refreshGate = AsyncLimiter(1)
    private var reauthAccount: String?

    public init(store: AccountCredentialStore, oauth: OAuthClient, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store; self.oauth = oauth; self.nowMs = nowMs
    }

    /// Konto-ID, deren Zugriff widerrufen wurde und die sich neu anmelden muss.
    public func reauthenticationRequired() -> String? { reauthAccount }
    public func acknowledgeReauthentication() { reauthAccount = nil }

    public func accessTokenOrNil() async -> String? { await activeToken()?.accessToken }

    public func activeToken() async -> AuthToken? {
        guard let active = await store.activeCredentials() else { return nil }
        if active.needsReauth { reauthAccount = active.accountId; return nil }
        if !active.isAccessTokenExpired(nowMs: nowMs()) { return AuthToken(accessToken: active.accessToken, accountId: active.accountId) }
        return await refresh(accountId: active.accountId, staleToken: nil).map { AuthToken(accessToken: $0, accountId: active.accountId) }
    }

    /// Nach HTTP 401 mit [accessToken] von Konto [accountId]: erneuert nur, wenn noch genau dieser Token gespeichert ist –
    /// sonst hat eine parallele Anfrage schon erneuert und deren Token wird geliefert. Bleibt immer beim selben Konto.
    public func forceRefresh(accessToken: String, accountId: String) async -> String? {
        await refresh(accountId: accountId, staleToken: accessToken)
    }

    /// [staleToken] `nil` = normale Erneuerung bei Ablauf, sonst erzwungen nach 401.
    private func refresh(accountId: String, staleToken: String?) async -> String? {
        await refreshGate.acquire()
        let result = await refreshLocked(accountId: accountId, staleToken: staleToken)
        await refreshGate.release()
        return result
    }

    private func refreshLocked(accountId: String, staleToken: String?) async -> String? {
        guard let latest = await store.credentials(accountId: accountId), !latest.needsReauth else { return nil }
        let expired = latest.isAccessTokenExpired(nowMs: nowMs())
        if staleToken == nil && !expired { return latest.accessToken }
        if let staleToken, latest.accessToken != staleToken, !expired { return latest.accessToken }
        do {
            let tokens = try await oauth.refresh(refreshToken: latest.refreshToken, client: latest.oauthClient())
            await store.updateTokens(accountId: accountId, accessToken: tokens.accessToken, expiresAtMs: nowMs() + tokens.expiresInSeconds * 1000,
                                     refreshToken: tokens.refreshToken, scope: tokens.scope)
            return tokens.accessToken
        } catch let error as OAuthError {
            if error.requiresReauthentication {
                // Gespeichert: weitere Aufrufe gehen nicht erneut an den Token-Endpunkt.
                await store.markNeedsReauth(accountId: accountId)
                reauthAccount = accountId
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            // Netzfehler: alten Token weiterverwenden, solange er formal noch gilt.
            return latest.isAccessTokenExpired(nowMs: nowMs(), safetyMarginMs: 0) ? nil : latest.accessToken
        }
    }
}
