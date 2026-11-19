import Foundation
import GuevenCore

/// Verwaltet den BotGuard-Generator (Port von `PoTokenMinter.kt`):
/// - erst bei Bedarf erzeugt (oder per [warmUp] beim Start), nach [idleRelease] (20 Minuten) ohne Nutzung wieder freigegeben,
/// - neu erzeugt, wenn der Integritäts-Token abläuft oder ein Prägen scheitert (einmal),
/// - nach wiederholten Fehlschlägen [pause] lang aus,
/// - jede Anfrage höchstens [timeout]; danach `nil` → die App verhält sich wie ohne Token.
actor PoTokenMinter: PoTokenProviding {
    private let transport: HTTPTransport
    private var generator: WebViewPoTokenGenerator?
    private var streaming: (visitorData: String, token: String)?
    private var failures = 0
    private var pausedUntil = Date.distantPast
    private var releaseTask: Task<Void, Never>?
    /// Läuft gerade ein Aufbau, hängen sich weitere Aufrufer daran (sonst entstünden zwei WebViews: Vorwärmen + erste Wiedergabe).
    private var creating: Task<WebViewPoTokenGenerator, Error>?
    private(set) var status = "noch nicht benutzt"

    private let timeout: TimeInterval = 15
    private let idleRelease: TimeInterval = 20 * 60
    private let maxFailures = 2
    private let pause: TimeInterval = 10 * 60

    init(transport: HTTPTransport) { self.transport = transport }

    func tokens(videoId: String, visitorData: String?, generate: Bool) async -> PoTokens? {
        guard generate, let visitorData, !visitorData.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if Date() < pausedUntil { status = "pausiert nach Fehlern"; return nil }
        let started = Date()
        do {
            let result = try await withTimeout(timeout) { try await self.mintAll(videoId: videoId, visitorData: visitorData, allowRecreate: true) }
            failures = 0
            status = "ok (\(Int(Date().timeIntervalSince(started) * 1000)) ms)"
            scheduleRelease()
            return result
        } catch {
            failures += 1
            status = "Fehler: \((error as? PoTokenError)?.message ?? String(describing: type(of: error)))"
            if failures >= maxFailures { pausedUntil = Date().addingTimeInterval(pause); failures = 0 }
            await dropGenerator()
            return nil
        }
    }

    /// Baut den Generator im Hintergrund vor, damit die erste Wiedergabe nicht auf BotGuard wartet.
    func warmUp() async {
        guard generator == nil, Date() >= pausedUntil else { return }
        do {
            _ = try await withTimeout(timeout) { try await self.currentGenerator() }
            status = "bereit"
            scheduleRelease()
        } catch {
            status = "Vorwärmen fehlgeschlagen: \((error as? PoTokenError)?.message ?? String(describing: type(of: error)))"
            await dropGenerator()
        }
    }

    private func currentGenerator() async throws -> WebViewPoTokenGenerator {
        if let g = generator, await !g.isExpired { return g }
        if let running = creating { return try await running.value }
        await dropGenerator()
        let transport = self.transport
        let task = Task { try await WebViewPoTokenGenerator.create(transport: transport) }
        creating = task
        defer { creating = nil }
        let g = try await task.value
        generator = g
        return g
    }

    private func mintAll(videoId: String, visitorData: String, allowRecreate: Bool) async throws -> PoTokens {
        let current = try await currentGenerator()
        do {
            let streamingToken: String
            if let s = streaming, s.visitorData == visitorData { streamingToken = s.token } else {
                streamingToken = try await current.mint(visitorData)
                streaming = (visitorData, streamingToken)
            }
            let playerToken = try await current.mint(videoId)
            return PoTokens(player: playerToken, streaming: streamingToken, generated: true)
        } catch {
            await dropGenerator()
            if !allowRecreate { throw error }
            return try await mintAll(videoId: videoId, visitorData: visitorData, allowRecreate: false)
        }
    }

    private func dropGenerator() async {
        if let g = generator { await g.close() }
        generator = nil
        streaming = nil
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        let delay = idleRelease
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.dropGenerator()
        }
    }

    /// Gibt nach [seconds] auf, auch wenn [work] hängt (WebView-Rückrufe sind nicht abbrechbar; eine Task-Gruppe würde darauf warten).
    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = OnceGate()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let job = Task {
                do { let v = try await work(); if gate.take() { c.resume(returning: v) } }
                catch { if gate.take() { c.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.take() { job.cancel(); c.resume(throwing: PoTokenError("Zeitüberschreitung nach \(Int(seconds)) s")) }
            }
        }
    }
}

/// Lässt genau einen Aufrufer „gewinnen“.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
}
