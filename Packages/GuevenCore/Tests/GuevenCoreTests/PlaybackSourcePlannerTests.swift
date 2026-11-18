import XCTest
@testable import GuevenCore

final class PlaybackSourcePlannerTests: XCTestCase {
    private func fmt(_ itag: Int, _ mime: String, h: Int? = nil, br: Int64 = 100, url: String? = nil) -> StreamFormat {
        StreamFormat(itag: itag, url: url ?? "https://x/\(itag)", signatureCipher: nil, mimeType: mime, bitrate: br, averageBitrate: nil, width: nil, height: h, fps: nil,
                     qualityLabel: h.map { "\($0)p" }, initRange: nil, indexRange: nil, contentLength: nil, approxDurationMs: nil, audioSampleRate: nil,
                     audioChannels: nil, audioTrackId: nil, audioTrackName: nil, audioIsDefault: false, isDrc: false, colorPrimaries: nil,
                     colorTransfer: nil, colorMatrix: nil, isOtf: false, lastModified: nil, xtags: nil)
    }
    private func v(_ itag: Int, _ h: Int) -> StreamFormat { fmt(itag, "video/mp4; codecs=\"avc1.640028\"", h: h) }
    private func vp9(_ itag: Int, _ h: Int) -> StreamFormat { fmt(itag, "video/webm; codecs=\"vp9\"", h: h) }
    private func aac(_ itag: Int, _ br: Int64) -> StreamFormat { fmt(itag, "audio/mp4; codecs=\"mp4a.40.2\"", br: br) }
    private func opus(_ itag: Int, _ br: Int64) -> StreamFormat { fmt(itag, "audio/webm; codecs=\"opus\"", br: br) }
    private func playback(adaptive: [StreamFormat] = [], muxed: [StreamFormat] = [], hls: String? = nil, live: Bool = false, throttled: Bool = false) -> ResolvedPlayback {
        let details = VideoDetails(videoId: "v", title: "T", author: "A", channelId: nil, lengthSeconds: 10, viewCount: nil, shortDescription: "", isLive: live, thumbnailUrl: "")
        let d = PlayerData(playability: Playability(status: "OK", reason: nil), details: details, adaptiveFormats: adaptive, muxedFormats: muxed, hlsManifestUrl: hls,
                           expiresInSeconds: nil, captions: [], loudnessDb: nil, storyboardSpec: nil, serverAbrStreamingUrl: nil, ustreamerConfig: nil)
        var p = ResolvedPlayback(videoId: "v", playerData: d, adaptiveFormats: adaptive, muxedFormats: muxed, resolvedAtMs: 0, expiresAtMs: 1, clientLabel: "t", userAgent: "UA/1", attempts: [])
        p.throttlingUnsolved = throttled
        return p
    }

    func testHigherAdaptiveBeatsMuxedAndUsesBestAac() throws {
        let plan = try PlaybackSourcePlanner.plan(playback(adaptive: [v(1, 720), v(2, 1080), vp9(3, 2160), aac(8, 48), aac(9, 128), opus(10, 160)], muxed: [v(18, 360)]))
        XCTAssertEqual(plan.source, .separate(videoUrl: "https://x/2", audioUrl: "https://x/9", height: 1080), "VP9/Opus werden nie gewählt")
        XCTAssertEqual(plan.qualityLabel, "1080p"); XCTAssertEqual(plan.userAgent, "UA/1")
    }

    func testMaxHeightLimitsAndMuxedWinsWhenEqual() throws {
        let p = playback(adaptive: [v(1, 360), v(2, 720), v(3, 1080), aac(9, 128)], muxed: [v(18, 360), v(22, 720)])
        XCTAssertEqual(try PlaybackSourcePlanner.plan(p, maxHeight: 720).source, .progressive(url: "https://x/22", height: 720), "gleich hoch: ein Strom statt zwei")
        XCTAssertEqual(try PlaybackSourcePlanner.plan(p, maxHeight: 360).source, .progressive(url: "https://x/18", height: 360))
        XCTAssertEqual(try PlaybackSourcePlanner.plan(p).source, .separate(videoUrl: "https://x/3", audioUrl: "https://x/9", height: 1080))
    }

    func testOnlyAboveLimitFallsBackToLowestStep() throws {
        let p = playback(adaptive: [v(2, 720), v(3, 1080), aac(9, 128)])
        XCTAssertEqual(try PlaybackSourcePlanner.plan(p, maxHeight: 360).source, .separate(videoUrl: "https://x/2", audioUrl: "https://x/9", height: 720))
    }

