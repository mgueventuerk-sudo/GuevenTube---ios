import Foundation

/// Wandelt InnerTube-Antworten in Domänenmodelle um (Port von `InnerTubeParser.kt`).
///
/// Statt fester Pfade wird der Baum nach bekannten Renderer-Schlüsseln durchsucht. Das deckt TV-Renderer
/// (`tileRenderer`, `shelfRenderer`) wie Web-Renderer (`videoRenderer`, `lockupViewModel`) ab und übersteht
/// die häufigen Umstrukturierungen der Antworten.
public enum InnerTubeParser {

    static let shelfKeys: Set<String> = ["shelfRenderer", "richShelfRenderer", "reelShelfRenderer", "gridShelfViewModel", "horizontalCardListRenderer"]
    static let videoKeys: Set<String> = [
        "tileRenderer", "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "reelItemRenderer", "lockupViewModel", "videoWithContextRenderer",
    ]
    static let channelKeys: Set<String> = ["channelRenderer", "gridChannelRenderer", "tileRenderer"]
    static let playlistLockupTypes: Set<String> = [
        "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_COURSE",
    ]

    // MARK: Feeds (Startseite, Abos, Verlauf, Kanal)

    public static func parseFeed(_ root: JSON, defaultShelfTitle: String) -> FeedPage {
        var shelves: [ShelfBuilder] = []
        let loose = ShelfBuilder(defaultShelfTitle)
        walkFeed(root, current: nil, shelves: &shelves, loose: loose, defaultTitle: defaultShelfTitle, depth: 0)
        var result: [Shelf] = []
        if !loose.items.isEmpty { result.append(loose.build()) }
        for s in shelves where !s.items.isEmpty { result.append(s.build()) }
        return FeedPage(shelves: result, continuation: findPageContinuation(root), cachedAtMs: nil)
    }

    final class ShelfBuilder {
        let title: String
        var items: [VideoItem] = []
        private var seen = Set<String>()
        init(_ title: String) { self.title = title }
        func add(_ item: VideoItem) { if seen.insert(item.videoId).inserted { items.append(item) } }
        func build() -> Shelf { Shelf(title: title, items: items) }
    }

    private static func walkFeed(_ element: JSON, current: ShelfBuilder?, shelves: inout [ShelfBuilder], loose: ShelfBuilder,
                                 defaultTitle: String, depth: Int) {
        // Schutz vor absurd tief verschachtelten Antworten; echte Antworten sind < 60 tief.
        if depth > maxJSONDepth { return }
        switch element {
        case .object(let o):
            for (key, value) in o.entries {
                if case .object = value, shelfKeys.contains(key) {
                    let shelf = ShelfBuilder(shelfTitle(value) ?? defaultTitle)
                    shelves.append(shelf)
                    walkFeed(value, current: shelf, shelves: &shelves, loose: loose, defaultTitle: defaultTitle, depth: depth + 1)
                    continue
                }
                if case .object = value, videoKeys.contains(key) {
                    if let item = parseVideoItem(key, value) { (current ?? loose).add(item) }
                    continue
                }
                walkFeed(value, current: current, shelves: &shelves, loose: loose, defaultTitle: defaultTitle, depth: depth + 1)
            }
        case .array(let a):
            for child in a { walkFeed(child, current: current, shelves: &shelves, loose: loose, defaultTitle: defaultTitle, depth: depth + 1) }
        default: break
        }
    }

    private static func shelfTitle(_ shelf: JSON) -> String? {
        if let t = shelf.text("title") { return t }
        for header in [shelf.obj("headerRenderer"), shelf.obj("header")].compactMap({ $0 }) {
            if let t = header.findFirst("title").asText() { return t }
            if let t = header.findFirst("headline").asText() { return t }
        }
        return nil
    }

    // MARK: Abonnierte Kanäle (TV: FEsubscriptions → tvSecondaryNavRenderer)

    public static func parseSubscriptionChannels(_ root: JSON) -> [SubscribedChannel] {
        var result: [SubscribedChannel] = []
        var seen = Set<String>()
        for section in root.findAll("tvSecondaryNavSectionRenderer") {
            for tab in section.arr("tabs") ?? [] {
                guard let renderer = tab.obj("tabRenderer"),
                      let params = renderer.path("endpoint", "browseEndpoint").str("params"),
                      let channelId = channelIdFromParams(params),
                      let name = renderer.text("title") else { continue }
                if seen.insert(channelId).inserted {
                    result.append(SubscribedChannel(
                        channelId: channelId, name: name,
                        avatarUrl: renderer.obj("thumbnail").arr("thumbnails").bestThumbnailUrl(88),
                        hasNewContent: renderer.obj("presentationStyle").str("style") == "NEW_CONTENT"))
                }
            }
        }
        return result
    }

