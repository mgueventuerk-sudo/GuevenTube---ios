import Foundation

/// Ergebnis eines einzelnen Abspielwegs (für Fehlerdetails und den Wiedergabe-Test).
public struct ClientAttempt: Equatable, Sendable {
    public enum Outcome: Sendable { case ok, failed, skipped }
    public var label: String
    public var outcome: Outcome
    public var detail: String

    public init(label: String, outcome: Outcome, detail: String) { self.label = label; self.outcome = outcome; self.detail = detail }

    /// Eine Zeile für die Oberfläche, z. B. „✗ TV (Samsung) · mit Konto: UNPLAYABLE – …".
    public func displayLine() -> String {
        let mark: String
        switch outcome { case .ok: mark = "✓"; case .failed: mark = "✗"; case .skipped: mark = "–" }
        return "\(mark) \(label): \(detail)"
    }
}

/// Ein Abspielweg hat sein Zeitbudget überschritten.
struct RouteTimeoutError: Error { let timeoutMs: Int64 }

public struct PlaybackUnavailableError: Error, CustomStringConvertible, Sendable {
    public var status: String
    public var message: String
    public var attempts: [ClientAttempt]
    /// Arten der Fehlschläge aller Wege (Frühwarnung).
    public var kinds: Set<FailureKind>
    public init(status: String, message: String, attempts: [ClientAttempt] = [], kinds: Set<FailureKind> = []) {
        self.status = status; self.message = message; self.attempts = attempts; self.kinds = kinds
    }
    public var description: String { message }
}

/// Ein konkreter Abspielweg: Profil plus „mit Konto" oder „ohne Anmeldung".
public struct PlaybackRoute: Equatable, Sendable {
    public var profile: PlayerClientProfile
    public var useAccount: Bool

    public var label: String {
        if useAccount { return "\(profile.label) · mit Konto" }
        if profile.supportsOAuth { return "\(profile.label) · ohne Anmeldung" }
        return profile.label
    }

    /// Vom Nutzer gewählter Client zuerst, die übrigen bleiben in ihrer Reihenfolge als Rückfall. Unbekannte Wahl: unverändert.
    public static func prioritize(_ routes: [PlaybackRoute], pinnedProfileId: String?) -> [PlaybackRoute] {
        guard let id = pinnedProfileId, routes.contains(where: { $0.profile.id == id }) else { return routes }
        return routes.filter { $0.profile.id == id } + routes.filter { $0.profile.id != id }
    }

    /// Reihenfolge: Profile mit Konto-Unterstützung zuerst angemeldet, dann jeweils anonym; Profile, die einen
    /// PO-Token verlangen, nur mit Token.
    public static func build(profiles: [PlayerClientProfile], hasAccount: Bool, hasPoToken: Bool) -> [PlaybackRoute] {
        var routes: [PlaybackRoute] = []
        for p in profiles {
            if p.requiresPoToken && !hasPoToken { continue }
            if p.supportsOAuth && hasAccount { routes.append(PlaybackRoute(profile: p, useAccount: true)) }
            routes.append(PlaybackRoute(profile: p, useAccount: false))
        }
        return routes
    }
}

/// Threadsicheres Protokoll der Wege (bei zeitversetztem Parallelbetrieb).
public final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClientAttempt] = []
    public init() {}
    public func append(_ a: ClientAttempt) { lock.withLock { items.append(a) } }
    public var all: [ClientAttempt] { lock.withLock { items } }
    public var count: Int { lock.withLock { items.count } }
}

private final class FailureSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [PlaybackUnavailableError?]
    init(_ n: Int) { slots = Array(repeating: nil, count: n) }
    func set(_ i: Int, _ e: PlaybackUnavailableError) { lock.withLock { slots[i] = e } }
    var first: PlaybackUnavailableError? { lock.withLock { slots.compactMap { $0 }.first } }
}

