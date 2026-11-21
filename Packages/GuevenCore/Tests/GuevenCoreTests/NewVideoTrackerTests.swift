import XCTest
@testable import GuevenCore

final class NewVideoTrackerTests: XCTestCase {
    private func video(_ id: String, short: Bool = false) -> VideoItem {
        VideoItem(videoId: id, title: "T\(id)", channelName: "C", channelId: nil, thumbnailUrl: "", isShort: short)
    }

    func testFirstRunOnlyRemembersAndReportsNothing() {
        let t = NewVideoTracker(store: InMemoryStringStore())
        XCTAssertTrue(t.process([video("a"), video("b")]).isEmpty)
    }

    func testEmptyFirstFeedStillCountsAsFirstRun() {
        let t = NewVideoTracker(store: InMemoryStringStore())
        XCTAssertTrue(t.process([]).isEmpty)
        XCTAssertTrue(t.process([video("a"), video("b")]).isEmpty, "kein Meldungsschwall nach leerem Erst-Feed")
        XCTAssertEqual(t.process([video("c"), video("a")]).map(\.videoId), ["c"])
    }

    func testSecondRunReportsOnlyNewVideosNewestFirst() {
        let t = NewVideoTracker(store: InMemoryStringStore())
        _ = t.process([video("a"), video("b")])
        XCTAssertEqual(t.process([video("c"), video("d"), video("a"), video("b")]).map(\.videoId), ["c", "d"])
        XCTAssertTrue(t.process([video("c"), video("d"), video("a"), video("b")]).isEmpty, "bereits gemeldet")
    }

    func testCapsNotificationsAtThree() {
        let t = NewVideoTracker(store: InMemoryStringStore())
        _ = t.process([video("a")])
        XCTAssertEqual(t.process(["1", "2", "3", "4", "5", "a"].map { video($0) }).map(\.videoId), ["1", "2", "3"])
    }

    func testShortsAndDuplicatesAreIgnored() {
        let t = NewVideoTracker(store: InMemoryStringStore())
        _ = t.process([video("a")])
        XCTAssertEqual(t.process([video("s", short: true), video("n"), video("n"), video("a")]).map(\.videoId), ["n"])
    }

    func testNextSeenKeepsCurrentFeedFirstAndCaps() {
        XCTAssertEqual(NewVideoTracker.nextSeen(["a", "b"], ["x", "a", "y"], max: 10), ["a", "b", "x", "y"])
        XCTAssertEqual(NewVideoTracker.nextSeen(["a", "b", "c"], ["x"], max: 3), ["a", "b", "c"], "aktueller Feed wird nie verdrängt")
    }

    func testEmptyFeedOnFirstRunStillMarksInitialised() {
        let store = InMemoryStringStore(); let t = NewVideoTracker(store: store)
        _ = t.process([])
        XCTAssertEqual(store.string("newvideos.seen"), "")
        XCTAssertEqual(t.process([video("a")]).map(\.videoId), ["a"], "ab dem zweiten Lauf zählt alles Neue")
    }
}
