import XCTest
@testable import GuevenCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256Hash.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hash.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Zwei Blöcke (Länge 56 Bytes erzwingt eigenes Polster-Block).
        XCTAssertEqual(SHA256Hash.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testMatchesSystemSha256sumForManyLengths() throws {
        for length in [1, 55, 56, 57, 63, 64, 65, 119, 120, 1000] {
            let text = String(repeating: "x", count: length)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["sha256sum"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(text.utf8)); try input.fileHandleForWriting.close()
            let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(SHA256Hash.hex(text), String(out.prefix(64)), "Länge \(length)")
        }
    }

    func testSponsorPrefix() {
        XCTAssertEqual(SponsorBlockClient.sha256Prefix("abc"), "ba78")
        XCTAssertEqual(SponsorBlockClient.sha256Prefix("dQw4w9WgXcQ").count, 4)
    }
}

final class SponsorBlockClientTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"
    private func ok(_ json: String) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(json.utf8))) }
    private func body(_ segments: String, videoId: String? = nil) -> String {
        #"[{"videoID":"other","segments":[{"category":"sponsor","segment":[1,2],"UUID":"x"}]},{"videoID":"\#(videoId ?? id)","segments":\#(segments)}]"#
    }
    private func make(_ steps: [FakeTransport.Step], now: @escaping @Sendable () -> Int64 = { 1_000_000 }, cache: SponsorSegmentCache = InMemorySponsorCache())
        -> (SponsorBlockClient, FakeTransport) {
        let t = FakeTransport(steps)
        return (SponsorBlockClient(transport: t, cache: cache, nowMs: now), t)
    }
    private let all = Set(SponsorCategory.allCases)

    func testRequestUsesHashPrefixAndSendsAllCategories() async throws {
        let (client, t) = make([ok(body("[]"))])
        _ = try await client.segments(id, categories: all)
        let url = t.requests[0].url.absoluteString
        XCTAssertTrue(url.hasPrefix("https://sponsor.ajay.app/api/skipSegments/\(SponsorBlockClient.sha256Prefix(id))?"), url)
        XCTAssertFalse(url.contains(id), "die Video-ID selbst darf nie gesendet werden")
        let items = URLComponents(url: t.requests[0].url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "actionTypes" }?.value, #"["skip"]"#)
        XCTAssertTrue(items.first { $0.name == "categories" }!.value!.contains(#""music_offtopic""#))
        XCTAssertNotNil(t.requests[0].headers["User-Agent"])
    }

    func testFiltersOwnVideoSortsAndDropsInvalid() async throws {
        let segs = #"""
        [{"category":"intro","segment":[30.5,40],"UUID":"b"},
         {"category":"sponsor","segment":[10,20.25],"UUID":"a"},
         {"category":"sponsor","actionType":"mute","segment":[50,60],"UUID":"m"},
         {"category":"sponsor","segment":[70],"UUID":"short"},
         {"category":"sponsor","segment":[80,80],"UUID":"empty"},
         {"category":"unbekannt","segment":[90,95],"UUID":"u"}]
        """#
        let (client, _) = make([ok(body(segs))])
        let result = try await client.segments(id, categories: all)
        XCTAssertEqual(result.map(\.uuid), ["a", "b"])
        XCTAssertEqual(result[0].startMs, 10_000); XCTAssertEqual(result[0].endMs, 20_250)
    }

    func testCategoryFilterAppliedLocallyAndEmptySetSkipsNetwork() async throws {
        let (client, t) = make([ok(body(#"[{"category":"intro","segment":[1,2],"UUID":"i"},{"category":"sponsor","segment":[3,4],"UUID":"s"}]"#))])
        let v0 = try await client.segments(id, categories: []).isEmpty
        XCTAssertTrue(v0)
        XCTAssertEqual(t.requests.count, 0)
        let v1 = try await client.segments(id, categories: [.sponsor]).map(\.uuid)
        XCTAssertEqual(v1, ["s"])
    }

    func testCacheServesSecondCallWithinThirtyMinutes() async throws {
        let (client, t) = make([ok(body(#"[{"category":"sponsor","segment":[1,2],"UUID":"s"}]"#))])
        _ = try await client.segments(id, categories: all)
        let again = try await client.segments(id, categories: [.sponsor])
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(t.requests.count, 1)
    }

    func testStaleCacheRefetchesAndFallsBackToStaleOnFailure() async throws {
        let clock = Clock(1_000_000)
        let (client, t) = make([ok(body(#"[{"category":"sponsor","segment":[1,2],"UUID":"s"}]"#)), .failure], now: { clock.now })
        _ = try await client.segments(id, categories: all)
        clock.now += SponsorBlockClient.cacheTtlMs + 1
        let result = try await client.segments(id, categories: all)   // Abruf scheitert → veraltete Segmente
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(result.map(\.uuid), ["s"])
    }

    func testNotFoundMeansNoSegmentsAndServerErrorWithoutCacheIsEmpty() async throws {
        let (a, _) = make([.response(HTTPResponse(code: 404))])
        let v2 = try await a.segments(id, categories: all).isEmpty
        XCTAssertTrue(v2)
        let (b, _) = make([.response(HTTPResponse(code: 500))])
        let v3 = try await b.segments(id, categories: all).isEmpty
        XCTAssertTrue(v3)
        let (c, _) = make([ok("kein json")])
        let v4 = try await c.segments(id, categories: all).isEmpty
        XCTAssertTrue(v4)
    }

    func testOldCacheEntriesArePurged() async throws {
        let cache = InMemorySponsorCache()
        await cache.put("alt", segmentsJson: "[]", fetchedAt: 0)
        let (client, _) = make([ok(body("[]"))], now: { 10 * SponsorBlockClient.cacheRetentionMs }, cache: cache)
        _ = try await client.segments(id, categories: all)
        let old = await cache.get("alt")
        XCTAssertNil(old)
    }

    func testHighlightParsedAndCached() async throws {
        let (client, t) = make([ok(body(#"[{"category":"poi_highlight","actionType":"poi","segment":[42.5,42.5],"UUID":"h"}]"#))])
        let v5 = try await client.highlight(id)
        XCTAssertEqual(v5, 42_500)
        let v6 = try await client.highlight(id)
        XCTAssertEqual(v6, 42_500)
        XCTAssertEqual(t.requests.count, 1)
    }

    func testNoHighlightIsCachedButFailuresAreNot() async throws {
        let (client, t) = make([ok(body("[]"))])
        let v7 = try await client.highlight(id)
        XCTAssertNil(v7)
        let v8 = try await client.highlight(id)
        XCTAssertNil(v8)
        XCTAssertEqual(t.requests.count, 1)
        let (flaky, ft) = make([.failure, ok(body(#"[{"category":"poi_highlight","segment":[7,7],"UUID":"h"}]"#))])
        let v9 = try await flaky.highlight(id)
        XCTAssertNil(v9)
        let v10 = try await flaky.highlight(id)
        XCTAssertEqual(v10, 7_000, "ein Netzfehler darf den Höhepunkt nicht dauerhaft unterdrücken")
        XCTAssertEqual(ft.requests.count, 2)
    }

    func testCategoryDefaults() {
        XCTAssertEqual(SponsorCategory.sponsor.defaultMode, .autoSkip)
        XCTAssertEqual(SponsorCategory.filler.defaultMode, .disabled)
        XCTAssertEqual(SponsorCategory.sponsor.colorArgb, 0xFF00D400)
        XCTAssertEqual(SponsorCategory.fromApiKey("music_offtopic"), .music_offtopic)
        XCTAssertNil(SponsorCategory.fromApiKey("poi_highlight"))
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64
    init(_ v: Int64) { value = v }
    var now: Int64 { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

final class DownloadQualityTests: XCTestCase {
    private func fmt(_ itag: Int, _ mime: String, url: String? = "https://x/", h: Int? = nil, fps: Int? = nil, label: String? = nil,
                     br: Int64 = 100, avg: Int64? = nil, drc: Bool = false, otf: Bool = false) -> StreamFormat {
        StreamFormat(itag: itag, url: url, signatureCipher: nil, mimeType: mime, bitrate: br, averageBitrate: avg, width: nil, height: h, fps: fps,
                     qualityLabel: label, initRange: nil, indexRange: nil, contentLength: nil, approxDurationMs: nil, audioSampleRate: nil,
                     audioChannels: nil, audioTrackId: nil, audioTrackName: nil, audioIsDefault: false, isDrc: drc, colorPrimaries: nil,
                     colorTransfer: nil, colorMatrix: nil, isOtf: otf, lastModified: nil, xtags: nil)
    }
    private func video(_ itag: Int, _ h: Int, fps: Int? = nil, codec: String = "avc1.640028", container: String = "mp4", label: String? = nil) -> StreamFormat {
        fmt(itag, "video/\(container); codecs=\"\(codec)\"", h: h, fps: fps, label: label ?? "\(h)p")
    }
    private func audio(_ itag: Int, br: Int64, container: String = "mp4", codec: String = "mp4a.40.2", drc: Bool = false, avg: Int64? = nil) -> StreamFormat {
        fmt(itag, "audio/\(container); codecs=\"\(codec)\"", br: br, avg: avg, drc: drc)
    }
    private func playback(_ formats: [StreamFormat]) -> ResolvedPlayback {
        let data = PlayerData(playability: Playability(status: "OK", reason: nil), details: nil, adaptiveFormats: formats, muxedFormats: [],
                              hlsManifestUrl: nil, expiresInSeconds: nil, captions: [], loudnessDb: nil, storyboardSpec: nil,
                              serverAbrStreamingUrl: nil, ustreamerConfig: nil)
        return ResolvedPlayback(videoId: "v", playerData: data, adaptiveFormats: formats, muxedFormats: [], resolvedAtMs: 0, expiresAtMs: 1,
                                clientLabel: "t", userAgent: "ua", attempts: [])
    }

    func testPicksHighestWithinLimitAndFallsBackToLowest() {
        let p = playback([video(1, 360), video(2, 720), video(3, 1080), video(4, 2160), audio(9, br: 128)])
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .hd)?.videoFormat?.itag, 2)
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .fullHd)?.videoFormat?.itag, 3)
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .highest)?.videoFormat?.itag, 4)
        let only = playback([video(5, 720), audio(9, br: 128)])
        XCTAssertEqual(DownloadQualityResolver.resolve(only, quality: .sd)?.videoFormat?.itag, 5, "nichts darunter: kleinste verfügbare")
    }

    func testHigherFrameRateWinsAtSameHeightAndLabelFallsBack() {
        let p = playback([video(1, 1080, fps: 30), video(2, 1080, fps: 60), audio(9, br: 128)])
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .fullHd)?.videoFormat?.itag, 2)
        var f = video(3, 480); f.qualityLabel = nil
        XCTAssertEqual(DownloadQualityResolver.resolve(playback([f, audio(9, br: 1)]), quality: .sd)?.qualityLabel, "480p")
    }

    func testOnlyH264Mp4VideoIsUsed() {
        let p = playback([video(1, 1080, codec: "vp09.00.40.08", container: "webm"), video(2, 1080, codec: "av01.0.08M.08"), video(3, 720), audio(9, br: 1)])
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .highest)?.videoFormat?.itag, 3)
        XCTAssertNil(DownloadQualityResolver.resolve(playback([video(1, 1080, codec: "vp09", container: "webm"), audio(9, br: 1)]), quality: .highest))
    }

    func testAudioOnlyPrefersAacOverOpusAndSkipsDrc() {
        let p = playback([audio(1, br: 160, container: "webm", codec: "opus"), audio(2, br: 128), audio(3, br: 256, drc: true), audio(4, br: 130)])
        let r = DownloadQualityResolver.resolve(p, quality: .audioOnly)
        XCTAssertEqual(r?.audioFormat.itag, 4)
        XCTAssertNil(r?.videoFormat)
        XCTAssertEqual(r?.qualityLabel, "Nur Ton")
    }

    func testAverageBitrateTakesPrecedenceAndOpusIsFallback() {
        XCTAssertEqual(DownloadQualityResolver.bestAudio([audio(1, br: 300, avg: 100), audio(2, br: 200, avg: 150)])?.itag, 2)
        XCTAssertEqual(DownloadQualityResolver.bestAudio([audio(1, br: 160, container: "webm", codec: "opus"), audio(2, br: 70, container: "webm", codec: "opus")])?.itag, 1)
        XCTAssertEqual(DownloadQualityResolver.bestAudio([audio(5, br: 99, drc: true)])?.itag, 5, "nur DRC vorhanden: besser als nichts")
    }

    func testFormatsWithoutUrlAreIgnoredAndNoAudioMeansNil() {
        let noUrl = fmt(1, "audio/mp4; codecs=\"mp4a.40.2\"", url: "  ")
        XCTAssertNil(DownloadQualityResolver.resolve(playback([noUrl, video(2, 720)]), quality: .hd))
        XCTAssertNil(DownloadQualityResolver.resolve(playback([]), quality: .audioOnly))
    }

    func testOtfStreamsExcluded() {
        let p = playback([fmt(1, "video/mp4; codecs=\"avc1.4d401f\"", h: 720, otf: true), video(2, 480), audio(9, br: 1)])
        XCTAssertEqual(DownloadQualityResolver.resolve(p, quality: .highest)?.videoFormat?.itag, 2)
    }

    func testMsRejectsValuesThatWouldTrap() {
        XCTAssertEqual(SponsorBlockClient.ms(1.5), 1500)
        XCTAssertNil(SponsorBlockClient.ms(1e30)); XCTAssertNil(SponsorBlockClient.ms(-1)); XCTAssertNil(SponsorBlockClient.ms(.nan))
    }
}
