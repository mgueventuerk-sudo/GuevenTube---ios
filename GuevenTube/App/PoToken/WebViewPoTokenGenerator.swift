import Foundation
import GuevenCore

/// Erzeugt PO-Tokens, indem Googles BotGuard-VM in einem unsichtbaren WKWebView läuft (Port von `WebViewPoTokenGenerator.kt`).
/// 1. `Create` liefert Interpreter-Skript und Programm, 2. die VM läuft im WebView und liefert eine Antwort,
/// 3. `GenerateIT` tauscht sie gegen einen Integritäts-Token, 4. daraus werden Tokens je Bezeichner geprägt.
///
/// Das WebView bekommt keine Cookies (nicht persistenter Datenspeicher); die beiden Google-Anfragen stellt die App selbst.
/// Tokens werden nie protokolliert.
@MainActor
final class WebViewPoTokenGenerator {
    private static let createUrl = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    private static let generateItUrl = URL(string: "https://www.youtube.com/api/jnn/v1/GenerateIT")!
    // Öffentliche Kennungen des YouTube-Web-Clients (wie in NewPipe und der Android-App), keine Geheimnisse.
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let expiryMarginSeconds: Int64 = 600

    private let web = PoTokenWebView(userAgent: WebViewPoTokenGenerator.userAgent)
    private var expiresAt = Date.distantPast

    var isExpired: Bool { web.terminated || Date() >= expiresAt }

    private init() {}

    /// Baut einen einsatzbereiten Generator; bei jedem Fehler wird das WebView sofort freigegeben.
    static func create(transport: HTTPTransport) async throws -> WebViewPoTokenGenerator {
        let generator = WebViewPoTokenGenerator()
        do {
            try await generator.initialize(transport: transport)
            return generator
        } catch {
            generator.close()
            throw error
        }
    }

    private func initialize(transport: HTTPTransport) async throws {
        web.attachToWindow()
        let loadError: String? = await withCheckedContinuation { c in
            web.loadHTML(PoTokenHtml.page, baseURL: "https://www.youtube.com") { c.resume(returning: $0) }
        }
        if let loadError { throw PoTokenError("WebView: \(loadError.prefix(100))") }
        let challenge = try BotGuardJson.parseChallengeData(try await post(transport, Self.createUrl, "[ \"\(Self.requestKey)\" ]"))
        let response = try await run(
            """
            const r = await runBotGuard(JSON.parse(challenge));
            window.webPoSignalOutput = r.webPoSignalOutput;
            return r.botguardResponse;
            """, ["challenge": challenge])
        guard let botguardResponse = response as? String, !botguardResponse.isEmpty else { throw PoTokenError("BotGuard ohne Antwort") }
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [botguardResponse]), encoding: .utf8) ?? "[]"
        let body = "[ \"\(Self.requestKey)\", \(quoted.dropFirst().dropLast()) ]"
        let integrity = try BotGuardJson.parseIntegrityToken(try await post(transport, Self.generateItUrl, body))
        expiresAt = Date().addingTimeInterval(TimeInterval(max(integrity.lifetimeSeconds - Self.expiryMarginSeconds, 60)))
        _ = try await run("window.integrityToken = new Uint8Array(bytes); return true;", ["bytes": integrity.bytes.map { Int($0) }])
    }

    /// Prägt einen Token für [identifier] (Video-ID oder visitorData).
    func mint(_ identifier: String) async throws -> String {
        guard !web.terminated else { throw PoTokenError("Generator nicht mehr nutzbar") }
        guard BotGuardJson.isSafeIdentifier(identifier) else { throw PoTokenError("Bezeichner ungültig") }
        let result = try await run(
            """
            const u8 = obtainPoToken(window.webPoSignalOutput, window.integrityToken, new Uint8Array(bytes));
            return Array.prototype.join.call(u8, ",");
            """, ["bytes": Array(identifier.utf8).map { Int($0) }])
        guard let joined = result as? String else { throw PoTokenError("PO-Token ohne Ergebnis") }
        return try BotGuardJson.u8ToBase64(joined)
    }

    /// Gibt das WebView frei. Mehrfach aufrufbar.
    func close() { web.close() }

    private func run(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        let outcome: (Any?, String?) = await withCheckedContinuation { c in
            web.callAsync(body, arguments: arguments) { result, error in c.resume(returning: (result, error)) }
        }
        if let error = outcome.1 { throw PoTokenError("JavaScript: \(error.prefix(120))") }
        return outcome.0
    }

    private func post(_ transport: HTTPTransport, _ url: URL, _ body: String) async throws -> String {
        let request = HTTPRequest(url: url, method: "POST", headers: [
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
            "Content-Type": "application/json+protobuf",
            "x-goog-api-key": Self.apiKey,
            "x-user-agent": "grpc-web-javascript/0.1",
        ], body: Data(body.utf8))
        let response = try await transport.send(request)
        guard response.isSuccessful else { throw PoTokenError("BotGuard-Dienst: HTTP \(response.code)") }
        return response.text
    }
}