    /// `igMaChhVQ1ly…%3D` → Protobuf mit der Kanal-ID `UC…` (24 Zeichen).
    public static func channelIdFromParams(_ params: String) -> String? {
        guard let decoded = params.removingPercentEncoding else { return nil }
        let standard = decoded
        let urlSafe = decoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        for candidate in [standard, urlSafe] {
            var padded = candidate.replacingOccurrences(of: "=", with: "")
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded) else { continue }
            let text = String(data.map { Character(Unicode.Scalar($0)) })
            if let m = channelIdRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range, in: text) { return String(text[r]) }
        }
        return nil
    }

    private static let channelIdRegex = try! NSRegularExpression(pattern: "UC[0-9A-Za-z_-]{22}")

    // MARK: Suche

    /// Suche über den WEB-Client: Treffer bleiben in YouTubes Reihenfolge, Werbung und Infokarten werden
    /// verworfen, Korrektur und Fortsetzung werden übernommen. Antworten ohne Web-Struktur laufen über
    /// [parseLegacySearch].
    public static func parseSearch(_ root: JSON) -> SearchPage {
        guard let sections = webSearchSections(root) else { return parseLegacySearch(root) }
        var results: [SearchResult] = []
        var seen = Set<String>()
        var correction: SearchCorrection?
        var continuation: String?
        for section in sections {
            if let token = section.obj("continuationItemRenderer").findFirst("continuationCommand").str("token") {
                continuation = token
                continue
            }
            for item in section.obj("itemSectionRenderer").arr("contents") ?? [] {
                guard let first = item.objectValue?.entries.first, case .object = first.value else { continue }
                let key = first.key, value = first.value
                switch key {
                case "showingResultsForRenderer": correction = parseCorrection(value, autoCorrected: true) ?? correction
                case "didYouMeanRenderer": correction = correction ?? parseCorrection(value, autoCorrected: false)
                case "officialCardViewModel":
                    for r in parseOfficialCard(value) where seen.insert(r.key).inserted { results.append(r) }
                default:
                    if let r = parseSearchItem(key, value), seen.insert(r.key).inserted { results.append(r) }
                }
            }
        }
        return SearchPage(results: results, continuation: continuation, correction: correction)
    }

    private static func webSearchSections(_ root: JSON) -> [JSON]? {
        if let c = root.path("contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer").arr("contents") { return c }
        guard let commands = root.arr("onResponseReceivedCommands") else { return nil }
        let flat = commands.flatMap { command -> [JSON] in
            (command.obj("appendContinuationItemsAction") ?? command.obj("reloadContinuationItemsCommand")).arr("continuationItems") ?? []
        }
        return flat.isEmpty ? nil : flat
    }

    /// Nicht behandelte Schlüssel (adSlotRenderer, searchPyvRenderer, promoted…, Filme) entfallen.
    private static func parseSearchItem(_ key: String, _ node: JSON) -> SearchResult? {
        switch key {
        case "videoRenderer": return parseClassicVideo(node).map(SearchResult.video)
        case "channelRenderer": return parseWebChannel(node).map(SearchResult.channel)
        case "playlistRenderer", "radioRenderer": return parsePlaylistRenderer(node, isMix: key == "radioRenderer").map(SearchResult.playlist)
        case "lockupViewModel":
            let type = node.str("contentType")
            if type == "LOCKUP_CONTENT_TYPE_VIDEO" { return parseLockup(node).map(SearchResult.video) }
            if let type, playlistLockupTypes.contains(type) { return parsePlaylistLockup(node).map(SearchResult.playlist) }
            return nil
        case "gridShelfViewModel", "reelShelfRenderer": return parseShortsRow(node)
        case "shelfRenderer": return parseVideoRow(node)
        default: return nil
        }
    }

    /// Künstlerkarte oben in der Suche: Mix als Playlist, Top-Videos als Reihe mit dem Künstlernamen.
    private static func parseOfficialCard(_ node: JSON) -> [SearchResult] {
        let title = node.path("header", "pageHeaderViewModel", "title", "dynamicTextViewModel", "text").str("content") ?? ""
        let lockups = (node.arr("contents") ?? [])
            .flatMap { $0.obj("horizontalShelfViewModel").arr("items") ?? [] }
            .compactMap { $0.obj("lockupViewModel") }
        let playlists = lockups.filter { $0.str("contentType").map(playlistLockupTypes.contains) ?? false }
            .compactMap(parsePlaylistLockup).map(SearchResult.playlist)
        let videos = lockups.filter { $0.str("contentType") == "LOCKUP_CONTENT_TYPE_VIDEO" }.compactMap(parseLockup)
        var out = playlists
        if !videos.isEmpty { out.append(.row(title: title, items: videos, isShorts: false)) }
        return out
    }

    /// Im Web steht das Handle in `subscriberCountText`, die Abonnentenzahl in `videoCountText`.
    private static func parseWebChannel(_ node: JSON) -> ChannelItem? {
        guard var channel = parseChannelItem("channelRenderer", node) else { return nil }
        guard node.text("subscriberCountText")?.hasPrefix("@") == true else { return channel }
        channel.subscriberText = node.text("videoCountText") ?? channel.subscriberText
        return channel
    }

    private static func parsePlaylistLockup(_ node: JSON) -> PlaylistItem? {
        guard let playlistId = node.str("contentId") else { return nil }
        let metadata = node.path("metadata", "lockupMetadataViewModel")
        guard let title = metadata.obj("title").str("content") else { return nil }
        let owner = metadata.path("metadata", "contentMetadataViewModel").arr("metadataRows")?.first
            .arr("metadataParts")?.first.obj("text").str("content")
        let thumbnail = node.path("contentImage", "collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel")
        let isMix = isMixId(playlistId)
        return PlaylistItem(
            playlistId: playlistId, title: title, ownerName: owner,
            thumbnailUrl: thumbnail.obj("image").arr("sources").bestThumbnailUrl(),
            videoCountText: isMix ? nil : thumbnail.findFirst("thumbnailBadgeViewModel").str("text"),
            isMix: isMix, firstVideoId: node.findFirst("watchEndpoint").str("videoId"))
    }

    private static func parsePlaylistRenderer(_ node: JSON, isMix: Bool) -> PlaylistItem? {
        guard let playlistId = node.str("playlistId"), let title = node.text("title") else { return nil }
        let thumbnails = node.arr("thumbnails")?.first.arr("thumbnails") ?? node.obj("thumbnail").arr("thumbnails")
        return PlaylistItem(
            playlistId: playlistId, title: title,
            ownerName: (node.obj("shortBylineText") ?? node.obj("longBylineText")).asText(),
            thumbnailUrl: thumbnails.bestThumbnailUrl(), videoCountText: node.text("videoCountText"),
            isMix: isMix || isMixId(playlistId), firstVideoId: node.findFirst("watchEndpoint").str("videoId"))
    }

    private static func isMixId(_ id: String) -> Bool { id.hasPrefix("RD") }

    private static func parseShortsRow(_ node: JSON) -> SearchResult? {
        let entries = node.arr("contents") ?? node.arr("items") ?? []
        let items = entries.compactMap { entry -> VideoItem? in
            if let lockup = entry.obj("shortsLockupViewModel"), let v = parseShortsLockup(lockup) { return v }
            if let reel = entry.obj("reelItemRenderer") { return parseReel(reel) }
            return nil
        }
        if items.isEmpty { return nil }
        let title = node.path("header", "sectionHeaderViewModel", "headline").str("content") ?? node.text("title") ?? "Shorts"
        return .row(title: title, items: items, isShorts: true)
    }

    private static func parseShortsLockup(_ node: JSON) -> VideoItem? {
        guard let videoId = node.path("onTap", "innertubeCommand", "reelWatchEndpoint").str("videoId") else { return nil }
        let overlay = node.obj("overlayMetadata")
        guard let title = overlay.obj("primaryText").str("content") else { return nil }
        return VideoItem(
            videoId: videoId, title: title,
            thumbnailUrl: node.obj("thumbnailViewModel").findFirst("image").arr("sources").bestThumbnailUrl() ?? fallbackThumbnail(videoId),
            viewCountText: overlay.obj("secondaryText").str("content"), isShort: true)
    }

    private static func parseVideoRow(_ node: JSON) -> SearchResult? {
        let content = node.obj("content")
        guard let entries = (content.obj("verticalListRenderer") ?? content.obj("horizontalListRenderer")).arr("items") else { return nil }
        let items = entries.compactMap { entry -> VideoItem? in
            guard let (key, value) = entry.objectValue?.entries.first.map({ ($0.key, $0.value) }), case .object = value,
                  videoKeys.contains(key) else { return nil }
            return parseVideoItem(key, value)
        }
        if items.isEmpty { return nil }
        return .row(title: node.text("title") ?? "", items: items, isShorts: items.allSatisfy { $0.isShort })
    }

    private static func parseCorrection(_ node: JSON, autoCorrected: Bool) -> SearchCorrection? {
        guard let corrected = node.text("correctedQuery") else { return nil }
        return SearchCorrection(
            correctedQuery: corrected, originalQuery: node.text("originalQuery"), autoCorrected: autoCorrected,
            originalQueryParams: node.path("originalQueryEndpoint", "searchEndpoint").str("params"))
    }

    private static func parseLegacySearch(_ root: JSON) -> SearchPage {
        var videos: [VideoItem] = []
        var videoSeen = Set<String>()
        var channels: [ChannelItem] = []
        var channelSeen = Set<String>()
        walkSearch(root, &videos, &videoSeen, &channels, &channelSeen, 0)
        return SearchPage(results: channels.map(SearchResult.channel) + videos.map(SearchResult.video),
                          continuation: findPageContinuation(root), correction: nil)
    }

    private static func walkSearch(_ element: JSON, _ videos: inout [VideoItem], _ videoSeen: inout Set<String>,
                                   _ channels: inout [ChannelItem], _ channelSeen: inout Set<String>, _ depth: Int) {
        if depth > maxJSONDepth { return }
        switch element {
        case .object(let o):
            for (key, value) in o.entries {
                if case .object = value, channelKeys.contains(key), let c = parseChannelItem(key, value) {
                    if channelSeen.insert(c.channelId).inserted { channels.append(c) }
                    continue
                }
                if case .object = value, videoKeys.contains(key) {
                    if let v = parseVideoItem(key, value), videoSeen.insert(v.videoId).inserted { videos.append(v) }
                    continue
                }
                walkSearch(value, &videos, &videoSeen, &channels, &channelSeen, depth + 1)
            }
        case .array(let a): for child in a { walkSearch(child, &videos, &videoSeen, &channels, &channelSeen, depth + 1) }
        default: break
        }
    }

    // MARK: Weiter ansehen (/next): Empfehlungen und Kapitel

    public static func parseWatchNext(_ root: JSON, videoId: String) -> WatchNextData {
        var related: [VideoItem] = []
        var seen = Set<String>()
        collectVideos(root, &related, &seen)
        related.removeAll { $0.videoId == videoId }
        return WatchNextData(videoId: videoId, related: related, chapters: parseChapters(root))
    }

    public static func parseChapters(_ root: JSON) -> [Chapter] {
        var chapters: [Int64: Chapter] = [:]
        for node in root.findAll("chapterRenderer") {
            guard let start = node.long("timeRangeStartMillis"), let title = node.text("title") else { continue }
            if chapters[start] == nil { chapters[start] = Chapter(title: title, startMs: start) }
        }
        if chapters.isEmpty {
            for node in root.findAll("macroMarkersListItemRenderer") {
                guard let seconds = node.path("onTap", "watchEndpoint").long("startTimeSeconds"), let title = node.text("title") else { continue }
                if chapters[seconds * 1000] == nil { chapters[seconds * 1000] = Chapter(title: title, startMs: seconds * 1000) }
            }
        }
        return chapters.values.sorted { $0.startMs < $1.startMs }
    }

    private static func collectVideos(_ element: JSON, _ out: inout [VideoItem], _ seen: inout Set<String>) {
        switch element {
        case .object(let o):
            for (key, value) in o.entries {
                if case .object = value, videoKeys.contains(key) {
                    if let v = parseVideoItem(key, value), seen.insert(v.videoId).inserted { out.append(v) }
                    continue
                }
                collectVideos(value, &out, &seen)
            }
        case .array(let a): for child in a { collectVideos(child, &out, &seen) }
        default: break
        }
    }

    // MARK: Einzelne Renderer

    public static func parseVideoItem(_ key: String, _ node: JSON) -> VideoItem? {
        switch key {
        case "tileRenderer": return parseTile(node)
        case "lockupViewModel": return parseLockup(node)
        case "reelItemRenderer": return parseReel(node)
        default: return parseClassicVideo(node)
        }
    }

    /// TV-Kachel (`TVHTML5`).
    private static func parseTile(_ node: JSON) -> VideoItem? {
        let contentType = node.str("contentType")
        let isShort = contentType?.contains("SHORT") == true
        if let contentType, !contentType.contains("VIDEO"), !isShort { return nil }
        guard let videoId = node.str("contentId") ?? node.path("onSelectCommand", "watchEndpoint").str("videoId") else { return nil }
        let header = node.path("header", "tileHeaderRenderer")
        let metadata = node.path("metadata", "tileMetadataRenderer")
        guard let title = metadata.text("title") else { return nil }
        let lines: [[String]] = (metadata.arr("lines") ?? []).map { line in
            (line.path("lineRenderer").arr("items") ?? [])
                .compactMap { $0.obj("lineItemRenderer").text("text") }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.trimmingCharacters(in: .whitespaces) != "•" }
        }
        let overlay = header.arr("thumbnailOverlays")?.lazy.compactMap { $0.obj("thumbnailOverlayTimeStatusRenderer") }.first
        let overlayText = overlay.text("text")
        let isLive = overlay.str("style") == "LIVE" || overlayText?.caseInsensitiveCompare("LIVE") == .orderedSame
        let secondLine = lines.count > 1 ? lines[1] : []
        let browseId = node.findFirst("browseEndpoint").str("browseId")
        return VideoItem(
            videoId: videoId, title: title, channelName: lines.first?.first,
            channelId: browseId.flatMap { $0.hasPrefix("UC") ? $0 : nil },
            thumbnailUrl: header.obj("thumbnail").arr("thumbnails").bestThumbnailUrl() ?? fallbackThumbnail(videoId),
            durationSeconds: isLive ? nil : overlayText.flatMap(parseDuration),
            viewCountText: secondLine.first, publishedText: secondLine.count > 1 ? secondLine[1] : nil,
            isLive: isLive, isShort: isShort)
    }

    /// Klassische Renderer: videoRenderer, compactVideoRenderer, gridVideoRenderer, playlistVideoRenderer.
    private static func parseClassicVideo(_ node: JSON) -> VideoItem? {
        guard let videoId = node.str("videoId"), let title = node.text("title") ?? node.text("headline") else { return nil }
        let owner = node.obj("ownerText") ?? node.obj("shortBylineText") ?? node.obj("longBylineText")
        let overlay = node.arr("thumbnailOverlays")?.lazy.compactMap { $0.obj("thumbnailOverlayTimeStatusRenderer") }.first
        let lengthText = node.text("lengthText") ?? overlay.text("text")
        let badgesLive = (node.arr("badges") ?? []).contains { $0.obj("metadataBadgeRenderer").str("style") == "BADGE_STYLE_TYPE_LIVE_NOW" }
        let isLive = badgesLive || overlay.str("style") == "LIVE"
        return VideoItem(
            videoId: videoId, title: title, channelName: owner.asText(),
            channelId: owner.findFirst("browseEndpoint").str("browseId"),
            thumbnailUrl: node.obj("thumbnail").arr("thumbnails").bestThumbnailUrl() ?? fallbackThumbnail(videoId),
            durationSeconds: isLive ? nil : lengthText.flatMap(parseDuration),
            viewCountText: node.text("viewCountText") ?? node.text("shortViewCountText"),
            publishedText: node.text("publishedTimeText"), isLive: isLive)
    }

    /// Neues Web-Format `lockupViewModel`.
    private static func parseLockup(_ node: JSON) -> VideoItem? {
        guard node.str("contentType") == "LOCKUP_CONTENT_TYPE_VIDEO", let videoId = node.str("contentId") else { return nil }
        let metadata = node.path("metadata", "lockupMetadataViewModel")
        guard let title = metadata.obj("title").str("content") else { return nil }
        let rows = metadata.path("metadata", "contentMetadataViewModel").arr("metadataRows") ?? []
        let rowTexts: [[String]] = rows.map { row in (row.arr("metadataParts") ?? []).compactMap { $0.obj("text").str("content") } }
        let badge = node.findFirst("thumbnailBadgeViewModel").str("text")
        let isLive = badge?.caseInsensitiveCompare("LIVE") == .orderedSame
        let row0 = rowTexts.first, row1 = rowTexts.count > 1 ? rowTexts[1] : nil
        return VideoItem(
            videoId: videoId, title: title, channelName: row0?.first,
            channelId: metadata.findFirst("browseEndpoint").str("browseId"),
            thumbnailUrl: node.path("contentImage", "thumbnailViewModel", "image").arr("sources").bestThumbnailUrl() ?? fallbackThumbnail(videoId),
            durationSeconds: isLive ? nil : badge.flatMap(parseDuration),
            viewCountText: row1?.first, publishedText: (row1?.count ?? 0) > 1 ? row1?[1] : nil, isLive: isLive)
    }

    private static func parseReel(_ node: JSON) -> VideoItem? {
        guard let videoId = node.str("videoId"), let title = node.text("headline") else { return nil }
        return VideoItem(
            videoId: videoId, title: title,
            thumbnailUrl: node.obj("thumbnail").arr("thumbnails").bestThumbnailUrl() ?? fallbackThumbnail(videoId),
            viewCountText: node.text("viewCountText"), isShort: true)
    }

    private static func parseChannelItem(_ key: String, _ node: JSON) -> ChannelItem? {
        if key == "tileRenderer" {
            guard node.str("contentType")?.contains("CHANNEL") == true,
                  let channelId = node.path("onSelectCommand", "browseEndpoint").str("browseId") ?? node.str("contentId"),
                  let name = node.path("metadata", "tileMetadataRenderer").text("title") else { return nil }
            return ChannelItem(
                channelId: channelId, name: name,
                avatarUrl: node.path("header", "tileHeaderRenderer").obj("thumbnail").arr("thumbnails").bestThumbnailUrl(176),
                subscriberText: node.path("metadata", "tileMetadataRenderer").arr("lines")?.first
                    .findFirst("lineItemRenderer").text("text"))
        }
        guard let channelId = node.str("channelId"), let name = node.text("title") else { return nil }
        return ChannelItem(
            channelId: channelId, name: name, avatarUrl: node.obj("thumbnail").arr("thumbnails").bestThumbnailUrl(176),
            subscriberText: node.text("subscriberCountText") ?? node.text("videoCountText"))
    }

    // MARK: Player

    public static func parsePlayer(_ root: JSON) -> PlayerData {
        let status = root.obj("playabilityStatus")
        let playability = Playability(
            status: status.str("status") ?? "ERROR",
            reason: status.str("reason")
                ?? status.findFirst("playerErrorMessageRenderer").text("reason")
                ?? status.findFirst("errorScreen").findFirst("reason").asText())
        let streamingData = root.obj("streamingData")
        return PlayerData(
            playability: playability,
            details: root.obj("videoDetails").flatMap(parseVideoDetails),
            adaptiveFormats: (streamingData.arr("adaptiveFormats") ?? []).compactMap(parseFormat),
            muxedFormats: (streamingData.arr("formats") ?? []).compactMap(parseFormat),
            hlsManifestUrl: streamingData.str("hlsManifestUrl"),
            expiresInSeconds: streamingData.long("expiresInSeconds"),
            captions: (root.path("captions", "playerCaptionsTracklistRenderer").arr("captionTracks") ?? []).compactMap(parseCaption),
            loudnessDb: root.path("playerConfig", "audioConfig").double("loudnessDb"),
            storyboardSpec: root.path("storyboards", "playerStoryboardSpecRenderer").str("spec"),
            serverAbrStreamingUrl: streamingData.str("serverAbrStreamingUrl"),
            ustreamerConfig: root.path("playerConfig", "mediaCommonConfig", "mediaUstreamerRequestConfig").str("videoPlaybackUstreamerConfig"))
    }

    private static func parseVideoDetails(_ node: JSON) -> VideoDetails? {
        guard let videoId = node.str("videoId") else { return nil }
        return VideoDetails(
            videoId: videoId, title: node.str("title") ?? "", author: node.str("author") ?? "", channelId: node.str("channelId"),
            lengthSeconds: node.long("lengthSeconds") ?? 0, viewCount: node.long("viewCount"),
            shortDescription: node.str("shortDescription") ?? "", isLive: node.bool("isLive") == true,
            thumbnailUrl: node.obj("thumbnail").arr("thumbnails").bestThumbnailUrl(1280) ?? fallbackThumbnail(videoId))
    }

    public static func parseFormat(_ node: JSON) -> StreamFormat? {
        guard case .object = node, let itag = node.int("itag"), let mimeType = node.str("mimeType") else { return nil }
        let audioTrack = node.obj("audioTrack")
        let colorInfo = node.obj("colorInfo")
        return StreamFormat(
            itag: itag, url: node.str("url"), signatureCipher: node.str("signatureCipher") ?? node.str("cipher"),
            mimeType: mimeType, bitrate: node.long("bitrate") ?? 0, averageBitrate: node.long("averageBitrate"),
            width: node.int("width"), height: node.int("height"), fps: node.int("fps"), qualityLabel: node.str("qualityLabel"),
            initRange: parseRange(node.obj("initRange")), indexRange: parseRange(node.obj("indexRange")),
            contentLength: node.long("contentLength"), approxDurationMs: node.long("approxDurationMs"),
            audioSampleRate: node.int("audioSampleRate"), audioChannels: node.int("audioChannels"),
            audioTrackId: audioTrack.str("id"), audioTrackName: audioTrack.str("displayName"),
            audioIsDefault: audioTrack.bool("audioIsDefault") ?? (audioTrack == nil),
            isDrc: node.bool("isDrc") == true, colorPrimaries: colorInfo.str("primaries"),
            colorTransfer: colorInfo.str("transferCharacteristics"), colorMatrix: colorInfo.str("matrixCoefficients"),
            isOtf: node.str("type") == "FORMAT_STREAM_TYPE_OTF", lastModified: node.long("lastModified"), xtags: node.str("xtags"))
    }

    private static func parseRange(_ node: JSON?) -> ByteRange? {
        guard let start = node.long("start"), let end = node.long("end"), end >= start else { return nil }
        return ByteRange(start: start, end: end)
    }

    private static func parseCaption(_ element: JSON) -> CaptionTrack? {
        guard let baseUrl = element.str("baseUrl"), let languageCode = element.str("languageCode") else { return nil }
        return CaptionTrack(baseUrl: normalizeUrl(baseUrl), languageCode: languageCode,
                            name: element.text("name") ?? languageCode, isAutoGenerated: element.str("kind") == "asr")
    }

    // MARK: Konto

    public static func parseAccount(_ root: JSON) -> AccountInfo? {
        let accounts = root.findAll("accountItem") + root.findAll("accountItemRenderer")
        guard let account = accounts.first(where: { $0.bool("isSelected") == true }) ?? accounts.first,
              let name = account.text("accountName") else { return nil }
        return AccountInfo(
            displayName: name, byline: account.text("accountByline") ?? account.text("channelHandle"),
            avatarUrl: account.obj("accountPhoto").arr("thumbnails").bestThumbnailUrl(176),
            channelId: account.findFirst("browseEndpoint").str("browseId"))
    }

    // MARK: Hilfsfunktionen

    /// Seiten-Fortsetzung (nicht die horizontalen Fortsetzungen einzelner Reihen).
    public static func findPageContinuation(_ root: JSON) -> String? {
        let lists = ["sectionListContinuation", "sectionListRenderer", "richGridContinuation", "richGridRenderer"]
            .compactMap { root.findFirst($0) }
        for list in lists {
            if let token = list.arr("continuations")?.lazy.compactMap({ $0.obj("nextContinuationData").str("continuation") }).first { return token }
            if let token = list.arr("contents")?.last.obj("continuationItemRenderer").findFirst("continuationCommand").str("token") { return token }
        }
        let actions = (root.arr("onResponseReceivedActions") ?? []) + (root.arr("onResponseReceivedCommands") ?? [])
        for action in actions {
            guard let items = action.obj("appendContinuationItemsAction").arr("continuationItems")
                ?? action.obj("reloadContinuationItemsCommand").arr("continuationItems") else { continue }
            if let token = items.last.obj("continuationItemRenderer").findFirst("continuationCommand").str("token") { return token }
        }
        return nil
    }

    /// "1:02:03" → 3723 s, "12:34" → 754 s; nicht parsebar → `nil`.
    public static func parseDuration(_ text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        if parts.isEmpty || parts.count > 3 { return nil }
        var total: Int64 = 0
        for part in parts {
            guard let v = Int64(part.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    public static func fallbackThumbnail(_ videoId: String) -> String { "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg" }
}
