import XCTest
@testable import GuevenCore

final class MusicQueueTests: XCTestCase {
    private func song(_ id: String) -> MusicSong { MusicSong(videoId: id, title: "Titel \(id)", artists: "Interpret", album: nil, thumbnailUrl: nil, durationSeconds: nil) }
    private func songs(_ ids: String...) -> [MusicSong] { ids.map(song) }
    private var rng = AnyRandom(seed: 42)

    // MARK: Radio-Nachschub (Port von MusicRadioRefillTest)

    private let answer = (1...5).map { MusicSong(videoId: "v\($0)", title: "T", artists: nil, album: nil, thumbnailUrl: nil, durationSeconds: nil) }

    func testUnplayedPreferred() {
        XCTAssertEqual(MusicQueueState.pickRefill(answer, queued: ["v1"], played: ["v2"]).map(\.videoId), ["v3", "v4", "v5"])
    }
    func testRunningAndQueuedNeverTwice() {
        XCTAssertEqual(MusicQueueState.pickRefill(answer, queued: ["v1", "v2", "v3"], played: []).map(\.videoId), ["v4", "v5"])
    }
    func testRadioContinuesWithPlayedAfterOneRound() {
        let played = Set(answer.map(\.videoId))
        XCTAssertEqual(MusicQueueState.pickRefill(answer, queued: [], played: played).map(\.videoId), ["v1", "v2", "v3", "v4", "v5"])
    }
    func testEverythingQueuedGivesNothing() {
        XCTAssertTrue(MusicQueueState.pickRefill(answer, queued: Set(answer.map(\.videoId)), played: []).isEmpty)
        XCTAssertTrue(MusicQueueState.pickRefill([], queued: [], played: []).isEmpty)
    }
    func testLimit() {
        let many = (1...40).map { song("w\($0)") }
        XCTAssertEqual(MusicQueueState.pickRefill(many, queued: [], played: []).count, MusicQueueState.radioBatch)
        XCTAssertEqual(MusicQueueState.pickRefill(many, queued: [], played: [], limit: 2).count, 2)
    }

    // MARK: Abspielen und Weiterschalten

    func testPlayStartsAtIndexAndQueuesRestWithoutDuplicates() {
        var q = MusicQueueState()
        let e = q.play(songs("a", "b", "c", "c", "d"), index: 1, radio: false, using: &rng)
        XCTAssertEqual(e.play?.videoId, "b")
        XCTAssertEqual(q.upcoming.map(\.videoId), ["c", "d"])
        XCTAssertNil(e.refillSeed)
    }

