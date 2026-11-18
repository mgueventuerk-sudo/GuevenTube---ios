import Foundation

/*
 Null-sichere Navigation durch tief verschachtelte InnerTube-Antworten (Port von JsonNavigation.kt).
 InnerTube ändert Strukturen häufig: alle Zugriffe liefern `nil` statt Fehler.
 */

/// Pfadsegment: Objektschlüssel (String) oder Array-Index (Int).
public enum PathSegment: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)
    public init(stringLiteral value: String) { self = .key(value) }
    public init(integerLiteral value: Int) { self = .index(value) }
}

/// Höchste Tiefe, die die rekursiven Suchen betreten.
public let maxJSONDepth = 256

public extension JSON {
    var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }

    func obj(_ key: String) -> JSON? {
        if case .object(let o)? = objectValue?[key] { return .object(o) }
        return nil
    }

    func arr(_ key: String) -> [JSON]? {
        if case .array(let a)? = objectValue?[key] { return a }
        return nil
    }

    /// String-Wert; Zahlen und Booleans werden als Text geliefert, `null` und Objekte/Arrays nicht.
    func str(_ key: String) -> String? {
        switch objectValue?[key] {
        case .string(let s)?: return s
        case .number(let n)?: return n
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    func long(_ key: String) -> Int64? { str(key).flatMap { Int64($0) } }
    func int(_ key: String) -> Int? { str(key).flatMap { Int($0) } }
    func double(_ key: String) -> Double? { str(key).flatMap { Double($0) } }

    func bool(_ key: String) -> Bool? {
        switch str(key) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Folgt einem Pfad aus Objektschlüsseln und Array-Indizes.
    func path(_ segments: PathSegment...) -> JSON? { path(segments) }

    func path(_ segments: [PathSegment]) -> JSON? {
        var current: JSON = self
        for segment in segments {
            switch (segment, current) {
            case (.key(let k), .object(let o)):
                guard let next = o[k] else { return nil }
                current = next
            case (.index(let i), .array(let a)):
                guard a.indices.contains(i) else { return nil }
                current = a[i]
            default: return nil
            }
        }
        return current
    }

    /// `{"simpleText": …}`, `{"runs": [{"text": …}]}` oder `{"content": …}` der View-Models.
    func text(_ key: String) -> String? { objectValue?[key].asText() }

    /// Sammelt rekursiv alle Objekte unter [key] (Tiefensuche, Dokumentreihenfolge).
    func findAll(_ key: String) -> [JSON] {
        var results: [JSON] = []
        collect(self, key, &results, 0)
        return results
    }

    func findFirst(_ key: String) -> JSON? { findFirstObject(self, key, 0) }

    func findFirstString(_ key: String) -> String? { findFirstStringImpl(self, key, 0) }
}

public extension Optional where Wrapped == JSON {
    var objectValue: JSONObject? { self?.objectValue }
    func obj(_ key: String) -> JSON? { self?.obj(key) }
    func arr(_ key: String) -> [JSON]? { self?.arr(key) }
    func str(_ key: String) -> String? { self?.str(key) }
    func long(_ key: String) -> Int64? { self?.long(key) }
    func int(_ key: String) -> Int? { self?.int(key) }
    func double(_ key: String) -> Double? { self?.double(key) }
    func bool(_ key: String) -> Bool? { self?.bool(key) }
    func path(_ segments: PathSegment...) -> JSON? { self?.path(segments) }
    func text(_ key: String) -> String? { self?.text(key) }
    func findFirst(_ key: String) -> JSON? { self?.findFirst(key) }
    func findAll(_ key: String) -> [JSON] { self?.findAll(key) ?? [] }
    func asText() -> String? {
        guard let node = self else { return nil }
        if case .string(let s) = node { return s }
        guard case .object = node else { return nil }
        if let s = node.str("simpleText") { return s }
        if let s = node.str("content") { return s }
        guard let runs = node.arr("runs") else { return nil }
        let joined = runs.map { $0.str("text") ?? "" }.joined()
        return joined.isEmpty ? nil : joined
    }
}

public extension Array where Element == JSON {
    /// Wählt aus einem `thumbnails`-Array das Bild, dessen Breite [preferredWidth] am nächsten liegt.
    func bestThumbnailUrl(_ preferredWidth: Int = 640) -> String? {
        var best: (url: String, width: Int)?
        for node in self {
            guard let url = node.str("url") else { continue }
            let width = node.int("width") ?? 0
            if best == nil || abs(width - preferredWidth) < abs(best!.width - preferredWidth) { best = (url, width) }
        }
        return best.map { normalizeUrl($0.url) }
    }
}

public extension Optional where Wrapped == [JSON] {
    func bestThumbnailUrl(_ preferredWidth: Int = 640) -> String? { self?.bestThumbnailUrl(preferredWidth) }
}

/// Ergänzt protokollrelative URLs (`//i.ytimg.com/…`).
public func normalizeUrl(_ url: String) -> String { url.hasPrefix("//") ? "https:" + url : url }

private func collect(_ element: JSON, _ key: String, _ out: inout [JSON], _ depth: Int) {
    if depth > maxJSONDepth { return }
    switch element {
    case .object(let o):
        for (k, v) in o.entries {
            if k == key, case .object = v { out.append(v) }
            collect(v, key, &out, depth + 1)
        }
    case .array(let a): for child in a { collect(child, key, &out, depth + 1) }
    default: break
    }
}

private func findFirstObject(_ element: JSON, _ key: String, _ depth: Int) -> JSON? {
    if depth > maxJSONDepth { return nil }
    switch element {
    case .object(let o):
        if case .object? = o[key] { return o[key] }
        for (_, v) in o.entries { if let r = findFirstObject(v, key, depth + 1) { return r } }
        return nil
    case .array(let a):
        for v in a { if let r = findFirstObject(v, key, depth + 1) { return r } }
        return nil
    default: return nil
    }
}

private func findFirstStringImpl(_ element: JSON, _ key: String, _ depth: Int) -> String? {
    if depth > maxJSONDepth { return nil }
    switch element {
    case .object(let o):
        if case .string(let s)? = o[key] { return s }
        for (_, v) in o.entries { if let r = findFirstStringImpl(v, key, depth + 1) { return r } }
        return nil
    case .array(let a):
        for v in a { if let r = findFirstStringImpl(v, key, depth + 1) { return r } }
        return nil
    default: return nil
    }
}
