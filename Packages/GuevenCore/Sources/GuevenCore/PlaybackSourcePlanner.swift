import Foundation

/// Was AVPlayer abspielen soll. AVPlayer spielt weder DASH noch WebM/VP9/Opus zuverlässig: gewählt wird nur H.264/AAC in MP4,
/// getrennte Bild-/Tonströme werden in der App-Schicht per `AVMutableComposition` zusammengesetzt.
public enum PlaybackSource: Equatable, Sendable {
    /// Live oder reiner HLS-Weg.
    case hls(url: String)
    /// Ein Strom mit Bild und Ton (muxed).
    case progressive(url: String, height: Int?)
    /// Bild- und Tonstrom getrennt (höhere Auflösung als muxed).
    case separate(videoUrl: String, audioUrl: String, height: Int)
    /// Nur Ton (Musik, Hintergrund, Datensparen).
    case audioOnly(url: String)

    public var isAudioOnly: Bool { if case .audioOnly = self { return true } else { return false } }
}

/// Weitere spielbare Quelle, falls der Server die beste ablehnt (absteigend nach Qualität).
public struct PlaybackAlternative: Equatable, Sendable {
    public var source: PlaybackSource
    public var label: String
}

public struct PlaybackPlan: Equatable, Sendable {
    public var source: PlaybackSource
    /// Anzeige, z. B. „720p“, „HLS“, „Nur Ton“.
    public var qualityLabel: String
    /// googlevideo erwartet den User-Agent des Abspielwegs.
    public var userAgent: String
    /// Läuft ohne entschlüsseltes `n`: wird gedrosselt.
    public var throttled: Bool
    public var isLive: Bool
    /// HLS-Adresse als Notweg: Scheitert das Zusammensetzen von Bild und Ton oder das Laden eines Einzelstroms auf dem Gerät,
    /// spielt der Player stattdessen den HLS-Strom (AVPlayer kann ihn nativ).
    public var hlsFallbackUrl: String? = nil
    /// Welcher Abspielweg die Adressen geliefert hat (für die Fehleranzeige), z. B. „TV (Samsung) · Konto“.
    public var clientLabel: String = ""
    /// Zusätzliche/abweichende Kopfzeilen für die Stream-Anfragen (vom Adress-Test ermittelt, wenn der Standard abgelehnt wird).
    public var extraHeaders: [String: String] = [:]
    /// Schlechtere Stufen als Notweg: manche Stufen lehnt der Videoserver ab, andere nicht.
    public var ladder: [PlaybackAlternative] = []
}

public struct PlaybackPlanError: Error, Equatable, Sendable { public let message: String; public init(_ m: String) { message = m } }

/// Wahl der Quelle aus einer aufgelösten Wiedergabe. Reine Funktion.
public enum PlaybackSourcePlanner {
    /// - Parameters:
    ///   - maxHeight: Obergrenze der Bildhöhe (Einstellung/Kanal/Mobilfunk); `nil` = unbegrenzt.
    ///   - audioOnly: nur Ton abspielen.
    public static func plan(_ playback: ResolvedPlayback, maxHeight: Int? = nil, audioOnly: Bool = false) throws -> PlaybackPlan {
        var p = try basePlan(playback, maxHeight: maxHeight, audioOnly: audioOnly)
        if !audioOnly && !p.isLive { p.ladder = alternatives(playback, excluding: p.source) }
        return p
    }

    /// Alle weiteren Stufen (je Höhe eine, höchste zuerst, höchstens 6): getrennt mit AAC-Ton oder muxed H.264.
    static func alternatives(_ playback: ResolvedPlayback, excluding primary: PlaybackSource) -> [PlaybackAlternative] {
        let adaptive = playback.adaptiveFormats.filter { hasUrl($0) }
        let muxed = playback.muxedFormats.filter { hasUrl($0) && $0.containerMimeType == "video/mp4" && $0.codecs.contains("avc1") }
        let aac = DownloadQualityResolver.commonAudio(adaptive).max(by: { rate($0) < rate($1) })
        var byHeight: [Int: PlaybackAlternative] = [:]
        for v in DownloadQualityResolver.commonVideo(adaptive) where (v.height ?? 0) > 0 {
            guard let url = v.url, let aac, let aUrl = aac.url else { continue }
            let h = v.height ?? 0
            let cand = PlaybackAlternative(source: .separate(videoUrl: url, audioUrl: aUrl, height: h), label: label(v))
            if byHeight[h] == nil { byHeight[h] = cand }
        }
        // Muxed hat Vorrang bei gleicher Höhe: ein Strom statt zwei, kein Zusammensetzen.
        for m in muxed {
            guard let url = m.url else { continue }
            byHeight[m.height ?? 0] = PlaybackAlternative(source: .progressive(url: url, height: m.height), label: label(m))
        }
        return byHeight.keys.sorted(by: >).compactMap { byHeight[$0] }.filter { $0.source != primary }.prefix(6).map { $0 }
    }

