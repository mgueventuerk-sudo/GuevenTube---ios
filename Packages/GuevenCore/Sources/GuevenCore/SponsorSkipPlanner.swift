import Foundation

public enum SponsorSkipAction: Equatable, Sendable {
    case none
    /// Automatisch zum Segmentende springen.
    case seek(toMs: Int64, segment: SponsorSegment)
    case showPrompt(SponsorSegment)
    case hidePrompt
}

/// Entscheidet je Positions-Meldung (ca. 4 Hz) über SponsorBlock-Aktionen. Port von `SponsorSkipScheduler.kt` ohne Player:
/// Android plant `PlayerMessage`s, hier wird abgefragt – dadurch reine, testbare Logik (Sprung bis zu einem Tick zu spät).
///
/// - `autoSkip`: beim Betreten springen; nach einem Sprung des Nutzers in das Segment nur der Knopf (er wollte dorthin).
/// - `manualSkip`: Knopf beim Betreten, 5 s bzw. bis Segmentende sichtbar.
/// - Verlässt die Position das Segment, verschwindet der Knopf; erneutes Betreten zeigt ihn wieder.
public struct SponsorSkipPlanner: Sendable {
    public static let promptDurationMs: Int64 = 5_000
    public static let toleranceMs: Int64 = 250
    /// Größere Positionssprünge zwischen zwei Meldungen gelten als Spulen des Nutzers.
    public static let seekJumpMs: Int64 = 2_000

    private let segments: [SponsorSegment]
    private let enabled: Bool
    private let mode: @Sendable (SponsorCategory) -> SkipMode
    private var lastPositionMs: Int64?
    private var prompt: SponsorSegment?
    private var promptHideAtMs: Int64?
    /// Segment, dessen Knopf schon ausgeblendet wurde, solange die Position darin bleibt.
    private var dismissed: String?

    public init(segments: [SponsorSegment], enabled: Bool, mode: @escaping @Sendable (SponsorCategory) -> SkipMode) {
        self.segments = segments.sorted { $0.startMs < $1.startMs }
        self.enabled = enabled; self.mode = mode
    }

    public var activePrompt: SponsorSegment? { prompt }

    /// Nutzer drückt „Überspringen“: Ziel oder `nil`, wenn kein Knopf sichtbar ist.
    public mutating func skipPrompted() -> Int64? {
        guard let p = prompt else { return nil }
        prompt = nil; promptHideAtMs = nil; dismissed = p.uuid
        return p.endMs
    }

    public mutating func update(positionMs: Int64) -> SponsorSkipAction {
        defer { lastPositionMs = positionMs }
        guard enabled else { return hide() }
        let last = lastPositionMs
        let userSeek = last.map { positionMs < $0 || positionMs - $0 > Self.seekJumpMs } ?? false
        guard let seg = segments.first(where: { positionMs >= $0.startMs && positionMs < $0.endMs - Self.toleranceMs }) else {
            dismissed = nil
            return hide()
        }
        if dismissed == seg.uuid { return hide() }
        switch mode(seg.category) {
        case .autoSkip:
            if !userSeek { prompt = nil; promptHideAtMs = nil; dismissed = seg.uuid; return .seek(toMs: seg.endMs, segment: seg) }
            return showOrKeep(seg, positionMs)
        case .manualSkip:
            return showOrKeep(seg, positionMs)
        case .showInSeekbar, .disabled:
            return hide()
        }
    }

    private mutating func showOrKeep(_ seg: SponsorSegment, _ positionMs: Int64) -> SponsorSkipAction {
        if prompt?.uuid == seg.uuid {
            if let hideAt = promptHideAtMs, positionMs >= hideAt { prompt = nil; promptHideAtMs = nil; dismissed = seg.uuid; return .hidePrompt }
            return .none
        }
        prompt = seg
        promptHideAtMs = min(positionMs + Self.promptDurationMs, seg.endMs)
        return .showPrompt(seg)
    }

    private mutating func hide() -> SponsorSkipAction {
        guard prompt != nil else { return .none }
        prompt = nil; promptHideAtMs = nil
        return .hidePrompt
    }
}
