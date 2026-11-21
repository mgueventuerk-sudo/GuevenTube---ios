import Foundation

public struct InnerTubeError: Error, Equatable {
    public let statusCode: Int
    public let message: String
}

public struct AuthToken: Equatable, Sendable {
    public var accessToken: String
    public var accountId: String
    public init(accessToken: String, accountId: String) { self.accessToken = accessToken; self.accountId = accountId }
}

/// Konto-Token der Anmeldung (die Anmeldung selbst folgt in Etappe 5).
public protocol AuthTokenProviding: Sendable {
    func activeToken() async -> AuthToken?
    func accessTokenOrNil() async -> String?
    func forceRefresh(accessToken: String, accountId: String) async -> String?
}

/// Verschlüsselter Speicher für `visitorData` (iOS: Keychain).
public protocol SecretStoring: Sendable {
    func secret(_ key: String) async -> String?
    func setSecret(_ key: String, _ value: String) async throws
    func removeSecret(_ key: String) async throws
}

/// Live ermittelte Konfiguration der TV-Web-App.
public struct InnerTubeRuntimeConfig: Equatable, Sendable {
    public var tvClientVersion: String
    public var tvScriptUrl: String?
    public var fetchedAtMs: Int64
}

/// Liest die aktuelle TVHTML5-Client-Version und die URL des TV-App-Skripts aus `youtube.com/tv`. YouTube
/// lehnt veraltete Client-Versionen irgendwann ab; bei Fehlern greift die eingebaute Fallback-Version.
public actor InnerTubeConfigProvider {
    static let cacheTtlMs: Int64 = 6 * 60 * 60 * 1000
    static let retryAfterMs: Int64 = 5 * 60 * 1000
    /// Überspringt die EU-Zustimmungsseite für reine Konfigurationsabrufe (nur notwendige Cookies).
    static let consentCookie = "SOCS=CAE="

    private let transport: HTTPTransport
    private let nowMs: @Sendable () -> Int64
    private var cached: InnerTubeRuntimeConfig?

    public init(transport: HTTPTransport, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport
        self.nowMs = nowMs
    }

    public func config() async -> InnerTubeRuntimeConfig {
        if let c = cached, isFresh(c) { return c }
        let fresh = await fetch()
        cached = fresh
        return fresh
    }

    public func clientVersion(_ client: InnerTubeClient) -> String {
        client == .tvhtml5 ? (cached?.tvClientVersion ?? client.fallbackVersion) : client.fallbackVersion
    }

    /// Verwirft die Live-Konfiguration, damit sie beim nächsten Aufruf neu gelesen wird.
    public func invalidate() { cached = nil }

    private func isFresh(_ c: InnerTubeRuntimeConfig) -> Bool { nowMs() - c.fetchedAtMs < Self.cacheTtlMs }

    private func fetch() async -> InnerTubeRuntimeConfig {
        let now = nowMs()
        do {
            let request = HTTPRequest(url: URL(string: HTTPConstants.youtubeTvReferer)!,
                                      headers: ["User-Agent": HTTPConstants.tvUserAgent, "Cookie": Self.consentCookie])
            let response = try await transport.send(request)
            guard response.isSuccessful else { throw InnerTubeError(statusCode: response.code, message: "HTTP \(response.code)") }
            let html = response.text
            let version = Self.firstGroup(#""INNERTUBE_CLIENT_VERSION":"([0-9.]+)[^"]*""#, in: html)
            let script = Self.firstGroup(#"(/s/_/kabuki/_/js/[^"'\\\s]+/m=base)"#, in: html).map {
                $0.hasPrefix("http") ? $0 : HTTPConstants.youtubeOrigin + $0
            }
            return InnerTubeRuntimeConfig(tvClientVersion: version ?? InnerTubeClient.tvhtml5.fallbackVersion, tvScriptUrl: script, fetchedAtMs: now)
        } catch is CancellationError {
            return cached ?? InnerTubeRuntimeConfig(tvClientVersion: InnerTubeClient.tvhtml5.fallbackVersion, tvScriptUrl: nil, fetchedAtMs: now - Self.cacheTtlMs + Self.retryAfterMs)
        } catch {
            // Nicht abrufbar: Fallback, nach 5 Minuten erneuter Versuch.
            var fallback = cached ?? InnerTubeRuntimeConfig(tvClientVersion: InnerTubeClient.tvhtml5.fallbackVersion, tvScriptUrl: nil, fetchedAtMs: 0)
            fallback.fetchedAtMs = now - Self.cacheTtlMs + Self.retryAfterMs
            return fallback
        }
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// Low-Level-Zugriff auf die interne YouTube-API (InnerTube).
///
/// - Jede Anfrage trägt den vollständigen `context.client` samt `visitorData` und `X-YouTube-Client-*`-Header.
/// - Angemeldete Nutzer erhalten den OAuth-Bearer-Token; bei HTTP 401 wird einmalig erneuert.
/// - `visitorData` aus jeder Antwort wird gespeichert und wiederverwendet.
public actor InnerTubeService {
    public static let secretVisitorData = "innertube.visitorData"
    public static let browseHome = "default"
    public static let browseSubscriptions = "FEsubscriptions"
    public static let browseHistory = "FEhistory"
    public static let browseLibrary = "FElibrary"
    static let maxRetries = 3
    static let baseBackoffMs: Int64 = 1_000
    static let maxBackoffMs: Int64 = 8_000
    static let musicTokenRejected: Set<Int> = [400, 401, 403]
    static let apiPath = "/youtubei/v1/"

    private let transport: HTTPTransport
    private let config: InnerTubeConfigProvider
    private let auth: AuthTokenProviding
    private let secrets: SecretStoring
    private let sleepMs: @Sendable (Int64) async throws -> Void
    private let locale: @Sendable () -> (hl: String, gl: String)
    private let lockedSafetyMode: @Sendable () -> Bool

    private var visitorData: String?
    private var visitorDataLoaded = false

    public init(transport: HTTPTransport, config: InnerTubeConfigProvider, auth: AuthTokenProviding, secrets: SecretStoring,
                sleepMs: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
                locale: @escaping @Sendable () -> (hl: String, gl: String) = {
                    let l = Locale.current
                    let lang = l.language.languageCode?.identifier ?? ""
                    let region = l.region?.identifier ?? ""
                    return (lang.isEmpty ? "de" : lang, region.isEmpty ? "DE" : region)
                },
                lockedSafetyMode: @escaping @Sendable () -> Bool = { false }) {
        self.transport = transport; self.config = config; self.auth = auth; self.secrets = secrets
        self.sleepMs = sleepMs; self.locale = locale; self.lockedSafetyMode = lockedSafetyMode
    }

    // MARK: Endpunkte

    public func browse(browseId: String?, params: String? = nil, continuation: String? = nil) async throws -> JSON {
        var payload: [(String, JSON)] = []
        if let continuation { payload.append(("continuation", .string(continuation))) } else {
            if let browseId { payload.append(("browseId", .string(browseId))) }
            if let params { payload.append(("params", .string(params))) }
        }
        return try await post("browse", .tvhtml5, payload: payload)
    }

    public func search(query: String?, continuation: String? = nil, params: String? = nil) async throws -> JSON {
        var payload: [(String, JSON)] = []
        if let continuation { payload.append(("continuation", .string(continuation))) } else {
            payload.append(("query", .string(query ?? "")))
            if let params { payload.append(("params", .string(params))) }
        }
        return try await post("search", .web, payload: payload)
    }

    /// Kontogebundene Aktion (Playlists) mit dem TV-Client und OAuth.
    public func action(_ endpoint: String, payload: [(String, JSON)]) async throws -> JSON {
        try await post(endpoint, .tvhtml5, payload: payload)
    }

    public func next(videoId: String) async throws -> JSON {
        try await post("next", .tvhtml5, payload: [("videoId", .string(videoId))])
    }

    /// `/player` im Kontext eines [PlayerClientProfile] mit Signatur-Zeitstempel und optionalem PO-Token.
    /// Mit [useAccount] wird der OAuth-Token des aktiven Kontos mitgeschickt (nur bei Profilen mit `supportsOAuth`).
    public func player(videoId: String, signatureTimestamp: Int?, poToken: String?, profile: PlayerClientProfile, useAccount: Bool) async throws -> JSON {
        var playback: [(String, JSON)] = []
        if let signatureTimestamp { playback.append(("signatureTimestamp", .number(String(signatureTimestamp)))) }
        playback.append(("html5Preference", "HTML5_PREF_WANTS"))
        var payload: [(String, JSON)] = [
            ("videoId", .string(videoId)), ("contentCheckOk", true), ("racyCheckOk", true),
            ("playbackContext", .obj([("contentPlaybackContext", .obj(playback))])),
        ]
        if let poToken, !poToken.trimmingCharacters(in: .whitespaces).isEmpty {
            payload.append(("serviceIntegrityDimensions", .obj([("poToken", .string(poToken))])))
        }
        return try await post("player", RequestClient.of(profile), useAccount: useAccount && profile.supportsOAuth, payload: payload)
    }

    public func hasAccount() async -> Bool { await auth.accessTokenOrNil() != nil }

    /// Verwirft die gespeicherte `visitorData` (z. B. bei „Erneut versuchen" nach Sperren).
    public func resetVisitorData() async throws {
        visitorData = nil
        visitorDataLoaded = true
        try await secrets.removeSecret(Self.secretVisitorData)
    }

    public func webNext(videoId: String) async throws -> JSON { try await post("next", .web, payload: [("videoId", .string(videoId))]) }
    public func webNextContinuation(_ continuation: String) async throws -> JSON { try await post("next", .web, payload: [("continuation", .string(continuation))]) }
    public func liveChat(continuation: String) async throws -> JSON { try await post("live_chat/get_live_chat", .web, payload: [("continuation", .string(continuation))]) }

    /// YouTube Music. Mit [withAccount] wird der vorhandene Token **nur gelesen** mitgeschickt – ohne erzwungene
    /// Token-Erneuerung bei 401. Lehnt YouTube Music den Token ab (400/401/403), wird anonym wiederholt;
    /// [accountAccepted] meldet, ob der Token angenommen wurde.
    /// `continuation` (Weiterladen einer Liste) geht zusätzlich als URL-Parameter mit; das Musik-Web verlangt beides.
    public func music(_ endpoint: String, withAccount: Bool, accountAccepted: @Sendable (Bool) -> Void = { _ in }, payload: [(String, JSON)]) async throws -> JSON {
        _ = await config.config()
        let client = RequestClient.of(.webRemix, version: await config.clientVersion(.webRemix))
        let token = withAccount ? await auth.accessTokenOrNil() : nil
        if let token {
            do {
                let result = try await post(endpoint, client, useAccount: false, explicitAccessToken: token, keepVisitorData: true, payload: payload)
                accountAccepted(true)
                return result
            } catch let error as InnerTubeError {
                if !Self.musicTokenRejected.contains(error.statusCode) { throw error }
                // 400 kann auch an der Anfrage liegen: Erst wenn anonym klappt, gilt der Token als abgelehnt.
                let anonymous = try await post(endpoint, client, useAccount: false, keepVisitorData: true, payload: payload)
                accountAccepted(false)
                return anonymous
            }
        }
        return try await post(endpoint, client, useAccount: false, keepVisitorData: true, payload: payload)
    }

    /// Kontoinformationen; mit [explicitAccessToken] auch direkt nach der Geräteanmeldung nutzbar.
    public func accountsList(explicitAccessToken: String? = nil) async throws -> JSON {
        try await post("account/accounts_list", .tvhtml5, explicitAccessToken: explicitAccessToken, payload: [])
    }

    public func currentVisitorData() async -> String? {
        await ensureVisitorDataLoaded()
        return visitorData
    }

    // MARK: Anfrage-Ausführung

    private func post(_ endpoint: String, _ client: InnerTubeClient, explicitAccessToken: String? = nil, payload: [(String, JSON)]) async throws -> JSON {
        _ = await config.config()
        let rc = RequestClient.of(client, version: await config.clientVersion(client))
        return try await post(endpoint, rc, useAccount: client.supportsOAuth, explicitAccessToken: explicitAccessToken, payload: payload)
    }

    private func post(_ endpoint: String, _ client: RequestClient, useAccount: Bool, explicitAccessToken: String? = nil,
                      keepVisitorData: Bool = false, payload: [(String, JSON)]) async throws -> JSON {
        await ensureVisitorDataLoaded()
        var urlQuery = ""
        if client.clientName == "WEB_REMIX", case .string(let token)? = payload.first(where: { $0.0 == "continuation" })?.1, !token.isEmpty,
           let enc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            urlQuery = "&ctoken=\(enc)&continuation=\(enc)&type=next"
        }
        let (hl, gl) = locale()
        let body = buildRequestBody(client: client, visitorData: visitorData, hl: hl, gl: gl, lockedSafetyMode: lockedSafetyMode(), payload: payload)
        let bodyData = Data(body.serialized().utf8)
        let accountToken = (explicitAccessToken == nil && useAccount) ? await auth.activeToken() : nil
        let accessToken = explicitAccessToken ?? accountToken?.accessToken
        var response = try await executeWithBackoff(endpoint, client, bodyData, accessToken, urlQuery: urlQuery)
        if response.code == 401, let accountToken {
            // Nur dasselbe Konto erneuern.
            let refreshed = await auth.forceRefresh(accessToken: accountToken.accessToken, accountId: accountToken.accountId)
            response = try await executeWithBackoff(endpoint, client, bodyData, refreshed, urlQuery: urlQuery)
        }
        return try await handleResponse(endpoint, response, keepVisitorData: keepVisitorData)
    }

    /// Wiederholt bei HTTP 429 und 5xx mit exponentiellem Backoff (1 s, 2 s, 4 s) bzw. dem gesendeten
    /// `Retry-After` (gedeckelt). Netzwerkfehler werden ebenso wiederholt.
    private func executeWithBackoff(_ endpoint: String, _ client: RequestClient, _ body: Data, _ accessToken: String?, urlQuery: String = "") async throws -> HTTPResponse {
        var attempt = 0
        while true {
            var response: HTTPResponse?
            do {
                response = try await execute(endpoint, client, body, accessToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= Self.maxRetries { throw error }
            }
            let retryable = response == nil || response!.code == 429 || (500...599).contains(response!.code)
            if !retryable || attempt >= Self.maxRetries { return response! }
            let backoff = response?.retryAfterSeconds.map { min(min(max($0, 0), 3_600) * 1000, Self.maxBackoffMs) } ?? (Self.baseBackoffMs << Int64(attempt))
            try await sleepMs(backoff)
            attempt += 1
        }
    }

    private func execute(_ endpoint: String, _ client: RequestClient, _ body: Data, _ accessToken: String?) async throws -> HTTPResponse {
        var headers = [
            "User-Agent": client.userAgent, "Origin": client.origin, "Referer": client.referer,
            "X-YouTube-Client-Name": String(client.clientNameId), "X-YouTube-Client-Version": client.clientVersion,
            "Content-Type": HTTPConstants.jsonContentType,
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        if let accessToken { headers["Authorization"] = "Bearer \(accessToken)" }
        let url = URL(string: "\(client.origin)\(Self.apiPath)\(endpoint)?prettyPrint=false\(urlQuery)")!
        return try await transport.send(HTTPRequest(url: url, method: "POST", headers: headers, body: body))
    }

    private func handleResponse(_ endpoint: String, _ response: HTTPResponse, keepVisitorData: Bool) async throws -> JSON {
        guard response.isSuccessful else { throw InnerTubeError(statusCode: response.code, message: "InnerTube /\(endpoint): HTTP \(response.code)") }
        guard let root = try? JSONParser.parse(response.body), case .object = root else {
            throw InnerTubeError(statusCode: response.code, message: "InnerTube /\(endpoint): ungültiges JSON")
        }
        if !keepVisitorData, let v = root.obj("responseContext").str("visitorData") { await updateVisitorData(v) }
        return root
    }

    private func ensureVisitorDataLoaded() async {
        if visitorDataLoaded { return }
        visitorData = await secrets.secret(Self.secretVisitorData)
        visitorDataLoaded = true
    }

    private func updateVisitorData(_ value: String) async {
        if value.trimmingCharacters(in: .whitespaces).isEmpty || value == visitorData { return }
        visitorData = value
        try? await secrets.setSecret(Self.secretVisitorData, value)
    }
}
