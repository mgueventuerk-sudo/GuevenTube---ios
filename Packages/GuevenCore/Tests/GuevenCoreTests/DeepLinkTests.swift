import XCTest
@testable import GuevenCore

final class DeepLinkTests: XCTestCase {
    func testYouTubeForms() {
        let id = "dQw4w9WgXcQ"
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)?t=90"), .play(videoId: id, startSeconds: 90))
        XCTAssertEqual(DeepLink.parse("https://www.youtube.com/watch?v=\(id)&t=1h2m3s"), .play(videoId: id, startSeconds: 3723))
        XCTAssertEqual(DeepLink.parse("https://m.youtube.com/watch?v=\(id)"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("https://youtube.com/shorts/\(id)"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("gueventube://play?v=\(id)"), .play(videoId: id, startSeconds: nil))
    }

    func testRejectsInvalid() {
        XCTAssertNil(DeepLink.parse("https://youtu.be/zu-kurz"))
        XCTAssertNil(DeepLink.parse("https://evil.example/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(DeepLink.parse("https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(DeepLink.parse("https://youtube.com/watch?v=dQw4w9WgXc!"))
        XCTAssertNil(DeepLink.parse("javascript:alert(1)"))
        XCTAssertNil(DeepLink.parse("gueventube://unknown"))
        XCTAssertNil(DeepLink.parse("gueventube://play?v=a%20b"))
        XCTAssertNil(DeepLink.parse("not a url"))
    }

    func testHugeTimestampsDoNotOverflow() {
        let id = "dQw4w9WgXcQ"
        // Früher: n * 3600 lief über und beendete die App.
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)?t=9000000000000000h"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)?t=9223372036854775807"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)?t=99999999999999999999m"), .play(videoId: id, startSeconds: nil))
        XCTAssertEqual(DeepLink.parse("https://youtu.be/\(id)?t=1000000000"), .play(videoId: id, startSeconds: 1_000_000_000))
    }

    func testPairLinkIsRouted() {
        let uri = "gueventube://pair?h=192.168.1.20&p=4711&fp=abc&tk=secret&n=Wohnzimmer"
        guard case .pair(let req)? = DeepLink.parse(uri) else { return XCTFail("pair erwartet") }
        XCTAssertEqual(req, LinkPairUri.parse(uri))
    }

    func testWidgetSnapshotRoundTripAndTolerance() {
        let items = (0..<5).map { VideoItem(videoId: "id\($0)aaaaaaaa", title: "T\($0)", channelName: "C", thumbnailUrl: "x") }
        let snap = WidgetSnapshot(continueWatching: items)
        XCTAssertEqual(snap.entries.count, 3)
        XCTAssertEqual(WidgetSnapshot.decode(snap.encoded()), snap)
        XCTAssertEqual(WidgetSnapshot.decode(Data("kaputt".utf8)).entries, [])
        XCTAssertEqual(WidgetSnapshot.decode(nil).entries, [])
        XCTAssertEqual(snap.url(for: snap.entries[0])?.absoluteString, "gueventube://play?v=id0aaaaaaaa")
    }
}
