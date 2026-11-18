import Foundation

/// Liest YouTube-Music-Antworten (`WEB_REMIX`). Port von MusicParser.kt: sucht Renderer über ihre Namen,
/// Unbekanntes wird ausgelassen, nie geworfen.
public enum MusicParser {
    private static let sectionKeys: Set<String> = [
        "musicCarouselShelfRenderer", "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicCardShelfRenderer", "gridRenderer",
    ]
    private static let headerKeys = [
        "musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer",
    ]
    private static let notAlbum = ["Aufrufe", "views", "Likes", "Wiedergaben", "plays"]
    private static let artistPages: Set<String> = ["MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL"]
    private static let typeWords: Set<String> = ["song", "titel", "video", "single", "ep", "album", "playlist", "interpret", "artist", "episode"]

    public static func parseSections(_ root: JSON) -> MusicPage {
        var sections: [MusicSection] = []
        walk(root, 0) { key, node in
            if let s = section(key, node), !s.items.isEmpty { sections.append(s) }
        }
        let continuation = root.findFirst("nextContinuationData").str("continuation")
            ?? root.findFirst("continuationCommand").str("token")
        return MusicPage(sections: sections, continuation: continuation)
    }

    public static func parseDetail(_ root: JSON) -> MusicDetail {
        let header = headerKeys.lazy.compactMap { root.findFirst($0) }.first
        let title = header.text("title") ?? ""
        let subtitle = header.flatMap { $0.text("straplineTextOne") ?? $0.text("subtitle") ?? $0.text("secondSubtitle") }
        let thumbnail = header.flatMap { thumbnailOf($0) }
        let page = parseSections(root)
        let trackSections = page.sections.filter { s in
            !s.items.isEmpty && s.items.allSatisfy { if case .song = $0 { return true } else { return false } }
        }
        var tracks: [MusicSong] = []
        for case .song(var song) in trackSections.first?.items ?? [] {
            song.thumbnailUrl = song.thumbnailUrl ?? thumbnail
            song.artists = song.artists ?? subtitle
            song.album = song.album ?? (header != nil ? title : nil)
            tracks.append(song)
        }
        let removed = trackSections.first
        let rest = page.sections.filter { $0 != removed }
        return MusicDetail(title: title, subtitle: subtitle, thumbnailUrl: thumbnail, tracks: tracks, sections: rest)
    }

    public static func parseQueue(_ root: JSON) -> MusicQueue {
        // Nur die Hauptversion je Eintrag (nicht die Video-/Audio-Gegenstücke im Wrapper).
        let entries: [JSON] = (root.findFirst("playlistPanelRenderer").arr("contents") ?? []).compactMap { entry in
            if let direct = entry.obj("playlistPanelVideoRenderer") { return direct }
            if let wrapped = entry.path("playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"),
               wrapped.objectValue != nil { return wrapped }
            return nil
        }
        var seen = Set<String>()
        let songs = entries.compactMap(panelSong).filter { seen.insert($0.videoId).inserted }
        let tabs = root.findAll("tabRenderer").compactMap { $0.path("endpoint", "browseEndpoint").str("browseId") }
        let selected = entries.first { $0.bool("selected") == true }.flatMap(panelSong)
        return MusicQueue(songs: songs, lyricsBrowseId: tabs.first { $0.hasPrefix("MPLYt") },
                          relatedBrowseId: tabs.first { $0.hasPrefix("MPTRt") }, selected: selected)
    }

