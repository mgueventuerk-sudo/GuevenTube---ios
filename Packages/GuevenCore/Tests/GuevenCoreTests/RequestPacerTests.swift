import XCTest
@testable import GuevenCore

final class RequestPacerTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t: Int64 = 1_000; var slept: [Int64] = [] }

    func testFirstImmediateThenSpaced() async {
        let c = Clock()
        let p = RequestPacer(minGapMs: 4_000, jitterMs: 0, nowMs: { c.t }, sleepMs: { c.slept.append($0); c.t += $0 }, random: { _ in 0 })
        await p.wait(); await p.wait(); await p.wait()
        XCTAssertEqual(c.slept, [4_000, 4_000])
    }

    func testNoWaitWhenEnoughTimePassed() async {
        let c = Clock()
        let p = RequestPacer(minGapMs: 4_000, jitterMs: 0, nowMs: { c.t }, sleepMs: { c.slept.append($0); c.t += $0 }, random: { _ in 0 })
        await p.wait(); c.t += 10_000; await p.wait()
        XCTAssertTrue(c.slept.isEmpty)
    }

    func testJitterAdded() async {
        let c = Clock()
        let p = RequestPacer(minGapMs: 1_000, jitterMs: 500, nowMs: { c.t }, sleepMs: { c.slept.append($0); c.t += $0 }, random: { $0 })
        await p.wait(); await p.wait()
        XCTAssertEqual(c.slept, [1_500])
    }
}
