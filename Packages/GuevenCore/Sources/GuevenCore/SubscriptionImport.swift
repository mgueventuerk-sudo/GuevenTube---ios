import Foundation

/// Abo-Import für den Gast-Modus: Google Takeout (`subscriptions.csv`) und NewPipe-Export (`subscriptions.json`). Unbekannte
/// Formate werden nach Kanal-IDs (`UC…`) durchsucht.
public enum SubscriptionImport {
    public struct ImportedChannel: Equatable, Sendable {
        public var channelId: String
        public var name: String
        public init(channelId: String, name: String) { self.channelId = channelId; self.name = name }
    }

    private static let channelIdPattern = try! NSRegularExpression(pattern: "UC[A-Za-z0-9_-]{22}")

    public static func parse(_ text: String) -> [ImportedChannel] {
        let trimmed = String(text.drop { "\u{FEFF} \n\r\t".contains($0) })
        var result = trimmed.hasPrefix("{") ? parseNewPipe(trimmed) : parseCsv(trimmed)
        if result.isEmpty { result = matches(in: trimmed).map { ImportedChannel(channelId: $0, name: $0) } }
        var seen = Set<String>()
        return result.filter { seen.insert($0.channelId).inserted }
    }

    private static func matches(in s: String) -> [String] {
        channelIdPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func parseNewPipe(_ text: String) -> [ImportedChannel] {
        guard let root = try? JSONParser.parse(text), root.objectValue != nil else { return [] }
        var out: [ImportedChannel] = []
        for entry in root.arr("subscriptions") ?? [] {
            guard entry.objectValue != nil else { continue }
            // Ein Feld mit Objekt/Array statt Text macht die ganze Datei unbrauchbar (wie bei Android).
            for key in ["url", "name"] { if let v = entry.objectValue?[key], v.isContainer { return [] } }
            guard let url = entry.str("url"), let id = matches(in: url).first else { continue }
            out.append(ImportedChannel(channelId: id, name: entry.str("name") ?? id))
        }
        return out
    }

    /// Takeout: „Kanal-ID,Kanal-URL,Kanaltitel“ (Titel kann Kommas in Anführungszeichen enthalten).
    private static func parseCsv(_ text: String) -> [ImportedChannel] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).compactMap { line in
            let line = String(line)
            guard let id = matches(in: line).first else { return nil }
            let fields = splitCsv(line)
            let name = fields.count > 2 && !fields[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fields[2] : id
            return ImportedChannel(channelId: id, name: name)
        }
    }

    static func splitCsv(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && quoted && i + 1 < chars.count && chars[i + 1] == "\"" { current.append("\""); i += 1 }
            else if c == "\"" { quoted.toggle() }
            else if c == "," && !quoted { fields.append(current); current = "" }
            else { current.append(c) }
            i += 1
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private extension JSON {
    var isContainer: Bool { switch self { case .object, .array: return true; default: return false } }
}
