import Foundation

/// Gemeinsame Kennungen für Anfragen an YouTube.
public enum HTTPConstants {
    /// User-Agent des YouTube-TV-Clients (Cobalt), passend zum TVHTML5-Kontext.
    public static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
    /// Neutraler Desktop-User-Agent.
    public static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    public static let youtubeOrigin = "https://www.youtube.com"
    public static let youtubeTvReferer = "https://www.youtube.com/tv"
    public static let musicOrigin = "https://music.youtube.com"
    public static let jsonContentType = "application/json; charset=utf-8"
}

/// InnerTube-Client-Kontexte für Inhalte (Browse, Suche, Konto, Kommentare).
public enum InnerTubeClient: CaseIterable, Sendable {
    /// YouTube-TV-Client für Startseite, Abos und Konto. Wiedergabe läuft über eigene [PlayerClientProfile].
    case tvhtml5
    /// Web-Kontext für Suche, Kommentare und Live-Chat; anonym (ohne OAuth).
    case web
    /// YouTube Music: Startseite, Suche, Alben, Interpreten, Radio, Liedtexte.
    case webRemix

    public var clientName: String {
        switch self { case .tvhtml5: "TVHTML5"; case .web: "WEB"; case .webRemix: "WEB_REMIX" }
    }
    public var clientNameId: Int {
        switch self { case .tvhtml5: 7; case .web: 1; case .webRemix: 67 }
    }
    public var fallbackVersion: String {
        switch self { case .tvhtml5: "7.20261021.13.00"; case .web: "2.20261020.01.00"; case .webRemix: "1.20261021.01.00" }
    }
    public var supportsOAuth: Bool { self == .tvhtml5 }
    public var userAgent: String { self == .tvhtml5 ? HTTPConstants.tvUserAgent : HTTPConstants.desktopUserAgent }
    public var referer: String {
        switch self { case .tvhtml5: HTTPConstants.youtubeTvReferer; case .web: "https://www.youtube.com/"; case .webRemix: "https://music.youtube.com/" }
    }
}

/// Ein InnerTube-Client-Kontext für den `/player`-Aufruf. Profile lassen sich ohne neuen Build per JSON-URL
/// ersetzen, weil YouTube Client-Kennungen regelmäßig sperrt.
public struct PlayerClientProfile: Equatable, Sendable {
    public var id: String
    public var label: String
    public var clientName: String
    public var clientNameId: Int
    public var clientVersion: String
    public var userAgent: String
    public var referer: String = HTTPConstants.youtubeTvReferer
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    public var platform: String?
    public var clientScreen: String?
    /// Setzt `context.thirdParty.embedUrl` (eingebettete Player).
    public var embedUrl: String?
    public var supportsOAuth = false
    /// Nur verwenden, wenn ein PO-Token hinterlegt ist.
    public var requiresPoToken = false
    /// `false`: Die Stream-URLs sind direkt abspielbar, das Player-Skript wird nicht geladen.
    public var requiresJsPlayer = true
    public var enabled = true
}

/// Eingebaute Profile (Stand der Android-App 2.5.1, abgeglichen mit yt-dlp).
public enum DefaultPlayerClients {
    /// visionOS: direkt abspielbare Stream-URLs ohne Signatur und `n`-Parameter, kein PO-Token.
    public static let visionOS = PlayerClientProfile(
        id: "visionos", label: "visionOS", clientName: "VISIONOS", clientNameId: 101, clientVersion: "1.02",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        referer: "https://www.youtube.com/", deviceMake: "Apple", deviceModel: "RealityDevice17,1",
        osName: "visionOS", osVersion: "26.5.23O471", requiresJsPlayer: false)

    /// TVHTML5 mit Samsung-Tizen-Gerätekennung.
    public static let tvSamsung = PlayerClientProfile(
        id: "tv_samsung", label: "TV (Samsung)", clientName: "TVHTML5", clientNameId: 7, clientVersion: "5.20260707",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        deviceMake: "Samsung", deviceModel: "UKS9800", osName: "Tizen", osVersion: "2.4.0", supportsOAuth: true)

