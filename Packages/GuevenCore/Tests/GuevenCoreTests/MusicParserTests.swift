import XCTest
@testable import GuevenCore

/// Port von MusicParserTest.kt und MusicCoverTest.kt (Aufbau wie `WEB_REMIX`, gekürzt).
final class MusicParserTests: XCTestCase {
    private func json(_ text: String) -> JSON { try! JSONParser.parse(text) }

    private func thumb(_ url: String) -> String {
        #"{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"\#(url)","width":544,"height":544}]}}}"#
    }
    private func artistRun(_ name: String) -> String {
        #"{"text":"\#(name)","navigationEndpoint":{"browseEndpoint":{"browseId":"UCx","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}"#
    }
    private func albumRun(_ name: String) -> String {
        #"{"text":"\#(name)","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_1","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}"#
    }
    private func listSong(_ videoId: String, _ title: String, _ duration: String = "3:45") -> String {
        let artistA = artistRun("Künstler A"), artistB = artistRun("Künstler B"), album = albumRun("Das Album")
        return #"""
        {"musicResponsiveListItemRenderer":{
          "thumbnail":\#(thumb("https://lh3/" + videoId)),
          "playlistItemData":{"videoId":"\#(videoId)"},
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\#(title)"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\#(artistA),{"text":" & "},\#(artistB),{"text":" • "},\#(album)]}}}
          ],
          "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"\#(duration)"}]}}}]
        }}
        """#
    }

    private func home() -> String {
        let s1 = thumb("https://lh3/s1"), a1 = thumb("https://lh3/a1"), b1 = thumb("https://lh3/b1")
        let hit = listSong("vid00000002", "Hit"), hit2 = listSong("vid00000003", "Zweiter Hit", "1:02:03")
        return #"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[
            {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Schnellauswahl"}]}}},
              "contents":[
                {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Lied 1"}]},"subtitle":{"runs":[{"text":"Song"},{"text":" • "},{"text":"Sängerin"}]},
                  "thumbnailRenderer":\#(s1),"navigationEndpoint":{"watchEndpoint":{"videoId":"vid00000001","playlistId":"RDAMVMvid"}}}},
                {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Ein Album"}]},"subtitle":{"runs":[{"text":"Album • 2024"}]},
                  "thumbnailRenderer":\#(a1),
                  "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_abc","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}},
                  "thumbnailOverlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchPlaylistEndpoint":{"playlistId":"OLAK5uy_x"}}}}}}}},
                {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Eine Band"}]},"thumbnailRenderer":\#(b1),
                  "navigationEndpoint":{"browseEndpoint":{"browseId":"UCband"}}}}
              ]}},
            {"musicShelfRenderer":{"title":{"runs":[{"text":"Charts"}]},"contents":[\#(hit),\#(hit2)]}}
          ],
          "continuations":[{"nextContinuationData":{"continuation":"CONT1"}}]
        }}}}]}}}
        """#
    }

    private func songs(_ items: [MusicItem]) -> [MusicSong] {
        items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
    }

    func testSearchContinuationPageIsParsedAsUntitledSection() throws {
        let cont = #"""
        {"continuationContents":{"musicShelfContinuation":{"contents":[
          {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"vid00000009"},
            "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Weiterer Song"}]}}},
                           {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"},{"text":" • "},{"text":"Band"}]}}}]}}
        ],"continuations":[{"nextContinuationData":{"continuation":"CONT2"}}]}}}
        """#
        let page = MusicParser.parseSections(json(cont))
        XCTAssertEqual(page.sections.count, 1)
        XCTAssertEqual(page.sections[0].title, "")
        XCTAssertEqual(songs(page.sections[0].items).map(\.videoId), ["vid00000009"])
        XCTAssertEqual(page.continuation, "CONT2")
    }

    func testHomeSectionsInDocumentOrderWithAllItemKinds() throws {
        let page = MusicParser.parseSections(json(home()))
        XCTAssertEqual(page.sections.map(\.title), ["Schnellauswahl", "Charts"])
        XCTAssertEqual(page.continuation, "CONT1")
        let quick = page.sections[0].items
        guard case .song(let song) = quick[0], case .collection(let album) = quick[1], case .collection(let band) = quick[2] else {
            return XCTFail("Falsche Eintragsarten")
        }
        XCTAssertEqual(song.videoId, "vid00000001")
        XCTAssertEqual(song.artists, "Sängerin")
        XCTAssertEqual(song.thumbnailUrl, "https://lh3/s1")
        XCTAssertEqual(album.kind, .album)
        XCTAssertEqual(album.playlistId, "OLAK5uy_x")
        XCTAssertEqual(band.kind, .artist)
    }

    func testListItemsCarryArtistsAlbumAndDuration() {
        let charts = songs(MusicParser.parseSections(json(home())).sections[1].items)
        XCTAssertEqual(charts[0].artists, "Künstler A, Künstler B")
        XCTAssertEqual(charts[0].album, "Das Album")
        XCTAssertEqual(charts[0].durationSeconds, 225)
        XCTAssertEqual(charts[1].durationSeconds, 3723)
        XCTAssertEqual(charts[0].subtitle, "Künstler A, Künstler B · Das Album")
    }

    func testAlbumDetailUsesHeaderForTrackCoverAndArtist() {
        let cover = thumb("https://lh3/cover")
        let album = #"""
        {"contents":{"twoColumnBrowseResultsRenderer":{
          "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{
            "title":{"runs":[{"text":"Das Album"}]},"straplineTextOne":{"runs":[{"text":"Die Band"}]},
            "thumbnail":\#(cover)}}]}}}}],
          "secondaryContents":{"sectionListRenderer":{"contents":[
            {"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"trk00000001"},
              "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Titel 1"}]}}},
                             {"musicResponsiveListItemFlexColumnRenderer":{"text":{}}}],
              "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"4:01"}]}}}]}}]}},
            {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Mehr von Die Band"}]}}},
              "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Anderes Album"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_2"}}}}]}}
          ]}}}}}
        """#
        let detail = MusicParser.parseDetail(json(album))
        XCTAssertEqual(detail.title, "Das Album")
        XCTAssertEqual(detail.subtitle, "Die Band")
        XCTAssertEqual(detail.thumbnailUrl, "https://lh3/cover")
        XCTAssertEqual(detail.tracks.count, 1)
        let first = detail.tracks[0]
        XCTAssertEqual(first.thumbnailUrl, "https://lh3/cover")
        XCTAssertEqual(first.artists, "Die Band")
        XCTAssertEqual(first.album, "Das Album")
        XCTAssertEqual(first.durationSeconds, 241)
        XCTAssertEqual(detail.sections.map(\.title), ["Mehr von Die Band"])
    }

    func testRadioQueueAndLyricsReference() {
        let next = #"""
        {"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[
          {"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[
            {"playlistPanelVideoRenderer":{"videoId":"q1","title":{"runs":[{"text":"Eins"}]},"longBylineText":{"runs":[{"text":"Band • Album • 2020"}]},
              "lengthText":{"runs":[{"text":"2:30"}]},"thumbnail":{"thumbnails":[{"url":"https://lh3/q1","width":544}]}}},
            {"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":{"videoId":"q2","title":{"runs":[{"text":"Zwei"}]},"longBylineText":{"runs":[{"text":"Andere • 2021"}]}}},
              "counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":{"videoId":"q2video","title":{"runs":[{"text":"Zwei (Video)"}]}}}}]}}
          ]}}}}}},
          {"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"MPLYt_abc"}}}}
        ]}}}}}
        """#
        let queue = MusicParser.parseQueue(json(next))
        XCTAssertEqual(queue.songs.map(\.videoId), ["q1", "q2"])
        XCTAssertEqual(queue.songs[0].album, "Album")
        XCTAssertNil(queue.songs[1].album, "Jahreszahl ist kein Album")
        XCTAssertEqual(queue.songs[0].durationSeconds, 150)
        XCTAssertEqual(queue.lyricsBrowseId, "MPLYt_abc")
    }

    func testLyricsText() {
        let lyrics = MusicParser.parseLyrics(json(#"""
        {"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{
          "description":{"runs":[{"text":"Zeile 1\nZeile 2"}]},"footer":{"runs":[{"text":"Quelle: LyricFind"}]}}}]}}}
        """#))
        XCTAssertEqual(lyrics?.text, "Zeile 1\nZeile 2")
        XCTAssertEqual(lyrics?.source, "Quelle: LyricFind")
        XCTAssertNil(MusicParser.parseLyrics(json(#"{"contents":{}}"#)))
    }

    func testSearchCardShelfIsTopResult() {
        let top = thumb("https://lh3/top"), s9 = listSong("vid00000009", "Noch einer"), s10 = listSong("vid00000010", "Song")
        let search = #"""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCardShelfRenderer":{"title":{"runs":[{"text":"Bester Treffer"}]},"subtitle":{"runs":[{"text":"Song • Sänger"}]},
             "thumbnail":\#(top),"onTap":{"watchEndpoint":{"videoId":"top00000001"}},
             "contents":[\#(s9)]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Songs"}]},"contents":[\#(s10)]}}
        ]}}}}]}}}
        """#
        let page = MusicParser.parseSections(json(search))
        XCTAssertEqual(page.sections.map(\.title), ["Top-Ergebnis", "Songs"])
        XCTAssertEqual(songs(page.sections[0].items).map(\.videoId), ["top00000001", "vid00000009"])
        XCTAssertEqual(songs(page.sections[0].items)[0].artists, "Sänger")
    }

    func testUnknownOrBrokenStructuresYieldEmptyResults() {
        let inputs = [#"{}"#, #"{"contents":[1,2,{"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{}}]}}]}"#,
                      #"{"musicCarouselShelfRenderer":{"contents":"kaputt"}}"#]
        for text in inputs {
            let page = MusicParser.parseSections(json(text))
            XCTAssertTrue(page.sections.allSatisfy { $0.items.isEmpty })
            _ = MusicParser.parseDetail(json(text))
            _ = MusicParser.parseQueue(json(text))
        }
    }

    func testDurations() {
        XCTAssertEqual(MusicParser.parseDuration("0:59"), 59)
        XCTAssertEqual(MusicParser.parseDuration("1:02:03"), 3723)
        XCTAssertNil(MusicParser.parseDuration("abc"))
        XCTAssertNil(MusicParser.parseDuration("1:2:3:4"))
        XCTAssertTrue(MusicParser.isDuration("3:45"))
        XCTAssertFalse(MusicParser.isDuration("٣:٤٥"))
        XCTAssertFalse(MusicParser.isDuration("123:45"))
    }

    /// Echte WEB_REMIX-Antwort (eingefroren): Reiter „Ähnlich“, ausgewählter Titel mit Interpret-Link.
    func testRealNextHasRelatedTabAndArtistLinks() throws {
        let queue = MusicParser.parseQueue(try Fixtures.json("remix_next"))
        XCTAssertTrue((queue.lyricsBrowseId ?? "").hasPrefix("MPLYt"))
        XCTAssertTrue((queue.relatedBrowseId ?? "").hasPrefix("MPTRt"))
        let selected = try XCTUnwrap(queue.selected)
        XCTAssertEqual(selected.videoId, "kJQP7kiw5Fk")
        XCTAssertEqual(selected.artistBrowseId, "UCk91oFc2hY2CdHirU93baLg")
        XCTAssertEqual(selected.artists, "Luis Fonsi, Daddy Yankee")
        XCTAssertNil(selected.album, "Aufrufe sind kein Album")
        XCTAssertGreaterThan(queue.songs.count, 10)
    }

    func testRealRelatedPageHasSections() throws {
        let page = MusicParser.parseSections(try Fixtures.json("remix_related"))
        let titles = page.sections.map(\.title)
        XCTAssertTrue(Set(["Das könnte dir auch gefallen", "Ähnliche Interpreten"]).isSubset(of: Set(titles)), "\(titles)")
        XCTAssertTrue(page.sections.allSatisfy { !$0.items.isEmpty })
    }

    func testCoverUpscaleOnlyForGoogleusercontent() {
        XCTAssertEqual(MusicCover.hiRes("https://lh3.googleusercontent.com/abc=w544-h544-l90-rj"),
                       "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj")
        let url = "https://i.ytimg.com/vi/abc/hqdefault.jpg"
        XCTAssertEqual(MusicCover.hiRes(url), url)
        XCTAssertNil(MusicCover.hiRes(nil))
    }
}
