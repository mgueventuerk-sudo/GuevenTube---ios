import XCTest
@testable import GuevenCore

/// Port von `InnerTubeParserTest.kt` und `SubscriptionChannelsParserTest.kt`.
final class FeedParserTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSONParser.parse(text) }

    private let tvHome = #"""
    {"contents":{"tvBrowseRenderer":{"content":{"tvSurfaceContentRenderer":{"content":{"sectionListRenderer":{
      "contents":[
        {"shelfRenderer":{"headerRenderer":{"shelfHeaderRenderer":{"title":{"runs":[{"text":"Für dich"}]}}},
          "content":{"horizontalListRenderer":{"items":[
            {"tileRenderer":{"contentId":"abcdefghijk","contentType":"TILE_CONTENT_TYPE_VIDEO",
              "header":{"tileHeaderRenderer":{"thumbnail":{"thumbnails":[
                  {"url":"//i.ytimg.com/vi/abcdefghijk/default.jpg","width":120,"height":90},
                  {"url":"https://i.ytimg.com/vi/abcdefghijk/hq720.jpg","width":720,"height":404}]},
                "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"text":{"simpleText":"1:02:03"},"style":"DEFAULT"}}]}},
              "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Testvideo"},"lines":[
                {"lineRenderer":{"items":[{"lineItemRenderer":{"text":{"runs":[{"text":"Kanal X"}]}}}]}},
                {"lineRenderer":{"items":[{"lineItemRenderer":{"text":{"simpleText":"1,2 Mio. Aufrufe"}}},
                                           {"lineItemRenderer":{"text":{"simpleText":"•"}}},
                                           {"lineItemRenderer":{"text":{"simpleText":"vor 2 Tagen"}}}]}}]}},
              "onSelectCommand":{"watchEndpoint":{"videoId":"abcdefghijk"}}}},
            {"tileRenderer":{"contentId":"UCchannel","contentType":"TILE_CONTENT_TYPE_CHANNEL",
              "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Kanal"}}}}},
            {"tileRenderer":{"contentId":"livelivelive","contentType":"TILE_CONTENT_TYPE_VIDEO",
              "header":{"tileHeaderRenderer":{"thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"text":{"simpleText":"LIVE"},"style":"LIVE"}}]}},
              "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Livestream"}}}}}
          ]}}}}
      ],
      "continuations":[{"nextContinuationData":{"continuation":"PAGE_TOKEN"}}]
    }}}}}}}
    """#

    func testParsesTvShelvesAndTiles() throws {
        let page = InnerTubeParser.parseFeed(try json(tvHome), defaultShelfTitle: "Empfohlen")
        XCTAssertEqual(page.shelves.count, 1)
        let shelf = try XCTUnwrap(page.shelves.first)
        XCTAssertEqual(shelf.title, "Für dich")
        XCTAssertEqual(shelf.items.count, 2, "Kanal-Kacheln gehören nicht in Videoreihen")
        let video = shelf.items[0]
        XCTAssertEqual(video.videoId, "abcdefghijk")
        XCTAssertEqual(video.title, "Testvideo")
        XCTAssertEqual(video.channelName, "Kanal X")
        XCTAssertEqual(video.durationSeconds, 3723)
        XCTAssertEqual(video.viewCountText, "1,2 Mio. Aufrufe")
        XCTAssertEqual(video.publishedText, "vor 2 Tagen")
        XCTAssertEqual(video.thumbnailUrl, "https://i.ytimg.com/vi/abcdefghijk/hq720.jpg")
        XCTAssertFalse(video.isLive)
        let live = shelf.items[1]
        XCTAssertTrue(live.isLive)
        XCTAssertNil(live.durationSeconds)
        XCTAssertEqual(live.thumbnailUrl, "https://i.ytimg.com/vi/livelivelive/hqdefault.jpg")
        XCTAssertEqual(page.continuation, "PAGE_TOKEN")
    }

    func testParsesChaptersAndExcludesCurrentVideo() throws {
        let next = try json(#"""
        {"playerOverlays":{"markersMap":[{"value":{"chapters":[
           {"chapterRenderer":{"title":{"simpleText":"Intro"},"timeRangeStartMillis":0}},
           {"chapterRenderer":{"title":{"simpleText":"Hauptteil"},"timeRangeStartMillis":95000}}]}}]},
         "contents":{"items":[
           {"compactVideoRenderer":{"videoId":"current1234","title":{"simpleText":"Aktuell"}}},
           {"compactVideoRenderer":{"videoId":"related1234","title":{"simpleText":"Empfehlung"},
             "shortBylineText":{"runs":[{"text":"Kanal Y","navigationEndpoint":{"browseEndpoint":{"browseId":"UCy"}}}]},
             "lengthText":{"simpleText":"4:05"}}}]}}
        """#)
        let data = InnerTubeParser.parseWatchNext(next, videoId: "current1234")
        XCTAssertEqual(data.chapters.map(\.title), ["Intro", "Hauptteil"])
        XCTAssertEqual(data.chapters[1].startMs, 95_000)
        XCTAssertEqual(data.related.count, 1)
        XCTAssertEqual(data.related.first?.channelId, "UCy")
        XCTAssertEqual(data.related.first?.durationSeconds, 245)
    }

    func testParsesPlayerFormats() throws {
        let player = try json(#"""
        {"playabilityStatus":{"status":"OK"},
         "videoDetails":{"videoId":"vid12345678","title":"T","author":"A","lengthSeconds":"634","isLive":false},
         "streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[
           {"itag":337,"signatureCipher":"s=AAA&sp=sig&url=https%3A%2F%2Fx","mimeType":"video/webm; codecs=\"vp09.02.51.10.01.09.16.09.00\"",
            "bitrate":40000000,"width":7680,"height":4320,"fps":60,"initRange":{"start":"0","end":"219"},"indexRange":{"start":"220","end":"1499"},
            "colorInfo":{"primaries":"COLOR_PRIMARIES_BT2020","transferCharacteristics":"COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084"}},
           {"itag":251,"url":"https://y","mimeType":"audio/webm; codecs=\"opus\"","bitrate":160000,"audioChannels":2,"audioSampleRate":"48000",
            "initRange":{"start":"0","end":"265"},"indexRange":{"start":"266","end":"1500"},
            "audioTrack":{"id":"de.4","displayName":"Deutsch","audioIsDefault":true}},
           {"itag":299,"url":"https://z","mimeType":"video/mp4; codecs=\"avc1.64002a\"","type":"FORMAT_STREAM_TYPE_OTF"}]},
         "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
           {"baseUrl":"https://www.youtube.com/api/timedtext?v=x","languageCode":"de","name":{"simpleText":"Deutsch"},"kind":"asr"}]}}}
        """#)
        let data = InnerTubeParser.parsePlayer(player)
        XCTAssertTrue(data.playability.isPlayable)
        XCTAssertEqual(data.details?.lengthSeconds, 634)
        XCTAssertEqual(data.expiresInSeconds, 21540)
        let video = data.adaptiveFormats[0]
        XCTAssertEqual(video.codecs, "vp09.02.51.10.01.09.16.09.00")
        XCTAssertEqual(video.containerMimeType, "video/webm")
        XCTAssertTrue(video.isHdr)
        XCTAssertTrue(video.hasSegmentIndex)
        let audio = data.adaptiveFormats[1]
        XCTAssertEqual(audio.languageCode, "de")
        XCTAssertEqual(audio.audioSampleRate, 48_000)
        XCTAssertFalse(data.adaptiveFormats[2].hasSegmentIndex)
        XCTAssertTrue(data.captions.first?.isAutoGenerated == true)
    }

    func testParsesDurations() {
        XCTAssertEqual(InnerTubeParser.parseDuration("12:34"), 754)
        XCTAssertEqual(InnerTubeParser.parseDuration("0:05"), 5)
        XCTAssertNil(InnerTubeParser.parseDuration("LIVE"))
    }

    func testMarksShortsTilesAndReels() throws {
        let feed = try json(#"""
        {"contents":{"sectionListRenderer":{"contents":[
          {"shelfRenderer":{"title":{"simpleText":"Shorts"},"content":{"horizontalListRenderer":{"items":[
            {"tileRenderer":{"contentId":"shortshort1","contentType":"TILE_CONTENT_TYPE_SHORT",
              "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Kurz"}}},
              "onSelectCommand":{"reelWatchEndpoint":{"videoId":"shortshort1"}}}},
            {"reelItemRenderer":{"videoId":"reelreel123","headline":{"simpleText":"Reel"}}}
          ]}}}}
        ]}}}
        """#)
        let videos = InnerTubeParser.parseFeed(feed, defaultShelfTitle: "Shorts").shelves.flatMap(\.items)
        XCTAssertEqual(videos.map(\.videoId), ["shortshort1", "reelreel123"])
        XCTAssertTrue(videos.allSatisfy(\.isShort))
    }

    // MARK: Abos

    private func tab(_ title: String, _ params: String, newContent: Bool = false) -> String {
        #"""
        {"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"FEsubscriptions","params":"\#(params)"}},
          "title":"\#(title)","selected":false,
          \#(newContent ? "\"presentationStyle\":{\"style\":\"NEW_CONTENT\"}," : "")
          "thumbnail":{"thumbnails":[{"url":"//yt3.googleusercontent.com/a=s48","width":48,"height":48},
                                     {"url":"//yt3.googleusercontent.com/a=s88","width":88,"height":88}]},
          "content":{"tvSurfaceContentRenderer":{"continuation":{"reloadContinuationData":{"continuation":"X"}}}}}}
        """#
    }

    private func subscriptionsResponse() throws -> JSON {
        try json(#"""
        {"contents":{"tvBrowseRenderer":{"content":{"tvSecondaryNavRenderer":{"sections":[{"tvSecondaryNavSectionRenderer":{"tabs":[
          {"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"FEsubscriptions"}},"title":"All","selected":true,
            "content":{"tvSurfaceContentRenderer":{"content":{"sectionListRenderer":{"contents":[
              {"shelfRenderer":{"headerRenderer":{"shelfHeaderRenderer":{"title":{"runs":[{"text":"Heute"}]}}},
                "content":{"horizontalListRenderer":{"items":[
                  {"tileRenderer":{"contentId":"abcdefghijk","contentType":"TILE_CONTENT_TYPE_VIDEO",
                    "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Neues Video"}}},
                    "onSelectCommand":{"watchEndpoint":{"videoId":"abcdefghijk"}}}}]}}}}]}}}}}},
          \#(tab("FastGoerTV", "igMaChhVQ1lyeElJbFVzSDJ4cldpUW93T0ZxSHc%3D")),
          \#(tab("TheDRZJ", "igMaChhVQ19nS01KRmVDZjFiS3pacl9mSUNraWc%3D", newContent: true))
        ]}}]}}}}}
        """#)
    }

    func testChannelsComeFromNavTabsInYouTubeOrderWithoutAllTab() throws {
        let channels = InnerTubeParser.parseSubscriptionChannels(try subscriptionsResponse())
        XCTAssertEqual(channels.map(\.name), ["FastGoerTV", "TheDRZJ"])
        XCTAssertEqual(channels[0].channelId, "UCYrxIIlUsH2xrWiQowOFqHw")
        XCTAssertEqual(channels[1].channelId, "UC_gKMJFeCf1bKzZr_fICkig")
        XCTAssertEqual(channels.map(\.hasNewContent), [false, true])
        XCTAssertEqual(channels[0].avatarUrl, "https://yt3.googleusercontent.com/a=s88")
    }

    func testFeedOfAllTabStillParses() throws {
        let feed = InnerTubeParser.parseFeed(try subscriptionsResponse(), defaultShelfTitle: "Neu von deinen Abos")
        XCTAssertEqual(feed.shelves.count, 1)
        XCTAssertEqual(feed.shelves.first?.items.first?.videoId, "abcdefghijk")
        XCTAssertNil(feed.continuation, "Reload-Token eines Kanal-Reiters ist keine Seitenfortsetzung")
    }

    func testInvalidParamsAreIgnored() {
        XCTAssertNil(InnerTubeParser.channelIdFromParams("%%%"))
    }

    // MARK: JSON-Leser

    func testJSONParserKeepsKeyOrderAndUnicode() throws {
        let v = try json(#"{"b":1,"a":"ä😀","c":[true,null,2.5e3]}"#)
        XCTAssertEqual(v.objectValue?.entries.map(\.key), ["b", "a", "c"])
        XCTAssertEqual(v.str("a"), "ä😀")
        XCTAssertEqual(v.int("b"), 1)
        XCTAssertEqual(v.path("c", 0).map { $0 }, .bool(true))
        XCTAssertNil(v.str("c"))
    }

    func testJSONParserRejectsGarbageAndDeepNesting() {
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":"))
        XCTAssertThrowsError(try JSONParser.parse("[1,]"))
        XCTAssertThrowsError(try JSONParser.parse(String(repeating: "[", count: 5000)))
    }
}