    func testIndexIsClamped() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b"), index: 99, radio: false, using: &rng)
        XCTAssertEqual(q.current?.videoId, "b")
    }

    func testSingleSongDefaultsToRadioAndAsksForRefill() {
        var q = MusicQueueState()
        let e = q.play([song("a")], using: &rng)
        XCTAssertEqual(q.radioSeed, "a")
        XCTAssertEqual(e.refillSeed, "a")
        XCTAssertFalse(e.refillStartsPlayback)
    }

    func testNextAdvancesAndRecordsHistory() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), radio: false, using: &rng)
        let e = q.next(using: &rng)
        XCTAssertEqual(e.play?.videoId, "b")
        XCTAssertEqual(q.history.map(\.videoId), ["a"])
        XCTAssertEqual(q.upcoming.map(\.videoId), ["c"])
    }

    func testNextAtEndWithoutRadioOrRepeatEnds() {
        var q = MusicQueueState()
        _ = q.play(songs("a"), radio: false, using: &rng)
        XCTAssertFalse(q.next(using: &rng).handled)
    }

    func testNextWithEmptyQueueAndRadioWaitsForRefill() {
        var q = MusicQueueState()
        _ = q.play(songs("a"), radio: true, using: &rng)
        let e = q.next(using: &rng)
        XCTAssertTrue(e.handled)
        XCTAssertEqual(e.refillSeed, "a")
        XCTAssertTrue(e.refillStartsPlayback)
        XCTAssertNil(e.play)
    }

    func testRepeatAllRestartsListInOriginalOrder() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), radio: false, using: &rng)
        q.setRepeat(.all)
        _ = q.next(using: &rng); _ = q.next(using: &rng)
        XCTAssertEqual(q.current?.videoId, "c")
        let e = q.next(using: &rng)
        XCTAssertEqual(e.play?.videoId, "a")
        XCTAssertEqual(q.upcoming.map(\.videoId), ["b", "c"])
        XCTAssertTrue(q.history.isEmpty)
    }

    func testRepeatOneRestartsCurrentOnEnd() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b"), radio: false, using: &rng)
        q.setRepeat(.one)
        let e = q.trackEnded(using: &rng)
        XCTAssertTrue(e.restartCurrent)
        XCTAssertEqual(q.current?.videoId, "a")
        XCTAssertEqual(q.upcoming.count, 1)
    }

    func testRepeatCycle() {
        var q = MusicQueueState()
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .all)
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .one)
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .off)
    }

    func testPreviousRestartsAfterThreeSecondsElseGoesBack() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), radio: false, using: &rng)
        _ = q.next(using: &rng)
        var e = q.previous(positionMs: 3_001)
        XCTAssertTrue(e.restartCurrent)
        XCTAssertEqual(q.history.map(\.videoId), ["a"], "Verlauf bleibt beim Zurückspulen erhalten")
        e = q.previous(positionMs: 500)
        XCTAssertEqual(e.play?.videoId, "a")
        XCTAssertEqual(q.upcoming.map(\.videoId), ["b", "c"], "laufender Titel kommt wieder vorn in die Warteschlange")
    }

    func testPreviousWithoutHistoryRestartsCurrent() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b"), radio: false, using: &rng)
        XCTAssertTrue(q.previous(positionMs: 0).restartCurrent)
    }

    // MARK: Bearbeiten

    func testPlayNextInsertsFrontAndDedupes() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), radio: false, using: &rng)
        _ = q.playNext(song("c"), using: &rng)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["c", "b"])
    }

    func testPlayNextWithoutCurrentStartsIt() {
        var q = MusicQueueState()
        XCTAssertEqual(q.playNext(song("x"), using: &rng).play?.videoId, "x")
    }

    func testJumpToMovesSkippedIntoHistory() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c", "d"), radio: false, using: &rng)
        let e = q.jumpTo(1)
        XCTAssertEqual(e.play?.videoId, "c")
        XCTAssertEqual(q.history.map(\.videoId), ["a", "b"])
        XCTAssertEqual(q.upcoming.map(\.videoId), ["d"])
        XCTAssertFalse(q.jumpTo(5).handled)
    }

    func testRemoveAndMove() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c", "d"), radio: false, using: &rng)
        q.remove(at: 0)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["c", "d"])
        q.move(from: 1, to: 0)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["d", "c"])
        q.move(from: 0, to: 9); q.remove(at: 9)
        XCTAssertEqual(q.upcoming.count, 2)
    }

    func testShuffleToggleRestoresOriginalOrderForRemaining() {
        var q = MusicQueueState()
        let ids = (1...12).map { "s\($0)" }
        _ = q.play(ids.map(song), radio: false, using: &rng)
        q.toggleShuffle(using: &rng)
        XCTAssertTrue(q.shuffle)
        XCTAssertEqual(Set(q.upcoming.map(\.videoId)), Set(ids.dropFirst()))
        _ = q.next(using: &rng)   // ein gemischter Titel läuft jetzt, fehlt in der ursprünglichen Reihenfolge
        q.toggleShuffle(using: &rng)
        XCTAssertFalse(q.shuffle)
        let expected = ids.dropFirst().filter { $0 != q.current?.videoId }
        XCTAssertEqual(q.upcoming.map(\.videoId), Array(expected))
    }

    func testPlayWithShuffleKeepsAllTracks() {
        var q = MusicQueueState()
        let ids = (1...10).map { "m\($0)" }
        _ = q.play(ids.map(song), radio: false, shuffle: true, using: &rng)
        XCTAssertTrue(q.shuffle)
        XCTAssertEqual(Set(q.upcoming.map(\.videoId) + [q.current!.videoId]), Set(ids))
    }

    func testQueueIsCapped() {
        var q = MusicQueueState()
        _ = q.play((1...300).map { song("c\($0)") }, radio: false, using: &rng)
        XCTAssertEqual(q.upcoming.count, MusicQueueState.maxQueue)
    }

    func testHistoryIsCapped() {
        var q = MusicQueueState()
        _ = q.play((1...80).map { song("h\($0)") }, radio: false, using: &rng)
        for _ in 0..<70 { _ = q.next(using: &rng) }
        XCTAssertEqual(q.history.count, MusicQueueState.maxHistory)
        XCTAssertEqual(q.history.last?.videoId, "h70")
    }

    func testStopClearsEverything() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b"), radio: true, using: &rng)
        q.stop()
        XCTAssertNil(q.current); XCTAssertTrue(q.upcoming.isEmpty); XCTAssertNil(q.radioSeed)
    }

    // MARK: Radio-Antwort einarbeiten

    func testApplyRadioAppendsFreshAndStartsWhenWaiting() {
        var q = MusicQueueState()
        _ = q.play(songs("a"), radio: true, using: &rng)
        _ = q.next(using: &rng)
        let (e, failed) = q.applyRadio(songs("a", "r1", "r2"), startWhenLoaded: true, using: &rng)
        XCTAssertFalse(failed)
        XCTAssertEqual(e.play?.videoId, "r1")
        XCTAssertEqual(q.upcoming.map(\.videoId), ["r2"])
    }

    func testApplyRadioWithNothingPlayableFailsWhenPlayerWaits() {
        var q = MusicQueueState()
        _ = q.play(songs("a"), radio: true, using: &rng)
        let (e, failed) = q.applyRadio(songs("a"), startWhenLoaded: true, using: &rng)
        XCTAssertTrue(failed)
        XCTAssertNil(e.play)
    }

    func testApplyRadioAfterStopIsIgnored() {
        var q = MusicQueueState()
        _ = q.play(songs("a"), radio: true, using: &rng)
        q.stop()
        let (e, failed) = q.applyRadio(songs("r1"), startWhenLoaded: false, using: &rng)
        XCTAssertFalse(e.handled); XCTAssertFalse(failed); XCTAssertTrue(q.upcoming.isEmpty)
    }

    func testRefillRequestedWhenQueueRunsLow() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c", "d", "e"), radio: true, using: &rng)
        XCTAssertNil(q.next(using: &rng).refillSeed)   // 3 übrig
        XCTAssertEqual(q.next(using: &rng).refillSeed, "c")   // 2 < 3
    }

    // MARK: Ans Ende einreihen

    func testEnqueueAppendsAndMovesDuplicateToEnd() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), index: 0, radio: false, using: &rng)
        _ = q.enqueue(song("x"), using: &rng)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["b", "c", "x"])
        _ = q.enqueue(song("b"), using: &rng)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["c", "x", "b"])
    }

    func testEnqueueIgnoresRunningSongAndStartsWhenIdle() {
        var q = MusicQueueState()
        let e = q.enqueue(song("a"), using: &rng)
        XCTAssertEqual(e.play?.videoId, "a")
        _ = q.enqueue(song("a"), using: &rng)
        XCTAssertTrue(q.upcoming.isEmpty)
    }

    func testEnqueueKeepsOrderWhenShuffleIsSwitchedOff() {
        var q = MusicQueueState()
        _ = q.play(songs("a", "b", "c"), index: 0, radio: false, using: &rng)
        q.toggleShuffle(using: &rng)
        _ = q.enqueue(song("x"), using: &rng)
        q.toggleShuffle(using: &rng)
        XCTAssertEqual(q.upcoming.map(\.videoId), ["b", "c", "x"])
    }
}

