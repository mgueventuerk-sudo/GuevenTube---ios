import Foundation

/// JSON-Wert mit erhaltener Schlüssel-Reihenfolge (Foundations `JSONSerialization` verwirft sie, der Parser
/// braucht aber die Dokumentreihenfolge von YouTube). Zahlen bleiben als Originaltext erhalten.
public indirect enum JSON: Equatable, Sendable {
    case object(JSONObject)
    case array([JSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

public struct JSONObject: Equatable, Sendable {
    public private(set) var entries: [(key: String, value: JSON)] = []
    private var index: [String: Int] = [:]

    public init() {}

    public subscript(key: String) -> JSON? {
        guard let i = index[key] else { return nil }
        return entries[i].value
    }

    /// Doppelte Schlüssel: der letzte Wert gewinnt, die Position bleibt die des ersten (wie `LinkedHashMap`).
    mutating func set(_ key: String, _ value: JSON) {
        if let i = index[key] {
            entries[i].value = value
        } else {
            index[key] = entries.count
            entries.append((key, value))
        }
    }

    public static func == (l: JSONObject, r: JSONObject) -> Bool {
        l.entries.count == r.entries.count && zip(l.entries, r.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

public struct JSONParseError: Error, Equatable {
    public let message: String
    public let offset: Int
}

public enum JSONParser {
    /// Höchste Verschachtelungstiefe beim Einlesen (Schutz vor Stapelüberlauf durch manipulierte Antworten).
    public static let maxDepth = 512

    public static func parse(_ text: String) throws -> JSON { try parse(Array(text.utf8)) }
    public static func parse(_ data: Data) throws -> JSON { try parse(Array(data)) }

    public static func parse(_ bytes: [UInt8]) throws -> JSON {
        var reader = Reader(bytes: bytes)
        reader.skipSpace()
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        if reader.pos != bytes.count { throw reader.fail("Unerwartete Zeichen nach dem JSON-Wert") }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: pos) }

        mutating func skipSpace() {
            while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 { pos += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth <= JSONParser.maxDepth else { throw fail("Zu tief verschachtelt") }
            guard pos < bytes.count else { throw fail("Unerwartetes Ende") }
            switch bytes[pos] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else { throw fail("Ungültiges Literal") }
            pos += w.count
        }

        mutating func number() throws -> JSON {
            let start = pos
            while pos < bytes.count {
                let c = bytes[pos]
                if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                    || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { pos += 1 } else { break }
            }
            guard pos > start else { throw fail("Ungültiges Zeichen") }
            return .number(String(decoding: bytes[start..<pos], as: UTF8.self))
        }

        mutating func object(depth: Int) throws -> JSON {
            pos += 1
            var result = JSONObject()
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(result) }
            while true {
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("Schlüssel erwartet") }
                let key = try string()
                skipSpace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("':' erwartet") }
                pos += 1
                skipSpace()
                result.set(key, try value(depth: depth + 1))
                skipSpace()
                guard pos < bytes.count else { throw fail("Unerwartetes Ende") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(result) }
                throw fail("',' oder '}' erwartet")
            }
        }

        mutating func array(depth: Int) throws -> JSON {
            pos += 1
            var items: [JSON] = []
            skipSpace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard pos < bytes.count else { throw fail("Unerwartetes Ende") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                throw fail("',' oder ']' erwartet")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard pos + 4 <= bytes.count else { throw fail("Ungültiges \\u-Escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[pos]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                default: throw fail("Ungültiges \\u-Escape")
                }
                v = v << 4 | d
                pos += 1
            }
            return v
        }

        mutating func string() throws -> String {
            pos += 1
            var out: [UInt8] = []
            while true {
                guard pos < bytes.count else { throw fail("Nicht beendeter String") }
                let c = bytes[pos]
                if c == UInt8(ascii: "\"") { pos += 1; return String(decoding: out, as: UTF8.self) }
                if c != UInt8(ascii: "\\") { out.append(c); pos += 1; continue }
                pos += 1
                guard pos < bytes.count else { throw fail("Nicht beendeter String") }
                let e = bytes[pos]; pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "/"), UInt8(ascii: "\\"), UInt8(ascii: "\""): out.append(e)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if scalar >= 0xD800 && scalar < 0xDC00, pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                        let save = pos
                        pos += 2
                        let low = try hex4()
                        if low >= 0xDC00 && low < 0xE000 {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else { pos = save }
                    }
                    let ch = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(ch)).utf8))
                default: throw fail("Ungültiges Escape")
                }
            }
        }
    }
}