    static func basePlan(_ playback: ResolvedPlayback, maxHeight: Int? = nil, audioOnly: Bool = false) throws -> PlaybackPlan {
        let data = playback.playerData
        let live = data.details?.isLive ?? false
        let hls = (data.hlsManifestUrl ?? "").trimmingCharacters(in: .whitespaces)
        func make(_ source: PlaybackSource, _ label: String) -> PlaybackPlan {
            var plan = PlaybackPlan(source: source, qualityLabel: label, userAgent: playback.userAgent, throttled: playback.throttlingUnsolved, isLive: live)
            plan.clientLabel = playback.clientLabel
            if case .hls = source {} else if !hls.isEmpty { plan.hlsFallbackUrl = hls }
            return plan
        }

        // Live: HLS ist der einzige Weg, der ohne Segmentindex funktioniert.
        if live {
            guard !hls.isEmpty else { throw PlaybackPlanError("Live-Stream ohne HLS-Adresse") }
            return make(.hls(url: hls), "Live")
        }

        let adaptive = playback.adaptiveFormats.filter { hasUrl($0) }
        let muxed = playback.muxedFormats.filter { hasUrl($0) && $0.containerMimeType == "video/mp4" && $0.codecs.contains("avc1") }
        let aac = DownloadQualityResolver.commonAudio(adaptive).max(by: { rate($0) < rate($1) })

        if audioOnly {
            if let aac, let url = aac.url { return make(.audioOnly(url: url), "Nur Ton") }
            // Kein AAC: der Ton des schlechtesten muxed-Stroms ist spielbar, WebM/Opus nicht.
            if let m = muxed.min(by: { ($0.height ?? 0) < ($1.height ?? 0) }), let url = m.url { return make(.progressive(url: url, height: m.height), "Nur Ton") }
            if !hls.isEmpty { return make(.hls(url: hls), "HLS") }
            throw PlaybackPlanError("Kein abspielbarer Tonstrom (nur WebM/Opus)")
        }

        let limit = maxHeight ?? Int.max
        let videos = DownloadQualityResolver.commonVideo(adaptive).filter { ($0.height ?? 0) > 0 }
        let bestMuxed = muxed.filter { ($0.height ?? 0) <= limit }.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
        let bestVideo = videos.filter { ($0.height ?? 0) <= limit }
            .sorted { ($0.height ?? 0, $0.fps ?? 0, rate($0)) < ($1.height ?? 0, $1.fps ?? 0, rate($1)) }.last

        // Getrennt nur, wenn es wirklich höher auflöst als der beste muxed-Strom und ein AAC-Ton da ist.
        if let v = bestVideo, let vUrl = v.url, let aac, let aUrl = aac.url, (v.height ?? 0) > (bestMuxed?.height ?? 0) {
            return make(.separate(videoUrl: vUrl, audioUrl: aUrl, height: v.height ?? 0), label(v))
        }
        if let m = bestMuxed, let url = m.url { return make(.progressive(url: url, height: m.height), label(m)) }
        // Nur Streams über der Grenze vorhanden: lieber die niedrigste Stufe als gar nichts.
        if let v = videos.min(by: { ($0.height ?? 0) < ($1.height ?? 0) }), let vUrl = v.url, let aac, let aUrl = aac.url {
            return make(.separate(videoUrl: vUrl, audioUrl: aUrl, height: v.height ?? 0), label(v))
        }
        if let m = muxed.min(by: { ($0.height ?? 0) < ($1.height ?? 0) }), let url = m.url { return make(.progressive(url: url, height: m.height), label(m)) }
        if !hls.isEmpty { return make(.hls(url: hls), "HLS") }
        throw PlaybackPlanError("Kein auf dem iPhone abspielbarer Strom (nur VP9/AV1/WebM)")
    }

    private static func hasUrl(_ f: StreamFormat) -> Bool { !(f.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func rate(_ f: StreamFormat) -> Int64 { f.averageBitrate ?? f.bitrate }
    private static func label(_ f: StreamFormat) -> String { f.qualityLabel ?? f.height.map { "\($0)p" } ?? "Video" }
}
