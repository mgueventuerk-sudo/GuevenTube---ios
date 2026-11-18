import Foundation

/// "1:02:03" / "4:05" → Sekunden; nil bei ungültiger Eingabe.
public func parseClock(_ text: String) -> Int? {
    let parts = text.split(separator: ":").map { Int($0) }
    guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}
