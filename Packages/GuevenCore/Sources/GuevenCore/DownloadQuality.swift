import Foundation

public enum DownloadQuality: String, Codable, Sendable, CaseIterable {
    case audioOnly = "AUDIO_ONLY", sd = "SD", hd = "HD", fullHd = "FULL_HD", highest = "HIGHEST"

    public var label: String {
        switch self {
        case .audioOnly: return "Nur Ton"
        case .sd: return "Bis 480p"
        case .hd: return "720p"
        case .fullHd: return "1080p"
        case .highest: return "Höchste verfügbare"
        }
    }
    public var maxHeight: Int? {
        switch self {
        case .audioOnly: return nil
        case .sd: return 480
        case .hd: return 720
        case .fullHd: return 1080
        case .highest: return Int.max
        }
    }
}

public struct ResolvedDownloadFormats: Equatable, Sendable {
    public var videoFormat: StreamFormat?
    public var audioFormat: StreamFormat
    /// Anzeige-Label der tatsächlich gewählten Qualität (kann niedriger sein als gewünscht).
    public var qualityLabel: String
}

/// Wählt aus den Formaten einer `ResolvedPlayback` das zur gewünschten Qualität passende Bild- und Tonformat.
/// Reine Auswahl; bevorzugt H.264/AAC in MP4 (der Muxer packt nur das zuverlässig um).
public enum DownloadQualityResolver {
    public static func resolve(_ playback: ResolvedPlayback, quality: DownloadQuality) -> ResolvedDownloadFormats? {
        let adaptive = playback.adaptiveFormats.filter { !($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let audio = bestAudio(adaptive) else { return nil }
        guard let maxHeight = quality.maxHeight else {
            return ResolvedDownloadFormats(videoFormat: nil, audioFormat: audio, qualityLabel: DownloadQuality.audioOnly.label)
        }
        // Stabil sortiert nach Höhe, dann Bildrate (wie `sortedWith` in Kotlin).
        let sorted = commonVideo(adaptive).enumerated().sorted { a, b in
            let ka = (a.element.height ?? 0, a.element.fps ?? 0), kb = (b.element.height ?? 0, b.element.fps ?? 0)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        guard let lowest = sorted.first else { return nil }
        let video = sorted.last { ($0.height ?? 0) <= maxHeight } ?? lowest
        let label = video.qualityLabel ?? video.height.map { "\($0)p" } ?? quality.label
        return ResolvedDownloadFormats(videoFormat: video, audioFormat: audio, qualityLabel: label)
    }

    /// Nur H.264 in MP4.
    public static func commonVideo(_ formats: [StreamFormat]) -> [StreamFormat] {
        formats.filter { $0.isVideo && !$0.isOtf && ($0.height ?? 0) > 0 && $0.containerMimeType == "video/mp4" && $0.codecs.hasPrefix("avc1") }
    }

    /// Nur AAC in MP4 (m4a).
    public static func commonAudio(_ formats: [StreamFormat]) -> [StreamFormat] {
        formats.filter { $0.isAudio && !$0.isOtf && !$0.isDrc && $0.containerMimeType == "audio/mp4" && $0.codecs.hasPrefix("mp4a") }
    }

    /// Beste Tonspur: nicht DRC, bevorzugt AAC/MP4 vor Opus/WebM, höchste Bitrate innerhalb der Bevorzugung.
    public static func bestAudio(_ formats: [StreamFormat]) -> StreamFormat? {
        var candidates = formats.filter { $0.isAudio && !$0.isDrc }
        if candidates.isEmpty { candidates = formats.filter { $0.isAudio } }
        candidates = originalLanguage(candidates)
        return maxByBitrate(commonAudio(candidates)) ?? maxByBitrate(candidates)
    }

    /// Videos mit mehreren Tonspuren (automatische Synchronisation): Ohne Auswahl gewann die Spur mit der höchsten Bitrate – oft eine
    /// fremdsprachige. Vorrang hat die als Original markierte Spur (`acont=original`), sonst die Standardspur ohne „dubbed“-Marke.
    public static func originalLanguage(_ formats: [StreamFormat]) -> [StreamFormat] {
        func tags(_ f: StreamFormat) -> String { (f.xtags ?? "").lowercased() }
        let original = formats.filter { tags($0).contains("acont=original") }
        if !original.isEmpty { return original }
        let standard = formats.filter { $0.audioIsDefault && !tags($0).contains("dubbed") }
        if !standard.isEmpty { return standard }
        let notDubbed = formats.filter { !tags($0).contains("dubbed") }
        return notDubbed.isEmpty ? formats : notDubbed
    }

    /// Erstes Maximum (wie `maxByOrNull`).
    private static func maxByBitrate(_ formats: [StreamFormat]) -> StreamFormat? {
        var best: StreamFormat?
        for f in formats where best == nil || (f.averageBitrate ?? f.bitrate) > (best!.averageBitrate ?? best!.bitrate) { best = f }
        return best
    }
}
