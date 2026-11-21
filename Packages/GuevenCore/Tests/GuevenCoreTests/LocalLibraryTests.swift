import XCTest
@testable import GuevenCore

final class LibClock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Int64 = 1_000
    func tick() -> Int64 { lock.lock(); defer { lock.unlock() }; t += 10; return t }
}

final class LocalLibraryTests: XCTestCase {
    private func lib(_ file: URL? = nil) -> LocalLibrary { let c = LibClock(); return LocalLibrary(file: file, nowMs: { c.tick() }) }
    private func video(_ id: String) -> VideoItem {
        VideoItem(videoId: id, title: "T\(id)", channelName: "C", channelId: nil, thumbnailUrl: "u\(id)", durationSeconds: 60, viewCountText: nil, publishedText: nil, isLive: false)
    }

    func testContinueWatchingThresholds() async {
        let l = lib()
        await l.saveProgress(videoId: "short", positionMs: 10_000, durationMs: 600_000, title: nil, channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "ok", positionMs: 60_000, durationMs: 600_000, title: "Ok", channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "done", positionMs: 580_000, durationMs: 600_000, title: nil, channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "live", positionMs: 90_000, durationMs: 0, title: nil, channelName: nil, thumbnailUrl: nil)
        let items = await l.continueWatching()
        XCTAssertEqual(items.map(\.videoId), ["live", "ok"])
        XCTAssertEqual(items[0].title, "live")
        XCTAssertEqual(items[0].thumbnailUrl, "https://i.ytimg.com/vi/live/hqdefault.jpg")
        XCTAssertNil(items[0].durationSeconds)
        XCTAssertEqual(items[1].durationSeconds, 600)
    }

    func testResumeAndProgressMap() async {
        let l = lib()
        await l.saveProgress(videoId: "a", positionMs: 300_000, durationMs: 600_000, title: nil, channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "b", positionMs: 20_000, durationMs: 600_000, title: nil, channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "c", positionMs: 590_000, durationMs: 600_000, title: nil, channelName: nil, thumbnailUrl: nil)
        let r = await l.resumePositionMs("a"); XCTAssertEqual(r, 300_000)
        let rb = await l.resumePositionMs("b"); XCTAssertEqual(rb, 0)
        let rc = await l.resumePositionMs("c"); XCTAssertEqual(rc, 0)
        let rx = await l.resumePositionMs("none"); XCTAssertEqual(rx, 0)
        let m = await l.progressMap()
        XCTAssertEqual(m["a"], 0.5); XCTAssertNil(m["b"]); XCTAssertNotNil(m["c"])
    }

    func testNegativeClampedAndUpsert() async {
        let l = lib()
        await l.saveProgress(videoId: "a", positionMs: -5, durationMs: -1, title: nil, channelName: nil, thumbnailUrl: nil)
        await l.saveProgress(videoId: "a", positionMs: 40_000, durationMs: 100_000, title: nil, channelName: nil, thumbnailUrl: nil)
        let e = await l.recentProgress(limit: 10)
        XCTAssertEqual(e.count, 1); XCTAssertEqual(e[0].positionMs, 40_000)
    }

    func testPruneKeepsNewest500() async {
        let l = lib()
        for i in 0..<600 { await l.saveProgress(videoId: "v\(i)", positionMs: 1, durationMs: 1, title: nil, channelName: nil, thumbnailUrl: nil) }
        let all = await l.recentProgress(limit: 1000)
        XCTAssertLessThanOrEqual(all.count, 550)
        XCTAssertEqual(all.first?.videoId, "v599")
        XCTAssertTrue(all.contains { $0.videoId == "v599" })
    }

    func testMergeOnlyNewer() async {
        let l = lib()
        await l.saveProgress(videoId: "a", positionMs: 50_000, durationMs: 100_000, title: nil, channelName: nil, thumbnailUrl: nil)
        let own = await l.recentProgress(limit: 1)[0]
        let n = await l.mergeProgress([
            WatchProgressEntry(videoId: "a", positionMs: 1, durationMs: 1, updatedAt: own.updatedAt - 1),
            WatchProgressEntry(videoId: "b", positionMs: -9, durationMs: 100, updatedAt: 5),
            WatchProgressEntry(videoId: "a", positionMs: 70_000, durationMs: 100_000, updatedAt: own.updatedAt + 1)])
        XCTAssertEqual(n, 2)
        let r = await l.resumePositionMs("a"); XCTAssertEqual(r, 70_000)
        let all = await l.recentProgress(limit: 10)
        XCTAssertEqual(all.first { $0.videoId == "b" }?.positionMs, 0)
    }

