import Foundation

/// Geprüfte Kopplungsanfrage aus dem QR-Link des Fernsehers (`gueventube://pair?h=&p=&fp=&tk=&n=`).
public struct PairRequest: Equatable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var name: String
    public var fingerprint: [UInt8]
    public var token: String
    /// Das Token ist ein Geheimnis und steht nie in Logs.
    public var description: String { "PairRequest(host=\(host), port=\(port), name=\(name), token=<redacted>)" }
}

public enum LinkPairUri {
    public static let scheme = "gueventube"
    static let maxName = 64

    /// Wie Android `parsePairUri`: jede Webseite kann so einen Link auslösen, deshalb nur Adressen im Heimnetz (IP-Literale).
    public static func parse(_ text: String) -> PairRequest? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == scheme, c.host == "pair" else { return nil }
        func q(_ k: String) -> String? { c.queryItems?.first { $0.name == k }?.value }
        guard var host = q("h")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if host.hasPrefix("[") { host.removeFirst() }
        if host.hasSuffix("]") { host.removeLast() }
        guard isLocalNetworkHost(host),
              let port = q("p").flatMap({ Int($0) }), (1...65535).contains(port),
              let fp = q("fp").flatMap({ LinkB64.decode($0) }), !fp.isEmpty,
              let token = q("tk"), !token.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let rawName = q("n").map { String($0.prefix(maxName)) } ?? ""
        let name = rawName.trimmingCharacters(in: .whitespaces).isEmpty ? "Fernseher" : rawName
        return PairRequest(host: host, port: port, name: name, fingerprint: [UInt8](fp), token: token)
    }

    /// `true` nur für IP-Literale im Heimnetz: RFC 1918, link-local (169.254/16, fe80::/10), IPv6-ULA (fc00::/7), Loopback.
    /// Hostnamen werden nie aufgelöst.
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        if let o = ipv4(host) {
            return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
                || (o[0] == 169 && o[1] == 254) || o[0] == 127
        }
        guard let h = ipv6(host) else { return false }
        let loopback = h.dropLast().allSatisfy { $0 == 0 } && h.last == 1
        return loopback || (h[0] & 0xFFC0) == 0xFE80 || (h[0] & 0xFE00) == 0xFC00
    }

    private static func ipv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(p), n <= 255 else { return nil }
            out.append(n)
        }
        return out
    }

    /// Strenger Parser: 8 Gruppen, höchstens ein `::`, ohne Zonen-ID/IPv4-Anhang.
    private static func ipv6(_ s: String) -> [Int]? {
        guard s.contains(":"), s.allSatisfy({ $0 == ":" || $0.isHexDigit && $0.isASCII }) else { return nil }
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ p: String) -> [Int]? {
            if p.isEmpty { return [] }
            var out: [Int] = []
            for g in p.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(g.count), let n = Int(g, radix: 16) else { return nil }
                out.append(n)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        let tail: [Int]
        if halves.count == 2 { guard let t = groups(halves[1]) else { return nil }; tail = t } else { tail = [] }
        let missing = 8 - head.count - tail.count
        if halves.count == 2 && missing < 1 { return nil }
        if halves.count == 1 && head.count != 8 { return nil }
        return head + Array(repeating: 0, count: max(missing, 0)) + tail
    }
}
