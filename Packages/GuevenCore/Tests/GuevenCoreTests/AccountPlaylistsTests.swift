import XCTest
@testable import GuevenCore

final class AccountPlaylistsTests: XCTestCase {
    private func json(_ t: String) -> JSON { try! JSONParser.parse(t) }
    private func serialized(_ p: [(String, JSON)]) -> String {
        var o = JSONObject(); for (k, v) in p { o.set(k, v) }
        return JSON.object(o).serialized()
    }

    func testParsesOptionsAndContainsFlag() {
        let r = json(#"""
        {"contents":[{"addToPlaylistRenderer":{"playlists":[
          {"playlistAddToOptionRenderer":{"playlistId":"WL","title":{"simpleText":"Später ansehen"},"containsSelectedVideos":"NONE"}},
          {"playlistAddToOptionRenderer":{"playlistId":"PL1","title":{"runs":[{"text":"Musik"}]},"containsSelectedVideos":"ALL"}},
          {"playlistAddToOptionRenderer":{"title":{"simpleText":"ohne Id"}}}
        ]}}]}
        """#)
        XCTAssertEqual(AccountPlaylists.parse(r), [
            AccountPlaylist(playlistId: "WL", title: "Später ansehen", containsVideo: false),
            AccountPlaylist(playlistId: "PL1", title: "Musik", containsVideo: true)])
    }

    func testRequestBodiesMatchAndroid() {
        XCTAssertEqual(serialized(AccountPlaylists.addToPlaylistPayload(videoId: "v")), #"{"videoIds":["v"],"excludeWatchLater":false}"#)
        XCTAssertEqual(serialized(AccountPlaylists.editPayload(playlistId: "PL", [("action", .string("ACTION_ADD_VIDEO")), ("addedVideoId", .string("v"))])),
                       #"{"playlistId":"PL","actions":[{"action":"ACTION_ADD_VIDEO","addedVideoId":"v"}]}"#)
        XCTAssertEqual(serialized(AccountPlaylists.createPayload(title: String(repeating: "x", count: 200), videoId: "v")),
                       #"{"title":"\#(String(repeating: "x", count: 150))","privacyStatus":"PRIVATE","videoIds":["v"]}"#)
    }

    func testAddRemoveCreateUseEndpoints() async throws {
        final class Log: @unchecked Sendable { var calls: [String] = [] }
        let log = Log()
        let svc = AccountPlaylists(action: { ep, _ in log.calls.append(ep); return .object(JSONObject()) })
        try await svc.add(playlistId: "P", videoId: "v")
        try await svc.remove(playlistId: "P", videoId: "v")
        try await svc.create(title: "t", videoId: "v")
        XCTAssertEqual(log.calls, ["browse/edit_playlist", "browse/edit_playlist", "playlist/create"])
    }
}
