import XCTest
@testable import GuevenCore

final class WatchTogetherTests: XCTestCase {
    private func tv(_ id: String? = "v", pos: Int64 = 10_000, playing: Bool = true, buffering: Bool = false, live: Bool = false) -> LinkPlayerState {
        var s = LinkPlayerState(); s.videoId = id; s.positionMs = pos; s.isPlaying = playing; s.isBuffering = buffering; s.isLive = live; return s
    }
    func testNothingWithoutTvVideo() { XCTAssertEqual(WatchTogether.plan(tv: tv(nil), localVideoId: "v", localPositionMs: 0, localPlaying: false), []) }
    func testOpenOtherVideoWithLatency() {
        XCTAssertEqual(WatchTogether.plan(tv: tv("x"), localVideoId: "v", localPositionMs: 0, localPlaying: true), [.open(videoId: "x", positionMs: 10_600)])
        XCTAssertEqual(WatchTogether.plan(tv: tv("x", playing: false), localVideoId: nil, localPositionMs: 0, localPlaying: false), [.open(videoId: "x", positionMs: 10_000)])
    }
    func testLiveOnlyOpens() {
        XCTAssertEqual(WatchTogether.plan(tv: tv("x", live: true), localVideoId: "v", localPositionMs: 0, localPlaying: true), [.open(videoId: "x", positionMs: 0)])
        XCTAssertEqual(WatchTogether.plan(tv: tv("x", live: true), localVideoId: "x", localPositionMs: 99, localPlaying: false), [])
    }
    func testSeekOnlyBeyondTolerance() {
        XCTAssertEqual(WatchTogether.plan(tv: tv(), localVideoId: "v", localPositionMs: 12_600, localPlaying: true), [])           // genau 2000 → noch ok
        XCTAssertEqual(WatchTogether.plan(tv: tv(), localVideoId: "v", localPositionMs: 12_601, localPlaying: true), [.seekTo(positionMs: 10_600)])
        XCTAssertEqual(WatchTogether.plan(tv: tv(), localVideoId: "v", localPositionMs: 8_599, localPlaying: true), [.seekTo(positionMs: 10_600)])
    }
    func testPlayStateAndBuffering() {
        XCTAssertEqual(WatchTogether.plan(tv: tv(playing: false), localVideoId: "v", localPositionMs: 10_000, localPlaying: true), [.setPlaying(false)])
        XCTAssertEqual(WatchTogether.plan(tv: tv(pos: 50_000, playing: false), localVideoId: "v", localPositionMs: 0, localPlaying: true), [.seekTo(positionMs: 50_000), .setPlaying(false)])
        XCTAssertEqual(WatchTogether.plan(tv: tv(pos: 50_000, buffering: true), localVideoId: "v", localPositionMs: 0, localPlaying: false), [], "während der TV puffert: nichts tun")
    }
}

final class PlaybackSelfTestTests: XCTestCase {
    private func playback(url: String? = "https://v/x", unsolved: Bool = false) -> ResolvedPlayback {
        var f = StreamFormat(itag: 1, url: url, signatureCipher: nil, mimeType: "video/mp4", bitrate: 1, averageBitrate: nil, width: nil, height: 1, fps: nil, qualityLabel: nil,
                             initRange: nil, indexRange: nil, contentLength: nil, approxDurationMs: nil, audioSampleRate: nil, audioChannels: nil, audioTrackId: nil, audioTrackName: nil,
                             audioIsDefault: false, isDrc: false, colorPrimaries: nil, colorTransfer: nil, colorMatrix: nil, isOtf: false, lastModified: nil, xtags: nil)
        f.url = url
        let d = PlayerData(playability: Playability(status: "OK", reason: nil), details: nil, adaptiveFormats: [f], muxedFormats: [], hlsManifestUrl: nil, expiresInSeconds: nil,
                           captions: [], loudnessDb: nil, storyboardSpec: nil, serverAbrStreamingUrl: nil, ustreamerConfig: nil)
        var r = ResolvedPlayback(videoId: "v", playerData: d, adaptiveFormats: [f], muxedFormats: [], resolvedAtMs: 0, expiresAtMs: 1, clientLabel: "visionOS", userAgent: "UA", attempts: [])
        r.throttlingUnsolved = unsolved; return r
    }
    private func test(_ t: FakeTransport, store: StringValueStore = InMemoryStringStore(), now: @escaping @Sendable () -> Int64 = { 5_000 },
                      resolve: @escaping @Sendable (String) async throws -> ResolvedPlayback) -> PlaybackSelfTest {
        PlaybackSelfTest(resolve: resolve, transport: t, store: store, nowMs: now)
    }

