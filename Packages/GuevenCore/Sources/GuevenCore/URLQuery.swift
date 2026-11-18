import Foundation

/// Abfrageparameter wie `android.net.Uri`: lesen mit Dekodierung, anhängen mit Kodierung (`Uri.encode`).
enum URLQuery {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-!.~'()*".utf8)

    /// Wie `Uri.encode`: alles außer `A-Za-z0-9_-!.~'()*` wird als UTF-8 prozentkodiert.
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 { if unreserved.contains(b) { out.unicodeScalars.append(Unicode.Scalar(b)) } else { out += String(format: "%%%02X", b) } }
        return out
    }

    static func decode(_ s: String) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    /// Roher Abfrageteil ohne Fragment.
    static func rawQuery(of url: String) -> String? {
        let noFragment = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        guard let q = noFragment.firstIndex(of: "?") else { return nil }
        return String(noFragment[noFragment.index(after: q)...])
    }

    static func items(_ query: String?) -> [(name: String, value: String)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(String(kv[0])), kv.count > 1 ? decode(String(kv[1])) : "")
        }
    }

    static func parameter(_ name: String, in url: String) -> String? { items(rawQuery(of: url)).first { $0.name == name }?.value }

    static func appending(_ name: String, _ value: String, to url: String) -> String {
        let (base, fragment) = splitFragment(url)
        let sep = base.contains("?") ? (base.hasSuffix("?") || base.hasSuffix("&") ? "" : "&") : "?"
        return base + sep + encode(name) + "=" + encode(value) + fragment
    }

    /// Ersetzt den Wert von [name] (alle Parameter werden dabei neu kodiert, wie `Uri.Builder`).
    static func replacing(_ name: String, with value: String, in url: String) -> String {
        let (base, fragment) = splitFragment(url)
        let path = base.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? base
        let query = items(rawQuery(of: base)).map { item in
            encode(item.name) + "=" + encode(item.name == name ? value : item.value)
        }.joined(separator: "&")
        return query.isEmpty ? path + fragment : path + "?" + query + fragment
    }

    private static func splitFragment(_ url: String) -> (String, String) {
        guard let h = url.firstIndex(of: "#") else { return (url, "") }
        return (String(url[..<h]), String(url[h...]))
    }
}
