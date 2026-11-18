import Foundation
import GuevenCore
import UIKit
import WebKit

/// Erzeugt PO-Tokens, indem Googles BotGuard-VM in einem unsichtbaren WKWebView läuft (Port von `WebViewPoTokenGenerator.kt`).
/// 1. `Create` liefert Interpreter-Skript und Programm, 2. die VM läuft im WebView und liefert eine Antwort,
/// 3. `GenerateIT` tauscht sie gegen einen Integritäts-Token, 4. daraus werden Tokens je Bezeichner geprägt.
///
/// Das WebView bekommt keine Cookies (nicht persistenter Datenspeicher); die beiden Google-Anfragen stellt die App selbst.
/// Tokens werden nie protokolliert.
@MainActor
final class WebViewPoTokenGenerator: NSObject {
    private static let createUrl = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    private static let generateItUrl = URL(string: "https://www.youtube.com/api/jnn/v1/GenerateIT")!
    // Öffentliche Kennungen des YouTube-Web-Clients (wie in NewPipe und der Android-App), keine Geheimnisse.
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let expiryMarginSeconds: Int64 = 600

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var expiresAt = Date.distantPast
    private var closed = false

    var isExpired: Bool { closed || Date() >= expiresAt }

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = nil
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
    }

    /// Zeitgeber laufen in WebViews ohne Fenster nur gedrosselt: unsichtbar ins Fenster hängen (sobald eines existiert).
    private func attachToWindow() {
        guard webView.superview == nil else { return }
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first?.addSubview(webView)
    }

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
        attachToWindow()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            webView.loadHTMLString(PoTokenHtml.page, baseURL: URL(string: "https://www.youtube.com"))
        }
        let challenge = try BotGuardJson.parseChallengeData(try await post(transport, Self.createUrl, "[ \"\(Self.requestKey)\" ]"))
        let response = try await webView.callAsyncJavaScript(
            """
            const r = await runBotGuard(JSON.parse(challenge));
            window.webPoSignalOutput = r.webPoSignalOutput;
            return r.botguardResponse;
            """,
            arguments: ["challenge": challenge], in: nil, contentWorld: .page)
        guard let botguardResponse = response as? String, !botguardResponse.isEmpty else { throw PoTokenError("BotGuard ohne Antwort") }
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [botguardResponse]), encoding: .utf8)!
        let body = "[ \"\(Self.requestKey)\", \(quoted.dropFirst().dropLast()) ]"
        let integrity = try BotGuardJson.parseIntegrityToken(try await post(transport, Self.generateItUrl, body))
        expiresAt = Date().addingTimeInterval(TimeInterval(max(integrity.lifetimeSeconds - Self.expiryMarginSeconds, 60)))
        _ = try await webView.callAsyncJavaScript("window.integrityToken = new Uint8Array(bytes); return true;",
                                                  arguments: ["bytes": integrity.bytes.map { Int($0) }], in: nil, contentWorld: .page)
    }

    /// Prägt einen Token für [identifier] (Video-ID oder visitorData).
    func mint(_ identifier: String) async throws -> String {
        guard !closed else { throw PoTokenError("Generator nicht mehr nutzbar") }
        guard BotGuardJson.isSafeIdentifier(identifier) else { throw PoTokenError("Bezeichner ungültig") }
        let result = try await webView.callAsyncJavaScript(
            """
            const u8 = obtainPoToken(window.webPoSignalOutput, window.integrityToken, new Uint8Array(bytes));
            return Array.prototype.join.call(u8, ",");
            """,
            arguments: ["bytes": Array(identifier.utf8).map { Int($0) }], in: nil, contentWorld: .page)
        guard let joined = result as? String else { throw PoTokenError("PO-Token ohne Ergebnis") }
        return try BotGuardJson.u8ToBase64(joined)
    }

    /// Gibt das WebView frei. Mehrfach aufrufbar.
    func close() {
        guard !closed else { return }
        closed = true
        loadContinuation?.resume(throwing: PoTokenError("Generator freigegeben"))
        loadContinuation = nil
        webView.stopLoading()
        webView.removeFromSuperview()
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

extension WebViewPoTokenGenerator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume(); loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error); loadContinuation = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close()
    }

    // Nichts nachladen: Nur die eigene Seite, alles andere (Weiterleitungen, Frames) wird verworfen.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" || navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
