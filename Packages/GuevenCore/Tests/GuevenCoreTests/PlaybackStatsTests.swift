import XCTest
@testable import GuevenCore

final class PlaybackStatsTests: XCTestCase {
    func testSummarisesSessions() throws {
        let sessions = [
            PlaybackSession(atMs: 1, route: "visionOS", startupMs: 800, rebuffers: 1, watchedMs: 1_800_000),
            PlaybackSession(atMs: 2, route: "visionOS", startupMs: 1_200, rebuffers: 0, watchedMs: 1_800_000),
            PlaybackSession(atMs: 3, route: "TV (Samsung) · mit Konto", startupMs: 2_000, watchedMs: 0),
            PlaybackSession(atMs: 4, error: "Video nicht verfügbar"),
        ]
        let s = PlaybackStatsSummary.of(sessions)
        XCTAssertEqual(s.sessions, 4)
        XCTAssertEqual(s.started, 3)
        XCTAssertEqual(try XCTUnwrap(s.successRate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(s.medianStartupMs, 1_200)
        XCTAssertEqual(s.p90StartupMs, 1_200)   // Index ((3-1)*0.9).toInt() = 1
        XCTAssertEqual(try XCTUnwrap(s.rebuffersPerHour), 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.topRoutes.first, .init(route: "visionOS", count: 2))
        XCTAssertEqual(s.recentErrors, ["Video nicht verfügbar"])
    }

    func testEmptyHasNoRates() {
        let s = PlaybackStatsSummary.of([])
        XCTAssertNil(s.successRate); XCTAssertNil(s.medianStartupMs); XCTAssertNil(s.p90StartupMs); XCTAssertNil(s.rebuffersPerHour)
    }

    func testTopRoutesTieKeepsFirstSeenOrderAndErrorsAreDistinctNewestFirst() {
        let sessions = [
            PlaybackSession(atMs: 1, route: "B", startupMs: 1), PlaybackSession(atMs: 2, route: "A", startupMs: 1),
            PlaybackSession(atMs: 3, error: "x"), PlaybackSession(atMs: 4, error: "y"), PlaybackSession(atMs: 5, error: "x"),
            PlaybackSession(atMs: 6, route: "C"),   // nie gestartet: zählt nicht als Weg
        ]
        let s = PlaybackStatsSummary.of(sessions)
        XCTAssertEqual(s.topRoutes.map(\.route), ["B", "A"])
        XCTAssertEqual(s.recentErrors, ["x", "y"])
    }

    func testStoreCapsPersistsAndSkipsBrokenLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("playback.jsonl")
        let store = PlaybackStatsStore(file: file)
        for i in 0..<(PlaybackStatsStore.maxSessions + 20) { await store.record(PlaybackSession(atMs: Int64(i), route: "r", startupMs: 10)) }
        let summary = await store.refresh()
        XCTAssertEqual(summary.sessions, PlaybackStatsStore.maxSessions)

        var raw = try Data(contentsOf: file)
        raw.append(Data("{kaputt\n".utf8))
        try raw.write(to: file)
        let reloaded = await PlaybackStatsStore(file: file).refresh()
        XCTAssertEqual(reloaded.sessions, PlaybackStatsStore.maxSessions)

        await store.clear()
        let cleared = await store.refresh()
        XCTAssertEqual(cleared.sessions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOlderFilesWithMissingFieldsStillLoad() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("playback.jsonl")
        try Data(#"{"atMs":5,"startupMs":300,"neuesFeld":1}"#.utf8 + [0x0A]).write(to: file)
        let s = await PlaybackStatsStore(file: file).refresh()
        XCTAssertEqual(s.sessions, 1)
        XCTAssertEqual(s.medianStartupMs, 300)
    }
}
