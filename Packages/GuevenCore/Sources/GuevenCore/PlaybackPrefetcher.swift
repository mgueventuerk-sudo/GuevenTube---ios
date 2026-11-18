import Foundation

/// Sofortstart: löst Videos auf, bevor sie gestartet werden.
/// - `likely`: Der Nutzer tippt gerade darauf – wird immer und zuerst geladen.
/// - `speculative`: Karte länger sichtbar/markiert – nur ohne getaktete Verbindung (WLAN).
/// Es wird nur die Player-Antwort geholt (wenige KB), keine Videodaten. Höchstens eine Auflösung gleichzeitig; neue Wünsche
/// verdrängen ältere (1 wahrscheinlicher, 2 spekulative), damit beim schnellen Blättern nichts aufläuft.
public actor PlaybackPrefetcher {
    public enum Intent: Sendable { case likely, speculative }

    static let speculativeQueue = 2
    static let recentSize = 64
    static let repeatIntervalMs: Int64 = 10 * 60 * 1000
    static let prefetchTimeoutMs: Int64 = 20_000
    /// Markierte Karten laden Mediendaten erst nach kurzer Verweildauer, angetippte sofort.
    public static let mediaDwellMs: Int64 = 1_100

    private let isCached: @Sendable (String) async -> Bool
    private let prefetch: @Sendable (String) async -> Bool
    private let instantStartEnabled: @Sendable () async -> Bool
    private let isMetered: @Sendable () async -> Bool
    private let afterResolved: @Sendable (String, Int64) async -> Void
    private let nowMs: @Sendable () -> Int64

    private var likely: [String] = []
    private var speculative: [String] = []
    private var recent = LRUCache<Int64>(capacity: PlaybackPrefetcher.recentSize)
    private var worker: Task<Void, Never>?
    private var sleeper: CheckedContinuation<Void, Never>?
    private var busy = false

    /// `afterResolved(videoId, dwellMs)` läuft nur nach erfolgreicher Auflösung (iOS: Medien vorladen).
    public init(isCached: @escaping @Sendable (String) async -> Bool, prefetch: @escaping @Sendable (String) async -> Bool,
                instantStartEnabled: @escaping @Sendable () async -> Bool, isMetered: @escaping @Sendable () async -> Bool,
                afterResolved: @escaping @Sendable (String, Int64) async -> Void = { _, _ in },
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.isCached = isCached; self.prefetch = prefetch; self.instantStartEnabled = instantStartEnabled; self.isMetered = isMetered
        self.afterResolved = afterResolved; self.nowMs = nowMs
    }

    public func request(_ videoId: String, intent: Intent) async {
        if await isCached(videoId) { return }
        let now = nowMs()
        if intent == .speculative, let last = recent.get(videoId), now - last < Self.repeatIntervalMs { return }
        guard await instantStartEnabled() else { return }
        if intent == .speculative, await isMetered() { return }
        recent.put(videoId, now)
        switch intent {
        case .likely: likely = [videoId]
        case .speculative:
            speculative.append(videoId)
            if speculative.count > Self.speculativeQueue { speculative.removeFirst() }
        }
        startWorkerIfNeeded()
        sleeper?.resume(); sleeper = nil
    }

    public func stop() { worker?.cancel(); worker = nil; likely = []; speculative = []; sleeper?.resume(); sleeper = nil }

    /// Wartet, bis nichts mehr ansteht oder läuft (für Tests).
    public func waitUntilIdle() async {
        while busy || !likely.isEmpty || !speculative.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let (id, isLikely) = await self.next() else { await self.waitForWork(); continue }
                await self.process(id, isLikely: isLikely)
            }
        }
    }

    private func next() -> (String, Bool)? {
        if !likely.isEmpty { busy = true; return (likely.removeFirst(), true) }
        if !speculative.isEmpty { busy = true; return (speculative.removeFirst(), false) }
        return nil
    }

    private func waitForWork() async {
        if !likely.isEmpty || !speculative.isEmpty { return }
        await withCheckedContinuation { sleeper = $0 }
    }

    private func process(_ id: String, isLikely: Bool) async {
        let resolved = await withTimeout(Self.prefetchTimeoutMs) { await self.prefetch(id) } ?? false
        if resolved { await afterResolved(id, isLikely ? 0 : Self.mediaDwellMs) }
        busy = false
    }

    private func withTimeout<T: Sendable>(_ ms: Int64, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await body() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}
