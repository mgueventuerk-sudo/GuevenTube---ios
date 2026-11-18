import Foundation

/// Art eines gescheiterten Abspielwegs (Frühwarnung): zeigt früh, ob YouTube nur noch SABR liefert oder eine
/// Bot-Prüfung (poToken) verlangt – beides wäre ohne Gegenmaßnahme ein Totalausfall.
public enum FailureKind: Int, CaseIterable, Comparable, Sendable {
    /// Antwort enthält nur eine SABR-Adresse, keine Stream-URLs.
    case sabrOnly
    /// „Melde dich an, um zu bestätigen, dass du kein Bot bist" o. Ä. – poToken nötig.
    case botCheck
    /// Inhaltliche Sperre (privat, Alter, Region, Mitgliedschaft).
    case content
    /// Netz, Zeitüberschreitung, HTTP-Fehler, Entschlüsselung.
    case technical

    public static let sabrStatus = "SABR_ONLY"
    private static let botRegex = try! NSRegularExpression(pattern: #"\bbot\b|not a robot|kein roboter|confirm you.?re not"#, options: .caseInsensitive)

    public var code: String {
        switch self { case .sabrOnly: "sabr"; case .botCheck: "bot"; case .content: "inhalt"; case .technical: "technik" }
    }

    public static func < (l: FailureKind, r: FailureKind) -> Bool { l.rawValue < r.rawValue }

    public static func of(status: String?, message: String?) -> FailureKind {
        if status == sabrStatus { return .sabrOnly }
        if let message, botRegex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil { return .botCheck }
        if let status, !RouteHealth.isTechnicalFailure(status) { return .content }
        return .technical
    }

    /// Kurzform für Messzeilen, z. B. `sabr+bot`, sortiert und ohne Doppelte.
    public static func summary(_ kinds: [FailureKind]) -> String {
        let s = Set(kinds).sorted().map(\.code).joined(separator: "+")
        return s.isEmpty ? "-" : s
    }
}

/// Speichert den zuletzt erfolgreichen Weg über Neustarts hinweg.
public protocol PreferredRouteStore: Sendable {
    func preferred() -> String?
    func setPreferred(_ label: String?)
}

/// Lernende Wegwahl: merkt sich je Abspielweg den letzten Erfolg und zählt technische Fehlschläge.
///
/// - Der zuletzt erfolgreiche Weg wird zuerst probiert.
/// - Nach `failureThreshold` technischen Fehlschlägen in Folge pausiert ein Weg für `coolDownMs` (Circuit
///   Breaker); pausierte Wege werden ans Ende gestellt, nicht gestrichen.
/// - Inhaltliche Gründe („Video privat", Altersgrenze) zählen nicht.
public final class RouteHealth: @unchecked Sendable {
    public static let failureThreshold = 3
    public static let coolDownMs: Int64 = 10 * 60 * 1000
    private static let contentStatuses: Set<String> = ["LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED", "ERROR"]

    /// Diese Status betreffen das Video, nicht den Abspielweg.
    public static func isTechnicalFailure(_ status: String) -> Bool { !contentStatuses.contains(status) }

    private let store: PreferredRouteStore
    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var pausedUntil: [String: Int64] = [:]

    public init(store: PreferredRouteStore, clock: @escaping @Sendable () -> Int64) {
        self.store = store; self.clock = clock
    }

    /// Sortiert [routes]: bevorzugter Weg zuerst, pausierte Wege zuletzt, sonst ursprüngliche Reihenfolge.
    public func order(_ routes: [PlaybackRoute]) -> [PlaybackRoute] {
        lock.withLock {
            let now = clock()
            let preferred = store.preferred()
            return routes.enumerated().sorted { a, b in
                let pa = (pausedUntil[a.element.label] ?? 0) > now ? 1 : 0
                let pb = (pausedUntil[b.element.label] ?? 0) > now ? 1 : 0
                if pa != pb { return pa < pb }
                let fa = a.element.label == preferred ? 0 : 1
                let fb = b.element.label == preferred ? 0 : 1
                if fa != fb { return fa < fb }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    public func recordSuccess(_ routeLabel: String) {
        lock.withLock {
            failures[routeLabel] = nil
            pausedUntil[routeLabel] = nil
            store.setPreferred(routeLabel)
        }
    }

    public func recordTechnicalFailure(_ routeLabel: String) {
        lock.withLock {
            let count = (failures[routeLabel] ?? 0) + 1
            failures[routeLabel] = count
            if count >= Self.failureThreshold {
                pausedUntil[routeLabel] = clock() + Self.coolDownMs
                failures[routeLabel] = nil
                if store.preferred() == routeLabel { store.setPreferred(nil) }
            }
        }
    }

    public func isPaused(_ routeLabel: String) -> Bool { lock.withLock { (pausedUntil[routeLabel] ?? 0) > clock() } }

    /// „Erneut versuchen": alle Pausen aufheben.
    public func reset() { lock.withLock { failures.removeAll(); pausedUntil.removeAll() } }
}