    /// Eingebetteter Web-Player: anonym; der Referer muss die einbettende Seite sein.
    public static let webEmbedded = PlayerClientProfile(
        id: "web_embedded", label: "Web (eingebettet)", clientName: "WEB_EMBEDDED_PLAYER", clientNameId: 56,
        clientVersion: "2.20260708.00.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        referer: "https://www.google.com/", platform: "DESKTOP", clientScreen: "EMBED", embedUrl: "https://www.google.com/")

    /// Web-Client: verlangt für Stream-URLs einen PO-Token.
    public static let web = PlayerClientProfile(
        id: "web", label: "Web", clientName: "WEB", clientNameId: 1, clientVersion: "2.20260120.01.00",
        userAgent: HTTPConstants.desktopUserAgent, referer: "https://www.youtube.com/", platform: "DESKTOP", requiresPoToken: true)

    public static let all: [PlayerClientProfile] = [visionOS, tvSamsung, webEmbedded, web]
}

public struct ProfileFileError: Error, Equatable { public let message: String }

/// Liest und prüft eine Profil-Datei streng: mindestens ein eingeschaltetes Profil, keine leeren Pflichtfelder.
public enum PlayerClientProfileParser {
    public static func parse(_ text: String) throws -> [PlayerClientProfile] {
        let root: JSON
        do { root = try JSONParser.parse(text) } catch { throw ProfileFileError(message: "kein gültiges JSON") }
        guard let clients = root.arr("clients") else { throw ProfileFileError(message: "clients fehlt") }
        let profiles = try clients.map(profile)
        guard profiles.contains(where: \.enabled) else { throw ProfileFileError(message: "keine aktiven Profile") }
        for p in profiles {
            guard !blank(p.id), !blank(p.clientName), !blank(p.clientVersion) else { throw ProfileFileError(message: "Profil unvollständig") }
            guard !blank(p.userAgent) else { throw ProfileFileError(message: "Profil \(p.id) ohne User-Agent") }
        }
        return profiles
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func profile(_ node: JSON) throws -> PlayerClientProfile {
        guard let id = node.str("id"), let label = node.str("label"), let clientName = node.str("clientName"),
              let clientNameId = node.int("clientNameId"), let version = node.str("clientVersion"), let ua = node.str("userAgent")
        else { throw ProfileFileError(message: "Pflichtfeld fehlt") }
        var p = PlayerClientProfile(id: id, label: label, clientName: clientName, clientNameId: clientNameId, clientVersion: version, userAgent: ua)
        p.referer = node.str("referer") ?? p.referer
        p.deviceMake = node.str("deviceMake"); p.deviceModel = node.str("deviceModel")
        p.osName = node.str("osName"); p.osVersion = node.str("osVersion")
        p.platform = node.str("platform"); p.clientScreen = node.str("clientScreen"); p.embedUrl = node.str("embedUrl")
        p.supportsOAuth = node.bool("supportsOAuth") ?? false
        p.requiresPoToken = node.bool("requiresPoToken") ?? false
        p.requiresJsPlayer = node.bool("requiresJsPlayer") ?? true
        p.enabled = node.bool("enabled") ?? true
        return p
    }
}

/// Vollständiger Client-Kontext einer Anfrage (aus [InnerTubeClient] oder [PlayerClientProfile]).
public struct RequestClient: Equatable, Sendable {
    public var clientName: String
    public var clientNameId: Int
    public var clientVersion: String
    public var userAgent: String
    public var referer: String
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    public var platform: String?
    public var clientScreen: String?
    public var embedUrl: String?
    /// Server der Anfrage: YouTube oder YouTube Music.
    public var origin: String = HTTPConstants.youtubeOrigin

    public static func of(_ client: InnerTubeClient, version: String) -> RequestClient {
        RequestClient(clientName: client.clientName, clientNameId: client.clientNameId, clientVersion: version,
                      userAgent: client.userAgent, referer: client.referer,
                      origin: client == .webRemix ? HTTPConstants.musicOrigin : HTTPConstants.youtubeOrigin)
    }

    public static func of(_ p: PlayerClientProfile) -> RequestClient {
        RequestClient(clientName: p.clientName, clientNameId: p.clientNameId, clientVersion: p.clientVersion,
                      userAgent: p.userAgent, referer: p.referer, deviceMake: p.deviceMake, deviceModel: p.deviceModel,
                      osName: p.osName, osVersion: p.osVersion, platform: p.platform, clientScreen: p.clientScreen, embedUrl: p.embedUrl)
    }
}

/// Baut den InnerTube-Request-Body: `context.client` mit allen Gerätefeldern, `context.user`, optional
/// `context.thirdParty.embedUrl`, darunter die Nutzdaten.
public func buildRequestBody(client: RequestClient, visitorData: String?, hl: String, gl: String,
                             lockedSafetyMode: Bool = false, payload: [(String, JSON)] = []) -> JSON {
    var c: [(String, JSON)] = [
        ("clientName", .string(client.clientName)), ("clientVersion", .string(client.clientVersion)),
        ("hl", .string(hl)), ("gl", .string(gl)), ("userAgent", .string(client.userAgent)),
    ]
    func add(_ key: String, _ value: String?) { if let value { c.append((key, .string(value))) } }
    add("deviceMake", client.deviceMake); add("deviceModel", client.deviceModel)
    add("osName", client.osName); add("osVersion", client.osVersion)
    add("platform", client.platform); add("clientScreen", client.clientScreen); add("visitorData", visitorData)
    var context: [(String, JSON)] = [("client", .obj(c)), ("user", .obj([("lockedSafetyMode", .bool(lockedSafetyMode))]))]
    if let embed = client.embedUrl { context.append(("thirdParty", .obj([("embedUrl", .string(embed))]))) }
    return .obj([("context", .obj(context))] + payload)
}
