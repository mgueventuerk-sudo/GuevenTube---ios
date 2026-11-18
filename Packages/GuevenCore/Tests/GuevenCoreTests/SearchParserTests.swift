import XCTest
@testable import GuevenCore

/// Eingefrorene WEB-Antworten von /youtubei/v1/search (hl=de, gl=DE) – gleiche Erwartungen wie `SearchParserTest.kt`.
final class SearchParserTests: XCTestCase {
    func testKeepsVideoOrderOfYouTube() throws {
        let root = try Fixtures.json("web_mrbeast")
        var expected: [String] = []
        for section in root.path("contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer").arr("contents") ?? [] {
            for item in section.obj("itemSectionRenderer").arr("contents") ?? [] {
                if let id = item.obj("videoRenderer").str("videoId"), !expected.contains(id) { expected.append(id) }
            }
        }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(InnerTubeParser.parseSearch(root).videos.map(\.videoId), expected)
    }

    func testChannelUsesSubscriberCountInsteadOfHandle() throws {
        let page = InnerTubeParser.parseSearch(try Fixtures.json("web_mrbeast"))
        let channel = try XCTUnwrap(page.channels.first { $0.channelId == "UCX6OQ3DkcsbYNE6H8uQQuVA" })
        XCTAssertEqual(channel.name, "MrBeast")
        XCTAssertTrue((channel.subscriberText ?? "").contains("Abonnenten"), channel.subscriberText ?? "nil")
    }

    func testEmbeddedShelfStaysInPlace() throws {
        let page = InnerTubeParser.parseSearch(try Fixtures.json("web_mrbeast"))
        let index = page.results.firstIndex { if case .row(let t, _, _) = $0 { return t.hasPrefix("Neueste Videos von") }; return false }
        let i = try XCTUnwrap(index)
        XCTAssertGreaterThan(i, 0)
        guard case .row(_, let items, _) = page.results[i] else { return XCTFail() }
        XCTAssertFalse(items.isEmpty)
    }

    func testShortsBecomeRow() throws {
        let results = InnerTubeParser.parseSearch(try Fixtures.json("web_minecraft")).results
        let row = results.compactMap { r -> (String, [VideoItem])? in if case .row(let t, let i, true) = r { return (t, i) }; return nil }.first
        let (title, items) = try XCTUnwrap(row)
        XCTAssertEqual(title, "Shorts")
        XCTAssertGreaterThanOrEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.isShort && $0.videoId.count == 11 && !$0.title.isEmpty })
    }

    func testPlaylistsAndMixes() throws {
        let playlists = InnerTubeParser.parseSearch(try Fixtures.json("web_taylor_swift")).playlists
        let mix = try XCTUnwrap(playlists.first { $0.isMix })
        XCTAssertNil(mix.browseId)
        XCTAssertNotNil(mix.firstVideoId)
        let playlist = try XCTUnwrap(playlists.first { !$0.isMix && $0.title == "Taylor Swift Greatest Hits" })
        XCTAssertEqual(playlist.browseId, "VL" + playlist.playlistId)
        XCTAssertEqual(playlist.ownerName, "Revive Music")
        XCTAssertEqual(playlist.videoCountText, "186 Videos")
    }

    func testPlaylistFilterYieldsPlaylists() throws {
        let page = InnerTubeParser.parseSearch(try Fixtures.json("web_filter_playlists_minecraft"))
        XCTAssertGreaterThanOrEqual(page.playlists.count, 15)
        XCTAssertTrue(page.playlists.allSatisfy { !$0.title.isEmpty && $0.thumbnailUrl != nil })
    }

    func testAutoCorrectionIsExposed() throws {
        let c = try XCTUnwrap(InnerTubeParser.parseSearch(try Fixtures.json("web_typo_youtbe_rewind")).correction)
        XCTAssertTrue(c.autoCorrected)
        XCTAssertEqual(c.correctedQuery, "youtube rewind")
        XCTAssertEqual(c.originalQuery, "youtbe rewind")
        XCTAssertNotNil(c.originalQueryParams)
    }

    func testContinuationOnFirstAndFollowUpPage() throws {
        XCTAssertNotNil(InnerTubeParser.parseSearch(try Fixtures.json("web_minecraft")).continuation)
        let more = InnerTubeParser.parseSearch(try Fixtures.json("web_continuation"))
        XCTAssertGreaterThanOrEqual(more.videos.count, 5)
        XCTAssertNotNil(more.continuation)
    }

    func testAdsAndUnknownCardsAreDropped() throws {
        let root = try JSONParser.parse(#"""
        {"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":{"sectionListRenderer":{"contents":[
        {"itemSectionRenderer":{"contents":[
          {"adSlotRenderer":{"fulfillmentContent":{"fulfilledLayout":{"inFeedAdLayoutRenderer":{"renderingContent":
            {"videoRenderer":{"videoId":"AAAAAAAAAAA","title":{"simpleText":"Werbung"}}}}}}}},
          {"searchPyvRenderer":{"ads":[{"videoRenderer":{"videoId":"BBBBBBBBBBB","title":{"simpleText":"Werbung"}}}]}},
          {"videoRenderer":{"videoId":"CCCCCCCCCCC","title":{"simpleText":"Treffer"}}},
          {"officialCardViewModel":{"videoId":"DDDDDDDDDDD"}}
        ]}}]}}}}}
        """#)
        XCTAssertEqual(InnerTubeParser.parseSearch(root).videos.map(\.videoId), ["CCCCCCCCCCC"])
    }

    func testResultKeysAreUnique() throws {
        for name in ["web_minecraft", "web_mrbeast", "web_taylor_swift", "web_typo_youtbe_rewind", "web_continuation"] {
            let keys = InnerTubeParser.parseSearch(try Fixtures.json(name)).results.map(\.key)
            XCTAssertEqual(keys.count, Set(keys).count, name)
        }
    }
}
