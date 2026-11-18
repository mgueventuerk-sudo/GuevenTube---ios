import Foundation

/// Eine eigene Playlist im YouTube-Konto, mit der Angabe, ob das Video schon enthalten ist.
public struct AccountPlaylist: Equatable, Sendable, Identifiable {
    public let playlistId: String
    public let title: String
    public let containsVideo: Bool
    public var id: String { playlistId }
    public init(playlistId: String, title: String, containsVideo: Bool) {
        self.playlistId = playlistId; self.title = title; self.containsVideo = containsVideo
    }
}

/// „In Playlist speichern“ und „Später ansehen“ („WL“) im Konto – dieselben Endpunkte wie die offiziellen Apps
/// (Port von `AccountPlaylists.kt`). Die Anfragekörper sind als reine Funktionen getrennt und getestet.
public struct AccountPlaylists: Sendable {
    public typealias Action = @Sendable (String, [(String, JSON)]) async throws -> JSON
    private let action: Action

    public init(action: @escaping Action) { self.action = action }
    public init(service: InnerTubeService) { self.init(action: { try await service.action($0, payload: $1) }) }

    public func playlists(for videoId: String) async throws -> [AccountPlaylist] {
        Self.parse(try await action("playlist/get_add_to_playlist", Self.addToPlaylistPayload(videoId: videoId)))
    }

    public func add(playlistId: String, videoId: String) async throws {
        _ = try await action("browse/edit_playlist", Self.editPayload(playlistId: playlistId, [("action", .string("ACTION_ADD_VIDEO")), ("addedVideoId", .string(videoId))]))
    }

    public func remove(playlistId: String, videoId: String) async throws {
        _ = try await action("browse/edit_playlist", Self.editPayload(playlistId: playlistId, [("action", .string("ACTION_REMOVE_VIDEO_BY_VIDEO_ID")), ("removedVideoId", .string(videoId))]))
    }

    public func create(title: String, videoId: String) async throws {
        _ = try await action("playlist/create", Self.createPayload(title: title, videoId: videoId))
    }

    // MARK: Reine Funktionen

    static func addToPlaylistPayload(videoId: String) -> [(String, JSON)] {
        [("videoIds", .array([.string(videoId)])), ("excludeWatchLater", .bool(false))]
    }

    static func createPayload(title: String, videoId: String) -> [(String, JSON)] {
        [("title", .string(String(title.prefix(150)))), ("privacyStatus", .string("PRIVATE")), ("videoIds", .array([.string(videoId)]))]
    }

    static func editPayload(playlistId: String, _ entries: [(String, JSON)]) -> [(String, JSON)] {
        var action = JSONObject()
        for (k, v) in entries { action.set(k, v) }
        return [("playlistId", .string(playlistId)), ("actions", .array([.object(action)]))]
    }

    static func parse(_ response: JSON) -> [AccountPlaylist] {
        response.findAll("playlistAddToOptionRenderer").compactMap { node in
            guard let id = node.str("playlistId") else { return nil }
            let contains = node.str("containsSelectedVideos")
            return AccountPlaylist(playlistId: id, title: node.text("title") ?? id, containsVideo: contains == "ALL" || contains == "true")
        }
    }
}
