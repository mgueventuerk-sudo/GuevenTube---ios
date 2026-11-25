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
    /// Streaming-Token je visitorData. Überlebt das Freigeben des Generators nach Leerlauf (sonst baut die erste Wiedergabe nach
    /// 20 Minuten Pause BotGuard neu auf), gilt aber nur [streamingLifetime] lang.
    private var streaming: (visitorData: String, token: String, mintedAt: Date)?
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
    /// Wie lange YouTube den Streaming-Token annimmt, ist nicht dokumentiert; eine Stunde ist bewusst vorsichtig.
    private let streamingLifetime: TimeInterval = 60 * 60

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

    /// Nur der Streaming-Token (`pot` an Stream-URLs). Aus dem Zwischenspeicher sofort, sonst einmal prägen.
    func streamingTokens(visitorData: String?) async -> PoTokens? {
        guard let visitorData, !visitorData.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let s = validStreaming(visitorData) { status = "Streaming-Token aus Zwischenspeicher (0 ms)"; return PoTokens(player: "", streaming: s, generated: true) }
        if Date() < pausedUntil { status = "pausiert nach Fehlern"; return nil }
        let started = Date()
        do {
            let token = try await withTimeout(timeout) { try await self.mintStreaming(visitorData: visitorData, allowRecreate: true) }
            failures = 0
            status = "Streaming-Token ok (\(Int(Date().timeIntervalSince(started) * 1000)) ms)"
            scheduleRelease()
            return PoTokens(player: "", streaming: token, generated: true)
        } catch {
            failures += 1
            status = "Fehler: \((error as? PoTokenError)?.message ?? String(describing: type(of: error)))"
            if failures >= maxFailures { pausedUntil = Date().addingTimeInterval(pause); failures = 0 }
            await dropGenerator()
            return nil
        }
    }

    private func validStreaming(_ visitorData: String) -> String? {
        guard let s = streaming, s.visitorData == visitorData, Date().timeIntervalSince(s.mintedAt) < streamingLifetime else { return nil }
        return s.token
    }

    private func mintStreaming(visitorData: String, allowRecreate: Bool) async throws -> String {
        if let s = validStreaming(visitorData) { return s }
        let current = try await currentGenerator()
        do {
            let token = try await current.mint(visitorData)
            streaming = (visitorData, token, Date())
            return token
        } catch {
            await dropGenerator()
            if !allowRecreate { throw error }
            return try await mintStreaming(visitorData: visitorData, allowRecreate: false)
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
            if let s = validStreaming(visitorData) { streamingToken = s } else {
                streamingToken = try await current.mint(visitorData)
                streaming = (visitorData, streamingToken, Date())
            }
            let playerToken = try await current.mint(videoId)
            return PoTokens(player: playerToken, streaming: streamingToken, generated: true)
        } catch {
            await dropGenerator()
            if !allowRecreate { throw error }
            return try await mintAll(videoId: videoId, visitorData: visitorData, allowRecreate: false)
        }
    }

    /// Nach einem Fehler: Generator und Streaming-Token verwerfen (der Token könnte zum Fehler gehören).
    private func dropGenerator() async {
        await releaseGenerator()
        streaming = nil
    }

    /// Nach Leerlauf: nur den Generator (WebView) freigeben, der Streaming-Token bleibt gültig.
    private func releaseGenerator() async {
        if let g = generator { await g.close() }
        generator = nil
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        let delay = idleRelease
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.releaseGenerator()
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
