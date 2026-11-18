import Foundation

/// Live-Chat-Abruf (Port von `LiveChatRepository`): Der Server gibt per `timeoutMs` den nächsten Abruf vor
/// (mindestens 1 s, höchstens 10 s); gesammelt werden die letzten 50 Nachrichten, nach 5 Fehlern in Folge endet die Sitzung.
public struct LiveChatSession: Sendable {
    public static let maxMessages = 50
    public static let maxSeenIds = 2_000
    public static let maxFailures = 5
    public static let retryDelayMs: Int64 = 2_000
    public static let minPollMs: Int64 = 1_000
    public static let maxPollMs: Int64 = 10_000

    public typealias Next = @Sendable (String) async throws -> JSON
    public typealias Fetch = @Sendable (String) async throws -> JSON
    public typealias Sleep = @Sendable (Int64) async throws -> Void

    private let startToken: String

    public init(startToken: String) { self.startToken = startToken }

    /// Läuft, bis der Task abgebrochen wird, kein Token mehr kommt oder zu viele Fehler auftreten.
    /// `onUpdate` bekommt nach jedem erfolgreichen Abruf die letzten Nachrichten.
    public func run(fetch: Fetch, sleep: Sleep, onUpdate: @Sendable ([ChatMessage]) async -> Void) async {
        var token = startToken
        var buffer: [ChatMessage] = []
        var seen = Set<String>()
        var failures = 0
        while !Task.isCancelled {
            let batch: ChatBatch
            do {
                batch = CommunityParser.parseLiveChat(try await fetch(token))
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                if failures >= Self.maxFailures { return }
                do { try await sleep(Self.retryDelayMs * Int64(failures)) } catch { return }
                continue
            }
            for m in batch.messages where seen.insert(m.id).inserted {
                buffer.append(m)
                if buffer.count > Self.maxMessages { buffer.removeFirst() }
            }
            if seen.count > Self.maxSeenIds { seen.removeAll() }
            await onUpdate(buffer)
            guard let next = batch.continuation else { return }
            token = next
            do { try await sleep(min(max(batch.timeoutMs, Self.minPollMs), Self.maxPollMs)) } catch { return }
        }
    }
}
