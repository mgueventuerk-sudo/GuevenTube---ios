import Foundation

/// Ein Eintrag im Musik-Bereich (Port von MusicModels.kt).
public enum MusicItem: Equatable, Hashable, Sendable {
    case song(MusicSong)
    case collection(MusicCollection)

    public var key: String {
        switch self {
        case .song(let s): return s.key
        case .collection(let c): return c.key
        }
    }
    public var title: String {
        switch self {
        case .song(let s): return s.title
        case .collection(let c): return c.title
        }
    }
    public var subtitle: String? {
        switch self {
        case .song(let s): return s.subtitle
        case .collection(let c): return c.subtitle
        }
    }
    public var thumbnailUrl: String? {
        switch self {
        case .song(let s): return s.thumbnailUrl
        case .collection(let c): return c.thumbnailUrl
        }
    }
}

public struct MusicSong: Equatable, Hashable, Codable, Sendable {
    public var videoId: String
    public var title: String
    public var artists: String?
    public var album: String?
    public var thumbnailUrl: String?
    public var durationSeconds: Int64?
    /// Wiedergabeliste, aus der der Titel stammt.
    public var playlistId: String?
    public var artistBrowseId: String?
    public var albumBrowseId: String?

    public init(videoId: String, title: String, artists: String?, album: String?, thumbnailUrl: String?,
                durationSeconds: Int64?, playlistId: String? = nil, artistBrowseId: String? = nil, albumBrowseId: String? = nil) {
        self.videoId = videoId; self.title = title; self.artists = artists; self.album = album
        self.thumbnailUrl = thumbnailUrl; self.durationSeconds = durationSeconds; self.playlistId = playlistId
        self.artistBrowseId = artistBrowseId; self.albumBrowseId = albumBrowseId
    }

    public var key: String { "song:\(videoId)" }

    public var subtitle: String? {
        let joined = [artists, album].compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    /// Für den vorhandenen Player und die Warteschlange.
    public func toVideoItem() -> VideoItem {
        VideoItem(videoId: videoId, title: title, channelName: artists, channelId: nil,
                  thumbnailUrl: thumbnailUrl ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                  durationSeconds: durationSeconds, viewCountText: nil, publishedText: nil, isLive: false)
    }
}

/// Album, Playlist oder Interpret – öffnet eine eigene Seite.
public struct MusicCollection: Equatable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case album, playlist, artist }
    public var browseId: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var thumbnailUrl: String?
    public var playlistId: String?

    public init(browseId: String, kind: Kind, title: String, subtitle: String?, thumbnailUrl: String?, playlistId: String? = nil) {
        self.browseId = browseId; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl; self.playlistId = playlistId
    }

    public var key: String { "col:\(browseId)" }
}

public struct MusicSection: Equatable, Hashable, Sendable {
    public var title: String
    public var items: [MusicItem]
    public init(title: String, items: [MusicItem]) { self.title = title; self.items = items }
}

public struct MusicPage: Equatable, Sendable {
    public var sections: [MusicSection]
    public var continuation: String?
    public init(sections: [MusicSection], continuation: String? = nil) { self.sections = sections; self.continuation = continuation }
}

/// Album-, Playlist- oder Interpretenseite.
public struct MusicDetail: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var thumbnailUrl: String?
    public var tracks: [MusicSong]
    public var sections: [MusicSection]
}

public struct MusicLyrics: Equatable, Sendable {
    public var text: String
    public var source: String?
}

/// Ergebnis von `next`: Radio-Warteschlange und Verweise.
public struct MusicQueue: Equatable, Sendable {
    public var songs: [MusicSong]
    public var lyricsBrowseId: String?
    public var relatedBrowseId: String?
    public var selected: MusicSong?
    public init(songs: [MusicSong], lyricsBrowseId: String?, relatedBrowseId: String? = nil, selected: MusicSong? = nil) {
        self.songs = songs; self.lyricsBrowseId = lyricsBrowseId; self.relatedBrowseId = relatedBrowseId; self.selected = selected
    }
}

public enum MusicRating: String, Codable, Sendable { case like, dislike, none }