final class MusicSessionStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("music_session.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ savedAt: Int64, queue: String = "[]") throws {
        try Data(#"{"current":{"videoId":"v1","title":"Titel","artists":"Interpret"},"queue":\#(queue),"repeat":"ALL","radio":true,"savedAtMs":\#(savedAt)}"#.utf8).write(to: file)
    }
    private let now: Int64 = 1_800_000_000_000
    private func store() -> MusicSessionStore { MusicSessionStore(fileURL: file, nowMs: { [now] in now }) }

    func testFreshSessionIsRead() throws {
        try write(now, queue: #"[{"videoId":"v2","title":"Zweiter"}]"#)
        let saved = try XCTUnwrap(store().load())
        XCTAssertEqual(saved.current.videoId, "v1")
        XCTAssertEqual(saved.repeatMode, "ALL")
        XCTAssertTrue(saved.radio)
        XCTAssertEqual(saved.queue.map(\.videoId), ["v2"])
        XCTAssertEqual(saved.current.toSong().artists, "Interpret")
    }
    func testOlderThanSevenDaysNotOffered() throws {
        try write(now - 8 * 24 * 60 * 60 * 1000)
        XCTAssertNil(store().load())
    }
    func testJustUnderSevenDaysStillOffered() throws {
        try write(now - (7 * 24 * 60 * 60 * 1000 - 60_000))
        XCTAssertEqual(store().load()?.current.videoId, "v1")
    }
    func testCorruptOrMissingFileGivesNil() throws {
        XCTAssertNil(store().load())
        try Data("{kein json".utf8).write(to: file)
        XCTAssertNil(store().load())
    }
    func testUnknownFieldsIgnoredAndDefaultsApplied() throws {
        try Data(#"{"current":{"videoId":"v1","title":"Titel","kuenftigesFeld":1},"queue":[],"savedAtMs":\#(now),"nochEinFeld":"x"}"#.utf8).write(to: file)
        XCTAssertEqual(store().load()?.current.videoId, "v1")
        XCTAssertEqual(store().load()?.repeatMode, "OFF")
    }
    func testSaveRoundTripCapsQueueAndClearRemovesFile() throws {
        let queue = (1...150).map { MusicSong(videoId: "q\($0)", title: "T", artists: nil, album: nil, thumbnailUrl: nil, durationSeconds: nil) }
        let s = store()
        try s.save(current: queue[0], queue: queue, repeatMode: .one, radio: true)
        let loaded = try XCTUnwrap(s.load())
        XCTAssertEqual(loaded.queue.count, MusicSessionStore.maxSaved)
        XCTAssertEqual(loaded.repeatMode, "ONE")
        s.clear()
        XCTAssertNil(s.load())
    }
}
