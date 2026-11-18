import Foundation

/// Gemeinsam schauen (Labor, Standard aus): Das Handy spielt dasselbe Video wie der gekoppelte Fernseher und folgt ihm
/// (Video, Position, Pause). Der Fernseher führt. Nur über die bestehende verschlüsselte Kopplung.
public enum WatchTogether {
    public enum Step: Equatable, Sendable {
        case open(videoId: String, positionMs: Int64)
        case seekTo(positionMs: Int64)
        case setPlaying(Bool)
    }

    public static let toleranceMs: Int64 = 2_000
    public static let latencyMs: Int64 = 600

    /// Was das Handy tun soll, um dem Fernseher zu folgen (rein).
    public static func plan(tv: LinkPlayerState, localVideoId: String?, localPositionMs: Int64, localPlaying: Bool) -> [Step] {
        guard let videoId = tv.videoId else { return [] }
        if tv.isLive { return videoId != localVideoId ? [.open(videoId: videoId, positionMs: 0)] : [] }
        // Der TV meldet die Position auf volle Sekunden und mit Übertragungszeit: etwas Vorlauf einrechnen.
        let target = tv.positionMs + (tv.isPlaying ? latencyMs : 0)
        if videoId != localVideoId { return [.open(videoId: videoId, positionMs: target)] }
        var steps: [Step] = []
        if !tv.isBuffering && abs(localPositionMs - target) > toleranceMs { steps.append(.seekTo(positionMs: target)) }
        if !tv.isBuffering && tv.isPlaying != localPlaying { steps.append(.setPlaying(tv.isPlaying)) }
        return steps
    }
}