    func testWatchLaterIdempotentAndRemove() async {
        let l = lib()
        let a = await l.isInWatchLater("x"); XCTAssertFalse(a)
        await l.addToWatchLater(video("x")); await l.addToWatchLater(video("x")); await l.addToWatchLater(video("y"))
        let items = await l.watchLaterItems()
        XCTAssertEqual(items.map(\.videoId), ["y", "x"])
        let b = await l.isInWatchLater("x"); XCTAssertTrue(b)
        await l.removeFromWatchLater("x")
        let c = await l.isInWatchLater("x"); XCTAssertFalse(c)
        let p = await l.playlists(); XCTAssertEqual(p.count, 1); XCTAssertEqual(p[0].itemCount, 1)
    }

    func testPlaylistsUniqueNameCascadeOrder() async throws {
        let l = lib()
        let a = await l.playlistId(named: "A"); let b = await l.playlistId(named: "B")
        let a2 = await l.playlistId(named: "A"); XCTAssertEqual(a, a2)
        do { try await l.renamePlaylist(b, to: "A"); XCTFail() } catch { XCTAssertEqual(error as? DuplicatePlaylistName, DuplicatePlaylistName()) }
        try await l.renamePlaylist(b, to: "B2")
        try await l.renamePlaylist(b, to: "B2")
        await l.add(video("1"), to: a)
        let order = await l.playlists().map(\.name); XCTAssertEqual(order, ["A", "B2"])
        await l.deletePlaylist(a)
        let rest = await l.playlists().map(\.name); XCTAssertEqual(rest, ["B2"])
        let items = await l.items(in: a); XCTAssertTrue(items.isEmpty)
    }

    func testSubscriptions() async {
        let l = lib()
        await l.subscribe(channelId: "1", name: "zeta", avatarUrl: nil)
        await l.subscribe(channelId: "2", name: "Alpha", avatarUrl: nil)
        await l.subscribe(channelId: "1", name: "beta", avatarUrl: "a")
        let s = await l.subscriptions().map(\.name); XCTAssertEqual(s, ["Alpha", "beta"])
        let ids = await l.subscribedChannelIds(); XCTAssertEqual(ids, ["1", "2"])
        await l.unsubscribe("1")
        let i = await l.isSubscribed("1"); XCTAssertFalse(i)
    }

    func testSearchHistory() async {
        let l = lib()
        await l.addSearch("  "); await l.addSearch(" a "); await l.addSearch("b"); await l.addSearch("a")
        let r = await l.recentSearches(); XCTAssertEqual(r, ["a", "b"])
        for i in 0..<40 { await l.addSearch("q\(i)") }
        let all = await l.recentSearches(limit: 100)
        XCTAssertEqual(all.count, 30); XCTAssertEqual(all.first, "q39")
        let lim = await l.recentSearches(limit: 12); XCTAssertEqual(lim.count, 12)
        await l.clearSearches()
        let e = await l.recentSearches(); XCTAssertTrue(e.isEmpty)
    }

    func testPersistenceAndCorruption() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ll\(UUID().uuidString)")
        let f = dir.appendingPathComponent("lib.json")
        let l = lib(f)
        await l.addToWatchLater(video("x")); await l.addSearch("hi")
        let l2 = lib(f)
        let w = await l2.watchLaterItems().map(\.videoId); XCTAssertEqual(w, ["x"])
        let s = await l2.recentSearches(); XCTAssertEqual(s, ["hi"])
        try Data("{kaputt".utf8).write(to: f)
        let l3 = lib(f)
        let e = await l3.recentSearches(); XCTAssertTrue(e.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    func testUpdatesStreamFires() async {
        let l = lib()
        let stream = await l.updates()
        await l.addSearch("x")
        var it = stream.makeAsyncIterator()
        let v: Void? = await it.next()
        XCTAssertNotNil(v)
    }

    func testMergeClampsAbsurdValuesFromPairedDevice() async {
        let lib = LocalLibrary()
        await lib.mergeProgress([WatchProgressEntry(videoId: "v", positionMs: Int64.max, durationMs: Int64.max, updatedAt: 1)])
        let items = await lib.continueWatching() // darf nicht abstürzen
        XCTAssertTrue(items.isEmpty || items.count == 1)
    }
}
