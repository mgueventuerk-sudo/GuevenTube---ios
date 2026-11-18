import XCTest
@testable import GuevenCore

/// Port von `PlaybackChainTest.kt`, `RouteHealthTest.kt`, `FailureKindTest.kt`.
final class PlaybackChainTests: XCTestCase {
    private let profiles = DefaultPlayerClients.all
    private var jsProfiles: [PlayerClientProfile] { profiles.filter(\.requiresJsPlayer) }
    private func hedgeRoutes() -> [PlaybackRoute] { PlaybackRoute.build(profiles: jsProfiles, hasAccount: false, hasPoToken: false) }

    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
    }
    final class Flag: @unchecked Sendable { var value = false }

    func testSignedInWithoutPoTokenStartsWithJsFreeRouteThenTvThenEmbedded() {
        let routes = PlaybackRoute.build(profiles: profiles, hasAccount: true, hasPoToken: false)
        XCTAssertEqual(routes.map { "\($0.profile.id)/\($0.useAccount)" },
                       ["visionos/false", "tv_samsung/true", "tv_samsung/false", "web_embedded/false"])
        XCTAssertEqual(routes[0].label, "visionOS")
        XCTAssertEqual(routes[1].label, "TV (Samsung) · mit Konto")
        XCTAssertEqual(routes[2].label, "TV (Samsung) · ohne Anmeldung")
    }

    func testGuestSkipsAccountRouteAndPoTokenEnablesWeb() {
        let guest = PlaybackRoute.build(profiles: profiles, hasAccount: false, hasPoToken: false)
        XCTAssertEqual(guest.map(\.profile.id), ["visionos", "tv_samsung", "web_embedded"])
        XCTAssertTrue(guest.allSatisfy { !$0.useAccount })
        XCTAssertEqual(PlaybackRoute.build(profiles: profiles, hasAccount: false, hasPoToken: true).map(\.profile.id),
                       ["visionos", "tv_samsung", "web_embedded", "web"])
    }

    func testFallsThroughFailuresToFirstWorkingRoute() async throws {
        let routes = PlaybackRoute.build(profiles: jsProfiles, hasAccount: true, hasPoToken: false)
        let attempts = AttemptLog()
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: attempts) { route in
            if route.useAccount { throw PlaybackUnavailableError(status: "UNPLAYABLE", message: "UNPLAYABLE – Die Seite muss neu geladen werden.") }
            if route.profile.id == "tv_samsung" { throw InnerTubeError(statusCode: 403, message: "verboten") }
            return "ok:\(route.profile.id)"
        }
        XCTAssertEqual(result, "ok:web_embedded")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.all[0].outcome, .failed)
        XCTAssertTrue(attempts.all[0].detail.contains("neu geladen"))
        XCTAssertEqual(attempts.all[1].detail, "HTTP 403")
    }

    func testAllRoutesFailingReportsFirstReasonAndFullProtocol() async {
        let routes = PlaybackRoute.build(profiles: jsProfiles, hasAccount: true, hasPoToken: false)
        do {
            let _: String = try await firstSuccessfulRoute(routes: routes, attempts: AttemptLog()) { route in
                if route.profile.id == "web_embedded" { throw URLError(.timedOut) }
                throw PlaybackUnavailableError(status: "UNPLAYABLE", message: "UNPLAYABLE – Die Seite muss neu geladen werden.")
            }
            XCTFail("Erwartete PlaybackUnavailableError")
        } catch let e as PlaybackUnavailableError {
            XCTAssertEqual(e.status, "UNPLAYABLE")
            XCTAssertEqual(e.message, "UNPLAYABLE – Die Seite muss neu geladen werden.")
            XCTAssertEqual(e.attempts.count, 3)
            XCTAssertEqual(e.attempts[2].detail, "Netzwerkfehler (URLError)")
            XCTAssertTrue(e.attempts.allSatisfy { $0.displayLine().hasPrefix("✗ ") })
        } catch { XCTFail("\(error)") }
    }

    func testNoRoutesGivesConnectionHint() async {
        do { let _: String = try await firstSuccessfulRoute(routes: [], attempts: AttemptLog()) { _ in "nie" }; XCTFail() }
        catch let e as PlaybackUnavailableError { XCTAssertEqual(e.status, "NO_ROUTE") } catch { XCTFail("\(error)") }
    }

    /// Ein hängender Weg darf die anderen nicht blockieren: nach der Zeitgrenze weiter zum nächsten.
    func testHangingRouteTimesOutAndNextRouteWins() async throws {
        let routes = PlaybackRoute.build(profiles: jsProfiles, hasAccount: false, hasPoToken: false)
        let attempts = AttemptLog()
        let technical = Log()
        let first = routes[0]
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: attempts, routeTimeoutMs: 50,
                                                            onTechnicalFailure: { technical.add($0.label) }) { route in
            if route == first { try await Task.sleep(nanoseconds: 10_000_000_000) }
            return "ok:\(route.profile.id)"
        }
        XCTAssertEqual(result, "ok:\(routes[1].profile.id)")
        XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(attempts.all[0].detail.hasPrefix("Zeitüberschreitung"))
        XCTAssertEqual(technical.all, [first.label])
    }

    /// Ungelöster n-Parameter ist kein Defekt des Wegs: zählt nicht für die Pause.
    func testUnsolvedNParameterDoesNotPauseRoute() async throws {
        let routes = PlaybackRoute.build(profiles: jsProfiles, hasAccount: false, hasPoToken: false)
        let technical = Log()
        let first = routes[0]
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: AttemptLog(), onTechnicalFailure: { technical.add($0.label) }) { route in
            if route == first { throw PlaybackUnavailableError(status: "N_PARAMETER", message: "gedrosselt") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertTrue(technical.all.isEmpty)
    }

    // MARK: Zeitversetzt parallele Wege

    func testHedgedHangingRouteDoesNotDelayNextRoute() async throws {
        let routes = hedgeRoutes()
        let technical = Log()
        let attempts = AttemptLog()
        let cancelled = Flag()
        let first = routes[0]
        let started = Date()
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: attempts, routeTimeoutMs: 10_000, hedgeDelayMs: 50,
                                                            onTechnicalFailure: { technical.add($0.label) }) { route in
            if route == first {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { cancelled.value = true; throw error }
            }
            return "ok:\(route.profile.id)"
        }
        XCTAssertEqual(result, "ok:\(routes[1].profile.id)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(cancelled.value)
        // Der abgebrochene Weg ist kein Fehlschlag und wird nicht pausiert.
        XCTAssertEqual(attempts.count, 0)
        XCTAssertTrue(technical.all.isEmpty)
    }

    func testHedgedSlowValidRouteStillWins() async throws {
        let routes = hedgeRoutes()
        let attempts = AttemptLog()
        let first = routes[0]
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: attempts, hedgeDelayMs: 20) { route in
            if route == first { try await Task.sleep(nanoseconds: 300_000_000); return "langsam-ok" }
            throw InnerTubeError(statusCode: 403, message: "verboten")
        }
        XCTAssertEqual(result, "langsam-ok")
        XCTAssertTrue(attempts.all.allSatisfy { $0.detail == "HTTP 403" })
    }

    /// Scheitern alle, zählt die Meldung des ersten Wegs in Wegreihenfolge, nicht des zeitlich ersten Fehlers.
    func testHedgedAllFailingReportsFirstRouteReason() async {
        let routes = hedgeRoutes()
        let first = routes[0]
        do {
            let _: String = try await firstSuccessfulRoute(routes: routes, attempts: AttemptLog(), hedgeDelayMs: 10) { route in
                if route == first {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    throw PlaybackUnavailableError(status: "LOGIN_REQUIRED", message: "Altersbeschränkt")
                }
                throw PlaybackUnavailableError(status: "UNPLAYABLE", message: "anderer Grund")
            }
            XCTFail()
        } catch let e as PlaybackUnavailableError {
            XCTAssertEqual(e.status, "LOGIN_REQUIRED")
            XCTAssertEqual(e.attempts.count, routes.count)
        } catch { XCTFail("\(error)") }
    }

    /// Scheitert ein Weg sofort, startet der nächste ohne Versatz.
    func testHedgedFailureStartsNextImmediately() async throws {
        let routes = hedgeRoutes()
        let first = routes[0]
        let started = Date()
        let result: String = try await firstSuccessfulRoute(routes: routes, attempts: AttemptLog(), hedgeDelayMs: 5_000) { route in
            if route == first { throw URLError(.notConnectedToInternet) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// Eine fremde CancellationError ist nur ein Fehlschlag dieses Wegs.
    func testStrayCancellationErrorIsRouteFailureNotAbort() async throws {
        let routes = hedgeRoutes()
        let first = routes[0]
        for hedge in [Int64.max, 50] {
            let attempts = AttemptLog()
            let result: String = try await firstSuccessfulRoute(routes: routes, attempts: attempts, hedgeDelayMs: hedge) { route in
                if route == first { throw CancellationError() }
                return "ok"
            }
            XCTAssertEqual(result, "ok")
            XCTAssertTrue(attempts.all.first?.detail.hasPrefix("Abgebrochen") == true)
        }
    }

    // MARK: RouteHealth

    final class MemoryStore: PreferredRouteStore, @unchecked Sendable {
        var value: String?
        func preferred() -> String? { value }
        func setPreferred(_ label: String?) { value = label }
    }
    final class Clock: @unchecked Sendable { var now: Int64 = 0 }

    func testLastSuccessfulRouteComesFirstAndIsRemembered() {
        let clock = Clock(); let store = MemoryStore()
        let health = RouteHealth(store: store) { clock.now }
        let routes = PlaybackRoute.build(profiles: profiles, hasAccount: true, hasPoToken: false)
        XCTAssertEqual(health.order(routes).map(\.label), routes.map(\.label))
        health.recordSuccess("Web (eingebettet)")
        XCTAssertEqual(health.order(routes).first?.label, "Web (eingebettet)")
        XCTAssertEqual(store.value, "Web (eingebettet)")
        XCTAssertEqual(RouteHealth(store: store) { clock.now }.order(routes).first?.label, "Web (eingebettet)")
    }

    func testRepeatedTechnicalFailuresPauseRouteThenItRecovers() {
        let clock = Clock(); let store = MemoryStore()
        let health = RouteHealth(store: store) { clock.now }
        let routes = PlaybackRoute.build(profiles: profiles, hasAccount: true, hasPoToken: false)
        health.recordSuccess("visionOS")
        for _ in 0..<RouteHealth.failureThreshold { health.recordTechnicalFailure("visionOS") }
        XCTAssertTrue(health.isPaused("visionOS"))
        XCTAssertEqual(health.order(routes).last?.label, "visionOS")
        XCTAssertNil(store.value)
        clock.now += RouteHealth.coolDownMs + 1
        XCTAssertFalse(health.isPaused("visionOS"))
        XCTAssertEqual(health.order(routes).map(\.label), routes.map(\.label))
    }

    func testContentReasonsDoNotCount() {
        XCTAssertFalse(RouteHealth.isTechnicalFailure("LOGIN_REQUIRED"))
        XCTAssertFalse(RouteHealth.isTechnicalFailure("ERROR"))
        XCTAssertTrue(RouteHealth.isTechnicalFailure("UNPLAYABLE"))
        XCTAssertTrue(RouteHealth.isTechnicalFailure("NO_STREAMS"))
    }

    // MARK: FailureKind

    func testClassifiesFailures() {
        XCTAssertEqual(FailureKind.of(status: FailureKind.sabrStatus, message: "keine Stream-URLs (nur SABR)"), .sabrOnly)
        XCTAssertEqual(FailureKind.of(status: "LOGIN_REQUIRED", message: "LOGIN_REQUIRED – Sign in to confirm you’re not a bot"), .botCheck)
        XCTAssertEqual(FailureKind.of(status: "LOGIN_REQUIRED", message: "LOGIN_REQUIRED – This video is private"), .content)
        XCTAssertEqual(FailureKind.of(status: "UNPLAYABLE", message: "UNPLAYABLE – Die Seite muss neu geladen werden."), .technical)
        XCTAssertEqual(FailureKind.of(status: "ERROR", message: "Video nicht verfügbar"), .content)
    }

    func testSummaryIsSortedAndUnique() {
        XCTAssertEqual(FailureKind.summary([.botCheck, .sabrOnly, .botCheck]), "sabr+bot")
        XCTAssertEqual(FailureKind.summary([]), "-")
    }

    // MARK: URL-Hilfen

    func testURLQueryMatchesAndroidUriBehaviour() {
        XCTAssertEqual(URLQuery.parameter("n", in: "https://x/v?a=1&n=ab%2Bc&b=2"), "ab+c")
        XCTAssertEqual(URLQuery.appending("pot", "a+b/c=", to: "https://x/v?a=1"), "https://x/v?a=1&pot=a%2Bb%2Fc%3D")
        XCTAssertEqual(URLQuery.appending("sig", "S", to: "https://x/v"), "https://x/v?sig=S")
        XCTAssertEqual(URLQuery.replacing("n", with: "NEU", in: "https://x/v?a=1&n=alt&b=%C3%A4"), "https://x/v?a=1&n=NEU&b=%C3%A4")
    }
}
