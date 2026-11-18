import Foundation

/// Videokarte in Listen (Startseite, Abos, Suche, Empfehlungen).
public struct VideoItem: Equatable, Hashable, Codable, Sendable {
    public var videoId: String
    public var title: String
    public var channelName: String?
    public var channelId: String?
    public var thumbnailUrl: String
    public var durationSeconds: Int64?
    public var viewCountText: String?
    public var publishedText: String?
    public var isLive: Bool
    /// Vertikales Kurzvideo (Shorts).
    public var isShort: Bool

    public init(videoId: String, title: String, channelName: String? = nil, channelId: String? = nil, thumbnailUrl: String,
                durationSeconds: Int64? = nil, viewCountText: String? = nil, publishedText: String? = nil,
                isLive: Bool = false, isShort: Bool = false) {
        self.videoId = videoId; self.title = title; self.channelName = channelName; self.channelId = channelId
        self.thumbnailUrl = thumbnailUrl; self.durationSeconds = durationSeconds; self.viewCountText = viewCountText
        self.publishedText = publishedText; self.isLive = isLive; self.isShort = isShort
    }
}

public struct ChannelItem: Equatable, Hashable, Sendable {
    public var channelId: String
    public var name: String
    public var avatarUrl: String?
    public var subscriberText: String?
}

/// Eine horizontale Reihe (Shelf) der Startseite.
public struct Shelf: Equatable, Codable, Sendable {
    public var title: String
    public var items: [VideoItem]
}

public struct FeedPage: Equatable, Codable, Sendable {
    public var shelves: [Shelf]
    public var continuation: String?
    /// Gesetzt, wenn die Seite ohne Netz aus dem Zwischenspeicher kommt.
    public var cachedAtMs: Int64?
}

public struct SubscribedChannel: Equatable, Hashable, Sendable {
    public var channelId: String
    public var name: String
    public var avatarUrl: String?
    public var hasNewContent: Bool
}

public struct PlaylistItem: Equatable, Hashable, Sendable {
    public var playlistId: String
    public var title: String
    public var ownerName: String?
    public var thumbnailUrl: String?
    public var videoCountText: String?
    /// Automatischer Mix (RD…): nicht über /browse abrufbar, startet mit [firstVideoId].
    public var isMix: Bool
    public var firstVideoId: String?
    /// Browse-ID der Playlist-Seite; für Mixe nicht vorhanden.
    public var browseId: String? { isMix ? nil : "VL" + playlistId }
}

/// „Ergebnisse für X – stattdessen suchen nach Y" (autoCorrected) bzw. „Meintest du: X".
public struct SearchCorrection: Equatable, Sendable {
    public var correctedQuery: String
    public var originalQuery: String?
    public var autoCorrected: Bool
    /// Such-Parameter, mit denen YouTube die Originaleingabe ohne Korrektur sucht.
    public var originalQueryParams: String?
}

public enum SearchResult: Equatable, Sendable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)
    /// Eingebettete Reihe, z. B. „Shorts" oder „Neueste Videos von …".
    case row(title: String, items: [VideoItem], isShorts: Bool)

    /// Stabiler Schlüssel für Listen und zum Entfernen von Dubletten beim Nachladen.
    public var key: String {
        switch self {
        case .video(let v): return "v-\(v.videoId)"
        case .channel(let c): return "c-\(c.channelId)"
        case .playlist(let p): return "p-\(p.playlistId)"
        case .row(let title, let items, _): return "r-\(title)-\(items.first?.videoId ?? "null")"
        }
    }
}

public struct SearchPage: Equatable, Sendable {
    /// Treffer in der Reihenfolge von YouTube (Videos, Kanäle, Playlists und Reihen gemischt).
    public var results: [SearchResult]
    public var continuation: String?
    public var correction: SearchCorrection?

    public var videos: [VideoItem] { results.compactMap { if case .video(let v) = $0 { return v }; return nil } }
    public var channels: [ChannelItem] { results.compactMap { if case .channel(let c) = $0 { return c }; return nil } }
    public var playlists: [PlaylistItem] { results.compactMap { if case .playlist(let p) = $0 { return p }; return nil } }
}

public struct Chapter: Equatable, Hashable, Sendable {
    public var title: String
    public var startMs: Int64
}

