import XCTest
@testable import GuevenCore

final class AppSettingsTests: XCTestCase {
    func testDefaultsMatchAndroid() async {
        let s = await SettingsStore().current()
        XCTAssertTrue(s.sponsorBlockEnabled); XCTAssertFalse(s.deArrowEnabled); XCTAssertNil(s.maxResolution)
        XCTAssertEqual(s.frameRateMatching, .seamlessOnly); XCTAssertEqual(s.defaultPlaybackSpeed, 1.0)
        XCTAssertTrue(s.autoplay); XCTAssertFalse(s.deviceLock); XCTAssertEqual(s.mobileTheme, "SYSTEM")
        XCTAssertEqual(s.skipMode(.sponsor), .autoSkip); XCTAssertEqual(s.skipMode(.filler), .disabled)
        XCTAssertEqual(SettingsStore.playbackSpeeds.count, 12); XCTAssertEqual(SettingsStore.playbackSpeeds.last, 3.0)
    }

    func testUpdateClampsAndTrims() async {
        let st = SettingsStore()
        await st.update { $0.defaultPlaybackSpeed = 9; $0.kidsDailyLimitMinutes = -3; $0.kidsBedtimeHour = 30; $0.remoteConfigUrl = "  https://x/c.json "; $0.clientProfilesUrl = "  " }
        let s = await st.current()
        XCTAssertEqual(s.defaultPlaybackSpeed, 3.0); XCTAssertEqual(s.kidsDailyLimitMinutes, 0); XCTAssertEqual(s.kidsBedtimeHour, 23)
        XCTAssertEqual(s.remoteConfigUrl, "https://x/c.json"); XCTAssertNil(s.clientProfilesUrl)
        await st.update { $0.defaultPlaybackSpeed = 0.1 }
        let lo = await st.current().defaultPlaybackSpeed; XCTAssertEqual(lo, 0.25)
    }

    func testRoundTripPersistenceAndAndroidKeys() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st\(UUID().uuidString)")
        let f = dir.appendingPathComponent("s.json")
        let st = SettingsStore(file: f)
        await st.update {
            $0.maxResolution = .fhd1080; $0.pinnedCodec = .avc; $0.skipModes[.sponsor] = .manualSkip; $0.subtitleLanguage = "de"
            $0.subscriptionSort = .alphabetical; $0.kidsMode = true; $0.mobileTheme = "BLACK"; $0.autoplay = false
        }
        let again = await SettingsStore(file: f).current()
        let orig = await st.current()
        XCTAssertEqual(again, orig)
        let json = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: f))
        XCTAssertEqual(json["video.max_resolution"], "FHD_1080"); XCTAssertEqual(json["sponsorblock.mode.sponsor"], "MANUAL_SKIP")
        XCTAssertEqual(json["playback.autoplay"], "false"); XCTAssertNil(json["mobile.haptics"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testTolerantParsing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st\(UUID().uuidString)")
        let f = dir.appendingPathComponent("s.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(["video.max_resolution": "NOPE", "playback.speed": "nan", "playback.autoplay": "vielleicht",
                                  "mobile.theme": "DYNAMIC", "profile.kids_daily_limit_min": "x", "sponsorblock.mode.sponsor": "??"]).write(to: f)
        let s = await SettingsStore(file: f).current()
        XCTAssertNil(s.maxResolution); XCTAssertEqual(s.defaultPlaybackSpeed, 1.0); XCTAssertTrue(s.autoplay)
        XCTAssertEqual(s.mobileTheme, "SYSTEM"); XCTAssertEqual(s.kidsDailyLimitMinutes, 0); XCTAssertEqual(s.skipMode(.sponsor), .autoSkip)
        try Data("{kaputt".utf8).write(to: f)
        let e = await SettingsStore(file: f).current(); XCTAssertEqual(e, AppSettings())
        try? FileManager.default.removeItem(at: dir)
    }

    func testResetAndUpdatesStream() async {
        let st = SettingsStore()
        let stream = await st.updates()
        var it = stream.makeAsyncIterator()
        let first = await it.next(); XCTAssertEqual(first, AppSettings())
        await st.update { $0.hdrEnabled = false }
        await st.update { $0.hdrEnabled = false } // keine Änderung → kein Ereignis
        let second = await it.next(); XCTAssertEqual(second?.hdrEnabled, false)
        await st.resetAll()
        let third = await it.next(); XCTAssertEqual(third, AppSettings())
    }

    func testEnumsMatchAndroidNames() {
        XCTAssertEqual(ResolutionTier.allCases.map(\.height), [480, 720, 1080, 1440, 2160, 4320])
        XCTAssertEqual(VideoCodec.priority, [.av1, .vp9, .hevc, .avc])
        XCTAssertEqual(SubtitleFormat.ttml.queryValue, "ttml"); XCTAssertEqual(SubtitleSize.large.fractionalTextSize, 0.07)
    }
}