    func testSuccessProbesWithRangeAndUserAgent() async {
        let p = playback(); let t = FakeTransport([.response(HTTPResponse(code: 206))])
        let st = test(t) { _ in p }
        let r = await st.run()
        XCTAssertTrue(r.ok); XCTAssertEqual(r.route, "visionOS"); XCTAssertEqual(r.detail, "Videoserver antwortet (HTTP 206)"); XCTAssertEqual(r.atMs, 5_000)
        XCTAssertEqual(t.requests.first?.headers["Range"], "bytes=0-1023"); XCTAssertEqual(t.requests.first?.headers["User-Agent"], "UA")
        let running = await st.isRunning(); XCTAssertFalse(running)
    }

    func testThrottledNoteRejectedAndNoFormats() async {
        let thr = playback(unsolved: true)
        let a = await test(FakeTransport([.response(HTTPResponse(code: 200))])) { _ in thr }.run(); XCTAssertEqual(a.detail, "Videoserver antwortet (HTTP 200) – gedrosselt")
        let b = await test(FakeTransport([.response(HTTPResponse(code: 403))])) { _ in thr }.run(); XCTAssertFalse(b.ok); XCTAssertEqual(b.detail, "Videoserver lehnt ab (HTTP 403)")
        let none = playback(url: " ")
        let c = await test(FakeTransport([])) { _ in none }.run(); XCTAssertFalse(c.ok); XCTAssertEqual(c.detail, "Keine abspielbaren Formate"); XCTAssertEqual(c.route, "visionOS")
    }

    func testErrorsBecomeResults() async {
        struct E: Error {}
        let net = await test(FakeTransport([])) { _ in throw E() }.run(); XCTAssertEqual(net.detail, "Netzwerkfehler (E)"); XCTAssertNil(net.route)
        let warn = await test(FakeTransport([])) { _ in throw PlaybackUnavailableError(status: "X", message: "Anmelden", kinds: [.botCheck, .technical, .sabrOnly]) }.run()
        XCTAssertEqual(warn.detail, "Frühwarnung (sabr+bot): Anmelden")
        let plain = await test(FakeTransport([])) { _ in throw PlaybackUnavailableError(status: "X", message: "", kinds: [.technical]) }.run(); XCTAssertEqual(plain.detail, "Kein Abspielweg")
        let long = await test(FakeTransport([])) { _ in throw PlaybackUnavailableError(status: "X", message: String(repeating: "x", count: 300)) }.run(); XCTAssertEqual(long.detail.count, 160)
    }

    func testDueLogicAndPersistence() async {
        final class T: @unchecked Sendable { var now: Int64 = 100_000_000 }
        let clock = T(); let store = InMemoryStringStore(); let p = playback()
        let first = test(FakeTransport([.response(HTTPResponse(code: 200))]), store: store, now: { clock.now }) { _ in p }
        let due0 = await first.isDue(); XCTAssertTrue(due0)
        await first.run()
        let due1 = await first.isDue(); XCTAssertFalse(due1)
        let reloaded = test(FakeTransport([]), store: store, now: { clock.now }) { _ in p }
        let last = await reloaded.lastResult(); XCTAssertEqual(last?.route, "visionOS")
        clock.now += PlaybackSelfTest.intervalMs - 1; let a = await reloaded.isDue(); XCTAssertFalse(a)
        clock.now += 1; let b = await reloaded.isDue(); XCTAssertTrue(b)
    }

    func testConcurrentRunsAreSerialized() async {
        final class Counter: @unchecked Sendable { let l = NSLock(); var active = 0; var maxActive = 0
            func enter() { l.withLock { active += 1; maxActive = max(maxActive, active) } }; func leave() { l.withLock { active -= 1 } } }
        let c = Counter(); let p = playback()
        let st = test(FakeTransport([.response(HTTPResponse(code: 200)), .response(HTTPResponse(code: 200)), .response(HTTPResponse(code: 200))])) { _ in
            c.enter(); try await Task.sleep(nanoseconds: 20_000_000); c.leave(); return p }
        await withTaskGroup(of: Void.self) { g in for _ in 0..<3 { g.addTask { await st.run() } } }
        XCTAssertEqual(c.maxActive, 1)
    }
}
