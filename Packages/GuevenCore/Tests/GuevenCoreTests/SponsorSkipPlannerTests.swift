import XCTest
@testable import GuevenCore

final class SponsorSkipPlannerTests: XCTestCase {
    private let sponsor = SponsorSegment(uuid: "a", category: .sponsor, startMs: 10_000, endMs: 20_000)
    private let promo = SponsorSegment(uuid: "b", category: .selfpromo, startMs: 40_000, endMs: 50_000)

    private func planner(_ segs: [SponsorSegment], enabled: Bool = true,
                         modes: [SponsorCategory: SkipMode] = [.sponsor: .autoSkip, .selfpromo: .manualSkip]) -> SponsorSkipPlanner {
        SponsorSkipPlanner(segments: segs, enabled: enabled, mode: { modes[$0] ?? .disabled })
    }

    func testAutoSkipJumpsOnEntryOnceOnly() {
        var p = planner([sponsor])
        XCTAssertEqual(p.update(positionMs: 9_500), .none)
        XCTAssertEqual(p.update(positionMs: 10_100), .seek(toMs: 20_000, segment: sponsor))
        // Nächste Meldung noch im Segment (Sprung noch nicht angekommen): kein zweiter Sprung.
        XCTAssertEqual(p.update(positionMs: 10_300), .none)
        XCTAssertEqual(p.update(positionMs: 20_100), .none)
    }

    func testStartInsideSegmentSkipsButUserSeekOnlyOffersButton() {
        var p = planner([sponsor])
        XCTAssertEqual(p.update(positionMs: 12_000), .seek(toMs: 20_000, segment: sponsor)) // Fortsetzen mitten im Segment
        var q = planner([sponsor])
        XCTAssertEqual(q.update(positionMs: 1_000), .none)
        XCTAssertEqual(q.update(positionMs: 15_000), .showPrompt(sponsor)) // Sprung des Nutzers
        XCTAssertEqual(q.skipPrompted(), 20_000)
    }

    func testManualPromptHidesAfterFiveSecondsAndStaysHidden() {
        var p = planner([promo])
        XCTAssertEqual(p.update(positionMs: 39_900), .none)
        XCTAssertEqual(p.update(positionMs: 40_100), .showPrompt(promo))
        XCTAssertEqual(p.update(positionMs: 42_000), .none)
        XCTAssertEqual(p.update(positionMs: 45_200), .hidePrompt)
        XCTAssertEqual(p.update(positionMs: 46_000), .none) // nicht erneut im selben Segment
        XCTAssertNil(p.skipPrompted())
    }

    func testPromptHidesWhenLeavingAndReentryShowsAgain() {
        var p = planner([promo])
        _ = p.update(positionMs: 40_500)
        XCTAssertEqual(p.update(positionMs: 51_000), .hidePrompt)
        XCTAssertEqual(p.update(positionMs: 39_000), .none)
        XCTAssertEqual(p.update(positionMs: 41_000), .showPrompt(promo)) // zurückgespult
    }

    func testPromptEndsAtSegmentEndIfShorterThanFiveSeconds() {
        let short = SponsorSegment(uuid: "s", category: .selfpromo, startMs: 1_000, endMs: 3_000)
        var p = planner([short])
        XCTAssertEqual(p.update(positionMs: 1_100), .showPrompt(short))
        XCTAssertEqual(p.update(positionMs: 3_100), .hidePrompt) // außerhalb (Ende minus Toleranz)
    }

    func testDisabledAndSeekbarOnlyAndOffDoNothing() {
        var off = planner([sponsor], enabled: false)
        XCTAssertEqual(off.update(positionMs: 12_000), .none)
        var bar = planner([sponsor], modes: [.sponsor: .showInSeekbar])
        XCTAssertEqual(bar.update(positionMs: 12_000), .none)
    }

    func testDisablingWhilePromptShownHidesIt() {
        var p = planner([promo])
        _ = p.update(positionMs: 41_000)
        XCTAssertEqual(p.activePrompt, promo)
        var off = SponsorSkipPlanner(segments: [promo], enabled: false, mode: { _ in .manualSkip })
        XCTAssertEqual(off.update(positionMs: 41_000), .none)
    }

    func testToleranceAtSegmentEndNoSkip() {
        var p = planner([sponsor])
        XCTAssertEqual(p.update(positionMs: 19_800), .none) // weniger als 250 ms bis zum Ende
    }

    func testUnsortedSegmentsAndTwoSegments() {
        var p = planner([promo, sponsor])
        XCTAssertEqual(p.update(positionMs: 10_050), .seek(toMs: 20_000, segment: sponsor))
        XCTAssertEqual(p.update(positionMs: 20_500), .none)
        XCTAssertEqual(p.update(positionMs: 40_050), .showPrompt(promo))
    }
}
