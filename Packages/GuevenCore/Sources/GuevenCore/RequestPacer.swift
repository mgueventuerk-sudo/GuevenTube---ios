import Foundation

/// Hält zwischen aufeinanderfolgenden Anfragen einen Mindestabstand (plus Zufallszuschlag) ein, damit Sammel-Downloads
/// nicht wie ein Skript aussehen. Die Wartezeit wird vor dem Start der Anfrage eingelegt; die erste Anfrage startet sofort.
public actor RequestPacer {
    private let minGapMs: Int64
    private let jitterMs: Int64
    private let nowMs: @Sendable () -> Int64
    private let sleepMs: @Sendable (Int64) async -> Void
    private let random: @Sendable (Int64) -> Int64
    private var nextFreeAt: Int64 = 0

    public init(minGapMs: Int64 = 4_000, jitterMs: Int64 = 2_000,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleepMs: @escaping @Sendable (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                random: @escaping @Sendable (Int64) -> Int64 = { $0 > 0 ? Int64.random(in: 0...$0) : 0 }) {
        self.minGapMs = minGapMs; self.jitterMs = jitterMs; self.nowMs = nowMs; self.sleepMs = sleepMs; self.random = random
    }

    /// Reserviert den nächsten Startplatz und wartet bis dahin (Aufrufer werden der Reihe nach bedient).
    public func wait() async {
        let now = nowMs()
        let slot = max(now, nextFreeAt)
        nextFreeAt = slot + minGapMs + random(jitterMs)
        if slot > now { await sleepMs(slot - now) }
    }
}
