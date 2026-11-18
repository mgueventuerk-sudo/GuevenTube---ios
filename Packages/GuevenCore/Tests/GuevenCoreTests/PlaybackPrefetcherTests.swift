import XCTest
@testable import GuevenCore

final class PlaybackPrefetcherTests: XCTestCase {
    final class Env: @unchecked Sendable {
        let l = NSLock()
        var cached: Set<String> = [], instant = true, metered = false, now: Int64 = 1_000_000
        var calls: [String] = [], resolved: [(String, Int64)] = [], results: [String: Bool] = [:]
        var gate: [String: AsyncStream<Void>] = [:]
        func rec(_ id: String) { l.withLock { calls.append(id) } }
    }
    private func make(_ e: Env) -> PlaybackPrefetcher {
        PlaybackPrefetcher(isCached: { id in e.l.withLock { e.cached.contains(id) } },
                           prefetch: { id in
                               e.rec(id)
                               if let g = e.l.withLock({ e.gate[id] }) { for await _ in g { break } }
                               return e.l.withLock { e.results[id] ?? true } },
                           instantStartEnabled: { e.instant }, isMetered: { e.metered },
                           afterResolved: { id, dwell in e.l.withLock { e.resolved.append((id, dwell)) } }, nowMs: { e.now })
    }

    func testLikelyResolvesAndPreloadsImmediately() async {
        let e = Env(); let p = make(e)
        await p.request("a", intent: .likely); await p.waitUntilIdle()
        XCTAssertEqual(e.calls, ["a"]); XCTAssertEqual(e.resolved.first?.0, "a"); XCTAssertEqual(e.resolved.first?.1, 0)
        await p.stop()
    }

    func testSpeculativeWaitsDwellAndFailureSkipsPreload() async {
        let e = Env(); e.results["b"] = false; let p = make(e)
        await p.request("a", intent: .speculative); await p.request("b", intent: .speculative); await p.waitUntilIdle()
        XCTAssertEqual(e.calls, ["a", "b"]); XCTAssertEqual(e.resolved.map(\.0), ["a"]); XCTAssertEqual(e.resolved.first?.1, PlaybackPrefetcher.mediaDwellMs)
        await p.stop()
    }

    func testGuardsCachedDisabledMeteredAndRepeat() async {
        let e = Env(); let p = make(e)
        e.cached = ["c"]; await p.request("c", intent: .likely)
        e.instant = false; await p.request("d", intent: .likely); e.instant = true
        e.metered = true; await p.request("m", intent: .speculative)
        await p.request("t", intent: .likely)                           // angetippt: auch im Mobilfunk
        e.metered = false
        await p.waitUntilIdle()
        XCTAssertEqual(e.calls, ["t"])
        await p.request("s", intent: .speculative); await p.waitUntilIdle()
        await p.request("s", intent: .speculative); await p.waitUntilIdle()   // Wiederholung innerhalb 10 min: ignoriert
        XCTAssertEqual(e.calls, ["t", "s"])
        e.now += PlaybackPrefetcher.repeatIntervalMs
        await p.request("s", intent: .speculative); await p.waitUntilIdle()
        XCTAssertEqual(e.calls, ["t", "s", "s"])
        await p.stop()
    }

    func testLikelyOvertakesAndNewerReplacesOlder() async {
        let e = Env()
        var cont: AsyncStream<Void>.Continuation!
        e.gate["first"] = AsyncStream { cont = $0 }
        let p = make(e)
        await p.request("first", intent: .speculative)
        while e.l.withLock({ e.calls.isEmpty }) { try? await Task.sleep(nanoseconds: 2_000_000) }     // "first" läuft und hängt
        await p.request("s1", intent: .speculative); await p.request("s2", intent: .speculative); await p.request("s3", intent: .speculative)   // s1 wird verdrängt
        await p.request("l1", intent: .likely); await p.request("l2", intent: .likely)                 // l1 wird verdrängt
        cont.yield(); cont.finish()
        await p.waitUntilIdle()
        XCTAssertEqual(e.calls, ["first", "l2", "s2", "s3"])
        await p.stop()
    }
}