    func testAudioOnlyPrefersAacThenMuxedNeverOpus() throws {
        XCTAssertEqual(try PlaybackSourcePlanner.plan(playback(adaptive: [aac(8, 48), aac(9, 128), opus(10, 160)]), audioOnly: true).source, .audioOnly(url: "https://x/9"))
        let opusOnly = playback(adaptive: [opus(10, 160)], muxed: [v(18, 360)])
        XCTAssertEqual(try PlaybackSourcePlanner.plan(opusOnly, audioOnly: true).source, .progressive(url: "https://x/18", height: 360))
        XCTAssertThrowsError(try PlaybackSourcePlanner.plan(playback(adaptive: [opus(10, 160)]), audioOnly: true))
    }

    func testHlsIsKeptAsFallbackForNonHlsSources() throws {
        let withHls = playback(adaptive: [v(1, 1080), aac(9, 128)], hls: "https://x/h.m3u8")
        let plan = try PlaybackSourcePlanner.plan(withHls)
        XCTAssertEqual(plan.source, .separate(videoUrl: "https://x/1", audioUrl: "https://x/9", height: 1080))
        XCTAssertEqual(plan.hlsFallbackUrl, "https://x/h.m3u8", "Notweg, falls das Zusammensetzen auf dem Gerät scheitert")
        XCTAssertNil(try PlaybackSourcePlanner.plan(playback(adaptive: [v(1, 1080), aac(9, 128)])).hlsFallbackUrl)
        XCTAssertNil(try PlaybackSourcePlanner.plan(playback(adaptive: [vp9(3, 1080), opus(10, 160)], hls: "https://x/h.m3u8")).hlsFallbackUrl, "HLS selbst hat keinen Notweg")
    }

    func testLadderOffersLowerQualitiesHighestFirst() throws {
        let p = playback(adaptive: [v(1, 1080), v(2, 720), v(4, 360), aac(9, 128)])
        let plan = try PlaybackSourcePlanner.plan(p)
        XCTAssertEqual(plan.source, .separate(videoUrl: "https://x/1", audioUrl: "https://x/9", height: 1080))
        XCTAssertEqual(plan.ladder.map(\.source), [
            .separate(videoUrl: "https://x/2", audioUrl: "https://x/9", height: 720),
            .separate(videoUrl: "https://x/4", audioUrl: "https://x/9", height: 360)
        ], "Die gewählte Stufe steht nicht noch einmal in der Leiter")
        XCTAssertTrue(try PlaybackSourcePlanner.plan(p, audioOnly: true).ladder.isEmpty)
    }

    func testLiveUsesHlsOrFails() throws {
        let plan = try PlaybackSourcePlanner.plan(playback(adaptive: [v(1, 720), aac(9, 128)], hls: "https://x/live.m3u8", live: true))
        XCTAssertEqual(plan.source, .hls(url: "https://x/live.m3u8")); XCTAssertTrue(plan.isLive)
        XCTAssertThrowsError(try PlaybackSourcePlanner.plan(playback(live: true)))
    }

    func testOnlyUnplayableCodecsUseHlsOtherwiseFail() throws {
        let p = playback(adaptive: [vp9(3, 1080), opus(10, 160)], hls: "https://x/h.m3u8")
        XCTAssertEqual(try PlaybackSourcePlanner.plan(p).source, .hls(url: "https://x/h.m3u8"))
        XCTAssertThrowsError(try PlaybackSourcePlanner.plan(playback(adaptive: [vp9(3, 1080), opus(10, 160)]))) { error in
            XCTAssertTrue((error as? PlaybackPlanError)?.message.contains("VP9") == true)
        }
    }

    func testFormatsWithoutUrlAreIgnoredAndThrottleFlagPassedThrough() throws {
        var noUrl = v(2, 1080); noUrl.url = nil
        let plan = try PlaybackSourcePlanner.plan(playback(adaptive: [noUrl, v(1, 720), aac(9, 128)], throttled: true))
        XCTAssertEqual(plan.source, .separate(videoUrl: "https://x/1", audioUrl: "https://x/9", height: 720))
        XCTAssertTrue(plan.throttled)
    }

    func testSeparateNeedsAacOtherwiseMuxed() throws {
        let plan = try PlaybackSourcePlanner.plan(playback(adaptive: [v(3, 1080), opus(10, 160)], muxed: [v(18, 360)]))
        XCTAssertEqual(plan.source, .progressive(url: "https://x/18", height: 360))
    }
}
