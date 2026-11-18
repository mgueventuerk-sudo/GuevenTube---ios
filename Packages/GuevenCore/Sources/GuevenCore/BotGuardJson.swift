import Foundation

/// Fehler bei der Erzeugung eines PO-Tokens (nie mit Token-Inhalt in der Meldung).
public struct PoTokenError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Hilfsfunktionen für die BotGuard-Antworten (`/api/jnn/v1/Create`, `/GenerateIT`). Reine Funktionen, testbar ohne WebView.
///
/// Portiert aus der Android-App (`BotGuardJson.kt`), die sie aus NewPipe übernommen hat (`JavaScriptUtil.kt`, GPLv3,
/// https://github.com/TeamNewPipe/NewPipe).
public enum BotGuardJson {

    /// Aufbereitete Challenge als JavaScript-Objektliteral (JSON) für `runBotGuard(data)`.
    public static func parseChallengeData(_ raw: String) throws -> String {
        guard let data = raw.data(using: .utf8), let scrambled = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw PoTokenError("Challenge nicht lesbar")
        }
        let challenge: [Any]
        if scrambled.count > 1, let text = scrambled[1] as? String {
            guard let inner = descramble(text).data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: inner)) as? [Any] else {
                throw PoTokenError("Challenge nicht entschlüsselbar")
            }
            challenge = parsed
        } else if let first = scrambled.first as? [Any] {
            challenge = first
        } else {
            throw PoTokenError("Challenge ohne Inhalt")
        }
        func str(_ i: Int) -> String? { challenge.indices.contains(i) ? challenge[i] as? String : nil }
        func firstString(_ i: Int) -> String? { challenge.indices.contains(i) ? (challenge[i] as? [Any])?.first(where: { $0 is String }) as? String : nil }
        guard let script = firstString(1) else { throw PoTokenError("Challenge ohne Interpreter-Skript") }
        guard let program = str(4) else { throw PoTokenError("Challenge ohne Programm") }
        guard let globalName = str(5) else { throw PoTokenError("Challenge ohne globalen Namen") }
        let object: [String: Any] = [
            "messageId": str(0) as Any? ?? NSNull(),
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": script,
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": firstString(2) as Any? ?? NSNull(),
            ] as [String: Any],
            "interpreterHash": str(3) as Any? ?? NSNull(),
            "program": program,
            "globalName": globalName,
            "clientExperimentsStateBlob": str(7) as Any? ?? NSNull(),
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: object), let text = String(data: out, encoding: .utf8) else {
            throw PoTokenError("Challenge nicht darstellbar")
        }
        return text
    }

    /// Integritäts-Token als Byte-Liste und Gültigkeit in Sekunden.
    public static func parseIntegrityToken(_ raw: String) throws -> (bytes: [UInt8], lifetimeSeconds: Int64) {
        guard let data = raw.data(using: .utf8), let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw PoTokenError("GenerateIT nicht lesbar")
        }
        guard let token = array.first as? String else { throw PoTokenError("GenerateIT ohne Token") }
        let seconds = (array.count > 1 ? (array[1] as? NSNumber)?.int64Value : nil) ?? defaultLifetimeSeconds
        return (try base64ToBytes(token), seconds)
    }

    /// Ausgabe von `Array.join(",")` über ein `Uint8Array` („97,98,99“) → PO-Token in YouTubes URL-sicherem Base64.
    public static func u8ToBase64(_ commaSeparated: String) throws -> String {
        var bytes: [UInt8] = []
        for part in commaSeparated.split(separator: ",") {
            guard let v = UInt8(part.trimmingCharacters(in: .whitespaces)) else { throw PoTokenError("PO-Token nicht lesbar") }
            bytes.append(v)
        }
        guard !bytes.isEmpty else { throw PoTokenError("leerer PO-Token") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Nur Bezeichner, die sicher als JS-Zahlenliste übergeben werden (Video-ID oder visitorData).
    public static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.%=".contains($0) }
    }

    static func descramble(_ scrambled: String) -> String {
        guard let bytes = try? base64ToBytes(scrambled) else { return "" }
        return String(decoding: bytes.map { $0 &+ 97 }, as: UTF8.self)
    }

    static func base64ToBytes(_ value: String) throws -> [UInt8] {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        while normalized.count % 4 != 0 { normalized += "=" }
        guard let data = Data(base64Encoded: normalized) else { throw PoTokenError("Base64 nicht lesbar") }
        return [UInt8](data)
    }

    static let defaultLifetimeSeconds: Int64 = 3_600
}