/// Führt [op] aus; liefert `nil`, wenn [ms] vorher abgelaufen sind (die Operation wird dann abgebrochen).
/// Anders als ein werfendes Timeout bricht das nur diesen Weg ab, nicht die ganze Auflösung.
func withTimeoutOrNil<T: Sendable>(ms: Int64, sleepMs: @escaping @Sendable (Int64) async throws -> Void,
                                   _ op: @escaping @Sendable () async throws -> T) async throws -> T? {
    if ms == .max { return try await op() }
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask { try await sleepMs(ms); return nil }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

enum RaceEvent<T: Sendable>: Sendable { case done(T?), tick(Int) }

/// Probiert [routes] mit [block], bis einer ein Ergebnis liefert. Jeder Fehlschlag wird in [attempts]
/// protokolliert (Erfolge protokolliert [block] selbst). Scheitern alle, wird eine
/// [PlaybackUnavailableError] mit der Meldung des ersten inhaltlichen Fehlschlags in Wegreihenfolge und dem
/// vollständigen Protokoll geworfen.
///
/// [hedgeDelayMs]: Antwortet ein Weg nach dieser Zeit noch nicht, startet der nächste parallel; der erste
/// Erfolg gewinnt, die übrigen werden abgebrochen. Scheitert ein Weg, startet der nächste sofort. Ohne Wert:
/// streng nacheinander.
func firstSuccessfulRoute<T: Sendable>(
    routes: [PlaybackRoute],
    attempts: AttemptLog,
    routeTimeoutMs: Int64 = .max,
    hedgeDelayMs: Int64 = .max,
    sleepMs: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
    onTechnicalFailure: @escaping @Sendable (PlaybackRoute) -> Void = { _ in },
    onFailureKind: @escaping @Sendable (FailureKind) -> Void = { _ in },
    block: @escaping @Sendable (PlaybackRoute) async throws -> T
) async throws -> T {
    let failures = FailureSlots(routes.count)

    /// Ein Weg: Ergebnis oder nil (Fehlschlag protokolliert). Echte Abbrüche werden weitergereicht.
    @Sendable func attempt(_ index: Int) async throws -> T? {
        let route = routes[index]
        func fail(_ detail: String, technical: Bool = true, kind: FailureKind = .technical) {
            attempts.append(ClientAttempt(label: route.label, outcome: .failed, detail: detail))
            if technical { onTechnicalFailure(route) }
            onFailureKind(kind)
        }
        do {
            guard let value = try await withTimeoutOrNil(ms: routeTimeoutMs, sleepMs: sleepMs, { try await block(route) }) else {
                throw RouteTimeoutError(timeoutMs: routeTimeoutMs)
            }
            return value
        } catch let error as PlaybackUnavailableError {
            try Task.checkCancellation() // abgebrochener Verlierer: kein Fehlschlag des Wegs
            attempts.append(ClientAttempt(label: route.label, outcome: .failed, detail: error.message))
            failures.set(index, error)
            onFailureKind(FailureKind.of(status: error.status, message: error.message))
            if error.status != "N_PARAMETER" && RouteHealth.isTechnicalFailure(error.status) { onTechnicalFailure(route) }
        } catch let error as RouteTimeoutError {
            try Task.checkCancellation()
            fail("Zeitüberschreitung nach \(error.timeoutMs / 1000) s")
        } catch let error as InnerTubeError {
            try Task.checkCancellation()
            fail("HTTP \(error.statusCode)")
        } catch is CancellationError {
            // Echter Abbruch → weiterreichen. Eine fremde CancellationError ist nur ein Fehlschlag dieses Wegs.
            try Task.checkCancellation()
            fail("Abgebrochen (CancellationError)")
        } catch let error as URLError {
            try Task.checkCancellation()
            fail("Netzwerkfehler (\(type(of: error)))")
        } catch {
            try Task.checkCancellation()
            fail("Fehler (\(type(of: error)))")
        }
        return nil
    }

    var result: T?
    if hedgeDelayMs == .max || routes.count < 2 {
        for index in routes.indices {
            try Task.checkCancellation()
            result = try await attempt(index)
            if result != nil { break }
        }
    } else {
        let count = routes.count
        result = try await withThrowingTaskGroup(of: RaceEvent<T>.self) { group in
            var started = 0
            var pending = 0
            func startNext() {
                let i = started
                started += 1
                pending += 1
                group.addTask { .done(try await attempt(i)) }
                if i + 1 < count { group.addTask { try await sleepMs(hedgeDelayMs); return .tick(i) } }
            }
            startNext()
            var winner: T?
            while let event = try await group.next() {
                switch event {
                case .tick(let i): if started == i + 1 && started < count { startNext() }
                case .done(let value):
                    pending -= 1
                    if let value { winner = value; group.cancelAll(); return winner }
                    if started < count { startNext() }
                }
                if pending == 0 && started == count { break }
            }
            group.cancelAll()
            return winner
        }
    }
    if let result { return result }
    let first = failures.first
    throw PlaybackUnavailableError(
        status: first?.status ?? "NO_ROUTE",
        message: first?.message ?? "Kein Abspielweg erreichbar. Prüfe die Internetverbindung.",
        attempts: attempts.all)
}