public struct WatchNextData: Equatable, Sendable {
    public var videoId: String
    public var related: [VideoItem]
    public var chapters: [Chapter]
}

public struct VideoDetails: Equatable, Sendable {
    public var videoId: String
    public var title: String
    public var author: String
    public var channelId: String?
    public var lengthSeconds: Int64
    public var viewCount: Int64?
    public var shortDescription: String
    public var isLive: Bool
    public var thumbnailUrl: String
}

public struct ByteRange: Equatable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var description: String { "\(start)-\(end)" }
}

/// Ein Eintrag aus `streamingData.adaptiveFormats` bzw. `formats`.
public struct StreamFormat: Equatable, Sendable {
    public var itag: Int
    public var url: String?
    public var signatureCipher: String?
    /// Vollständiger MIME-Typ inkl. Codecs, z. B. `video/webm; codecs="vp9"`.
    public var mimeType: String
    public var bitrate: Int64
    public var averageBitrate: Int64?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var qualityLabel: String?
    public var initRange: ByteRange?
    public var indexRange: ByteRange?
    public var contentLength: Int64?
    public var approxDurationMs: Int64?
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var audioTrackId: String?
    public var audioTrackName: String?
    public var audioIsDefault: Bool
    public var isDrc: Bool
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorMatrix: String?
    public var isOtf: Bool
    public var lastModified: Int64?
    public var xtags: String?

    public static let transferPQ = "COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084"
    public static let transferHLG = "COLOR_TRANSFER_CHARACTERISTICS_ARIB_STD_B67"

    /// Container-MIME ohne Parameter, z. B. `video/webm`.
    public var containerMimeType: String {
        (mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? mimeType)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Codec-String aus dem MIME-Typ, z. B. `vp09.02.51.10.01.09.16.09.00`.
    public var codecs: String {
        guard let r = mimeType.range(of: "codecs=\""), let end = mimeType[r.upperBound...].firstIndex(of: "\"") else { return "" }
        return mimeType[r.upperBound..<end].trimmingCharacters(in: .whitespaces)
    }

    public var isVideo: Bool { containerMimeType.hasPrefix("video/") }
    public var isAudio: Bool { containerMimeType.hasPrefix("audio/") }
    public var isHdr: Bool { colorTransfer == Self.transferPQ || colorTransfer == Self.transferHLG }
    public var isHlg: Bool { colorTransfer == Self.transferHLG }
    public var hasSegmentIndex: Bool { initRange != nil && indexRange != nil && !isOtf }
    /// Sprachcode aus der Audio-Track-ID (`de.4` → `de`).
    public var languageCode: String? {
        guard let id = audioTrackId else { return nil }
        let code = id.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
        return code.trimmingCharacters(in: .whitespaces).isEmpty ? nil : code
    }
}

public struct CaptionTrack: Equatable, Sendable {
    public var baseUrl: String
    public var languageCode: String
    public var name: String
    public var isAutoGenerated: Bool
}

public struct Playability: Equatable, Sendable {
    public var status: String
    public var reason: String?
    public var isPlayable: Bool { status == "OK" }
}

/// Ergebnis des `/player`-Endpunkts. Stream-URLs sind ggf. noch verschlüsselt.
public struct PlayerData: Equatable, Sendable {
    public var playability: Playability
    public var details: VideoDetails?
    public var adaptiveFormats: [StreamFormat]
    public var muxedFormats: [StreamFormat]
    public var hlsManifestUrl: String?
    public var expiresInSeconds: Int64?
    public var captions: [CaptionTrack]
    public var loudnessDb: Double?
    public var storyboardSpec: String?
    public var serverAbrStreamingUrl: String?
    public var ustreamerConfig: String?

    /// Nur SABR: Formate ohne jede Stream-Adresse, aber mit SABR-Adresse.
    public var isSabrOnly: Bool {
        serverAbrStreamingUrl != nil && hlsManifestUrl == nil
            && !(adaptiveFormats + muxedFormats).contains { $0.url != nil || $0.signatureCipher != nil }
    }
}

/// Öffentliche Kontodaten aus `account/accounts_list`.
public struct AccountInfo: Equatable, Sendable {
    public var displayName: String
    public var byline: String?
    public var avatarUrl: String?
    public var channelId: String?
}
