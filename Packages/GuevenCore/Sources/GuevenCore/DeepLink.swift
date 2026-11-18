import Foundation

/// Eingehende Links: Widget (`gueventube://play?v=…`), YouTube-Links (`youtu.be`, `youtube.com/watch`, `/shorts/`, `/live/`)
/// und Kopplungs-Links des Fernsehers (`gueventube://pair?…`).
public enum DeepLink: Equatable, Sendable {
    case play(videoId: String, startSeconds: Int?)
    case pair(PairRequest)

    public static func parse(_ text: String) -> DeepLink? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased() else { return nil }
        let items = Dictionary((comps.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let start = items["t"].flatMap(parseSeconds) ?? items["start"].flatMap(parseSeconds)
        switch scheme {
        case "gueventube":
            switch comps.host?.lowercased() {
            case "pair": return LinkPairUri.parse(text).map(DeepLink.pair)
            case "play": return items["v"].flatMap(validId).map { .play(videoId: $0, startSeconds: start) }
            default: return nil
            }
        case "http", "https":
            guard var host = comps.host?.lowercased() else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if host.hasPrefix("m.") { host.removeFirst(2) }
            let parts = comps.path.split(separator: "/").map(String.init)
            switch host {
            case "youtu.be":
                return parts.first.flatMap(validId).map { .play(videoId: $0, startSeconds: start) }
            case "youtube.com", "music.youtube.com":
                if parts.first == "watch" { return items["v"].flatMap(validId).map { .play(videoId: $0, startSeconds: start) } }
                if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) { return validId(parts[1]).map { .play(videoId: $0, startSeconds: start) } }
                return nil
            default: return nil
            }
        default: return nil
        }
    }

    static func validId(_ s: String) -> String? {
        s.utf8.count == 11 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 } ? s : nil
    }

    /// Obergrenze je Angabe (ca. 31 Jahre): größere Werte aus fremden Links würden beim Umrechnen überlaufen und die App abstürzen lassen.
    static let maxSeconds = 1_000_000_000

    /// `90`, `90s` oder `1h2m3s`.
    static func parseSeconds(_ s: String) -> Int? {
        if let n = Int(s.hasSuffix("s") ? String(s.dropLast()) : s) { return (0...maxSeconds).contains(n) ? n : nil }
        var total = 0, num = ""
        for ch in s {
            if ch.isNumber { num.append(ch); continue }
            guard let n = Int(num), n <= maxSeconds else { return nil }
            switch ch { case "h": total += n * 3600; case "m": total += n * 60; case "s": total += n; default: return nil }
            num = ""
        }
        return num.isEmpty && total > 0 ? total : nil
    }
}
