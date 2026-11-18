import XCTest
@testable import GuevenCore

final class LiveChatSessionTests: XCTestCase {
    private func page(ids: [String], next: String?, timeout: Int64 = 3500) -> JSON {
        let actions = ids.map { #"{"addChatItemAction":{"item":{"liveChatTextMessageRenderer":{"id":"\#($0)","authorName":{"simpleText":"A"},"message":{"runs":[{"text":"t\#($0)"}]}}}}}"# }.joined(separator: ",")
        let cont = next.map { #""continuations":[{"timedContinuationData":{"continuation":"\#($0)","timeoutMs":\#(timeout)}}],"# } ?? ""
        return try! JSONParser.parse(#"{"continuationContents":{"liveChatContinuation":{\#(cont)"actions":[\#(actions)]}}}"#)
    }

    private actor Recorder {
        var tokens: [String] = []; var sleeps: [Int64] = []; var updates: [[String]] = []
        func token(_ t: String) { tokens.append(t) }
        func sleep(_ ms: Int64) { sleeps.append(ms) }
        func update(_ m: [ChatMessage]) { updates.append(m.map(\.id)) }
    }

    func testFollowsContinuationDedupesAndClampsDelay() async {
        let rec = Recorder()
        let pages: [String: JSON] = [
            "T0": page(ids: ["a", "b"], next: "T1", timeout: 100),
            "T1": page(ids: ["b", "c"], next: "T2", timeout: 99_000),
            "T2": page(ids: [], next: nil),
        ]
        await LiveChatSession(startToken: "T0").run(
            fetch: { t in await rec.token(t); return pages[t]! },
            sleep: { await rec.sleep($0) },
            onUpdate: { await rec.update($0) })
        let tokens = await rec.tokens, sleeps = await rec.sleeps, updates = await rec.updates
        XCTAssertEqual(tokens, ["T0", "T1", "T2"])
        XCTAssertEqual(sleeps, [1_000, 10_000])
        XCTAssertEqual(updates, [["a", "b"], ["a", "b", "c"], ["a", "b", "c"]])
    }

    func testKeepsOnlyLast50Messages() async {
        let rec = Recorder()
        let ids = (0..<60).map { "m\($0)" }
        await LiveChatSession(startToken: "T").run(
            fetch: { _ in self.page(ids: ids, next: nil) }, sleep: { _ in }, onUpdate: { await rec.update($0) })
        let last = await rec.updates.last
        XCTAssertEqual(last?.count, 50)
        XCTAssertEqual(last?.first, "m10")
        XCTAssertEqual(last?.last, "m59")
    }

    func testStopsAfterFiveConsecutiveFailuresWithGrowingBackoff() async {
        struct Boom: Error {}
        let rec = Recorder()
        await LiveChatSession(startToken: "T").run(
            fetch: { t in await rec.token(t); throw Boom() }, sleep: { await rec.sleep($0) }, onUpdate: { _ in XCTFail("kein Update erwartet") })
        let sleeps = await rec.sleeps, tokens = await rec.tokens
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(sleeps, [2_000, 4_000, 6_000, 8_000])
    }

    func testFailureCounterResetsAfterSuccess() async {
        struct Boom: Error {}
        let rec = Recorder()
        let calls = Counter()
        await LiveChatSession(startToken: "T0").run(
            fetch: { t in
                let n = await calls.next()
                if n == 1 || n == 2 { throw Boom() }
                return n == 3 ? self.page(ids: ["x"], next: "T1") : self.page(ids: [], next: nil)
            },
            sleep: { await rec.sleep($0) }, onUpdate: { await rec.update($0) })
        let updates = await rec.updates
        XCTAssertEqual(updates.count, 2)
    }

    private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
}