    public static func parseLyrics(_ root: JSON) -> MusicLyrics? {
        guard let shelf = root.findFirst("musicDescriptionShelfRenderer"),
              let text = shelf.text("description"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MusicLyrics(text: text, source: shelf.text("footer"))
    }

    public static func parseDuration(_ text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total: Int64 = 0
        for part in parts {
            guard let n = Int64(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    // MARK: - intern

    /// Tiefensuche in Dokumentreihenfolge; in gefundene Abschnitte wird nicht weiter abgestiegen.
    private static func walk(_ element: JSON, _ depth: Int, _ onSection: (String, JSON) -> Void) {
        if depth > maxJSONDepth { return }
        switch element {
        case .object(let o):
            for (key, value) in o.entries {
                if sectionKeys.contains(key), value.objectValue != nil { onSection(key, value) } else { walk(value, depth + 1, onSection) }
            }
        case .array(let a):
            for e in a { walk(e, depth + 1, onSection) }
        default: break
        }
    }

    private static func section(_ key: String, _ node: JSON) -> MusicSection? {
        let title: String?
        switch key {
        case "musicCarouselShelfRenderer": title = node.path("header", "musicCarouselShelfBasicHeaderRenderer").text("title")
        case "musicCardShelfRenderer": title = "Top-Ergebnis"
        case "gridRenderer": title = node.path("header", "gridHeaderRenderer").text("title")
        default: title = node.text("title")
        }
        var items: [MusicItem] = []
        if key == "musicCardShelfRenderer", let c = card(node) { items.append(c) }
        for child in node.arr("contents") ?? node.arr("items") ?? [] {
            if let i = item(child) { items.append(i) }
        }
        var seen = Set<String>()
        return MusicSection(title: title ?? "", items: items.filter { seen.insert($0.key).inserted })
    }

    private static func item(_ element: JSON) -> MusicItem? {
        guard element.objectValue != nil else { return nil }
        if let n = element.obj("musicTwoRowItemRenderer") { return twoRow(n) }
        if let n = element.obj("musicResponsiveListItemRenderer") { return listItem(n) }
        if let n = element.obj("playlistPanelVideoRenderer") { return panelSong(n).map { .song($0) } }
        return nil
    }

    private static func twoRow(_ node: JSON) -> MusicItem? {
        guard let title = node.text("title") else { return nil }
        let subtitle = node.text("subtitle")
        let thumbnail = thumbnailOf(node)
        let navigation = node.obj("navigationEndpoint")
        if let videoId = navigation.obj("watchEndpoint").str("videoId") {
            return .song(MusicSong(videoId: videoId, title: title, artists: artistsFrom(subtitle), album: nil, thumbnailUrl: thumbnail,
                                   durationSeconds: nil, playlistId: navigation.obj("watchEndpoint").str("playlistId")))
        }
        guard let browse = navigation.obj("browseEndpoint"), let browseId = browse.str("browseId") else { return nil }
        let playlistId = node.findFirst("watchPlaylistEndpoint").str("playlistId")
        return .collection(MusicCollection(browseId: browseId, kind: kindOf(browse, browseId), title: title, subtitle: subtitle,
                                           thumbnailUrl: thumbnail, playlistId: playlistId))
    }

    private static func listItem(_ node: JSON) -> MusicItem? {
        let columns: [JSON?] = (node.arr("flexColumns") ?? []).map {
            $0.obj("musicResponsiveListItemFlexColumnRenderer").obj("text")
        }
        guard let title = (columns.first ?? nil).asText() else { return nil }
        let second: JSON? = columns.count > 1 ? columns[1] : nil
        let runs = (second.arr("runs") ?? []).filter { $0.objectValue != nil }
        let thumbnail = thumbnailOf(node)
        if let browse = node.path("navigationEndpoint", "browseEndpoint"), browse.objectValue != nil {
            guard let browseId = browse.str("browseId") else { return nil }
            return .collection(MusicCollection(browseId: browseId, kind: kindOf(browse, browseId), title: title, subtitle: second.asText(),
                                               thumbnailUrl: thumbnail, playlistId: node.findFirst("watchPlaylistEndpoint").str("playlistId")))
        }
        guard let videoId = node.path("playlistItemData").str("videoId") ?? node.findFirst("watchEndpoint").str("videoId") else { return nil }
        var artists = nonEmpty(runs.filter { artistPages.contains(pageType($0) ?? "") }.map { $0.str("text") ?? "" }.joined(separator: ", "))
        let album = runs.first { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }?.str("text")
        if artists == nil { artists = artistsFrom(second.asText()) }
        let fixed: String? = node.arr("fixedColumns")?.first.flatMap { $0.findFirst("text").asText() }
        let fromColumns: String? = columns.dropFirst().compactMap { $0.asText() }
            .flatMap { $0.components(separatedBy: " • ") }.first { isDuration($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let durationText = fixed ?? fromColumns
        return .song(MusicSong(
            videoId: videoId, title: title, artists: artists, album: album, thumbnailUrl: thumbnail,
            durationSeconds: durationText.flatMap(parseDuration), playlistId: node.findFirst("watchEndpoint").str("playlistId"),
            artistBrowseId: browseIdOf(runs) { artistPages.contains($0 ?? "") },
            albumBrowseId: browseIdOf(runs) { $0 == "MUSIC_PAGE_TYPE_ALBUM" }))
    }

    private static func card(_ node: JSON) -> MusicItem? {
        guard let title = node.text("title") else { return nil }
        let thumbnail = thumbnailOf(node)
        let subtitle = node.text("subtitle")
        var tap = node.obj("onTap")
        if tap == nil, let t = node.path("title", "runs", 0, "navigationEndpoint"), t.objectValue != nil { tap = t }
        if let videoId = tap.obj("watchEndpoint").str("videoId") {
            return .song(MusicSong(videoId: videoId, title: title, artists: artistsFrom(subtitle), album: nil, thumbnailUrl: thumbnail, durationSeconds: nil))
        }
        guard let browse = tap.obj("browseEndpoint"), let browseId = browse.str("browseId") else { return nil }
        return .collection(MusicCollection(browseId: browseId, kind: kindOf(browse, browseId), title: title, subtitle: subtitle, thumbnailUrl: thumbnail))
    }

    private static func panelSong(_ node: JSON) -> MusicSong? {
        guard let videoId = node.str("videoId"), let title = node.text("title") else { return nil }
        let byline = node.text("longBylineText") ?? node.text("shortBylineText")
        let parts = byline?.components(separatedBy: " • ") ?? []
        // Verlinkte Läufe sind eindeutig; sonst Text „Interpret • Album • Jahr“ (Aufrufe/Likes sind kein Album).
        let runs = (node.obj("longBylineText").arr("runs") ?? []).filter { $0.objectValue != nil }
        let linkedArtists = nonEmpty(runs.filter { artistPages.contains(pageType($0) ?? "") }.map { $0.str("text") ?? "" }.joined(separator: ", "))
        let linkedAlbum = runs.first { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }?.str("text")
        var album = linkedAlbum
        if album == nil, linkedArtists == nil, parts.count > 1 {
            let part = parts[1]
            let blank = part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let digits = part.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber }
            let banned = notAlbum.contains { part.range(of: $0, options: .caseInsensitive) != nil }
            if !blank && !digits && !banned { album = part }
        }
        let firstPart = parts.first.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return MusicSong(
            videoId: videoId, title: title, artists: linkedArtists ?? firstPart, album: album,
            thumbnailUrl: node.obj("thumbnail").arr("thumbnails").bestThumbnailUrl(544),
            durationSeconds: node.text("lengthText").flatMap(parseDuration),
            artistBrowseId: browseIdOf(runs) { artistPages.contains($0 ?? "") },
            albumBrowseId: browseIdOf(runs) { $0 == "MUSIC_PAGE_TYPE_ALBUM" })
    }

    private static func thumbnailOf(_ node: JSON) -> String? {
        let primary = node.findFirst("musicThumbnailRenderer").obj("thumbnail") ?? node.obj("thumbnail")
        return primary.arr("thumbnails").bestThumbnailUrl(544)
            ?? node.findFirst("croppedSquareThumbnailRenderer").obj("thumbnail").arr("thumbnails").bestThumbnailUrl(544)
    }

    private static func browseIdOf(_ runs: [JSON], _ matches: (String?) -> Bool) -> String? {
        runs.first { matches(pageType($0)) }?.path("navigationEndpoint", "browseEndpoint").str("browseId")
    }

    private static func pageType(_ run: JSON) -> String? {
        run.path("navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig").str("pageType")
    }

    private static func kindOf(_ browse: JSON, _ browseId: String) -> MusicCollection.Kind {
        let type = browse.path("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig").str("pageType")
        if (type.map { artistPages.contains($0) } ?? false) || browseId.hasPrefix("UC") { return .artist }
        if type == "MUSIC_PAGE_TYPE_ALBUM" || type == "MUSIC_PAGE_TYPE_AUDIOBOOK" || browseId.hasPrefix("MPRE") { return .album }
        return .playlist
    }

    /// „Song • Interpret • 3,2 Mio. Aufrufe“ → „Interpret“; reine Typ-Wörter fallen weg.
    private static func artistsFrom(_ subtitle: String?) -> String? {
        let parts = (subtitle?.components(separatedBy: " • ") ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.first { !typeWords.contains($0.lowercased()) && !isDuration($0) && !$0.contains("Aufrufe") && !$0.contains("views") }
    }

    /// `^\d{1,2}(:\d{2}){1,2}$` (nur ASCII-Ziffern wie in Kotlin).
    static func isDuration(_ s: String) -> Bool {
        let groups = s.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count == 2 || groups.count == 3 else { return false }
        for (i, g) in groups.enumerated() {
            let ok = g.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            if !ok || (i == 0 ? !(1...2).contains(g.utf8.count) : g.utf8.count != 2) { return false }
        }
        return true
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

public enum MusicCover {
    /// YouTube-Music-Cover (`…googleusercontent.com/…=w544-h544…`) in 1200 px; andere Adressen unverändert.
    public static func hiRes(_ url: String?) -> String? {
        guard let url else { return nil }
        guard url.contains("googleusercontent.com") else { return url }
        return url.replacingOccurrences(of: "=w[0-9]+-h[0-9]+", with: "=w1200-h1200", options: .regularExpression)
    }
}
