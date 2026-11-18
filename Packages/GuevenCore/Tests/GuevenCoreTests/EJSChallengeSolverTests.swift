import XCTest
@testable import GuevenCore

private final class FakeEngine: JSEngine, @unchecked Sendable {
    private let lock = NSLock()
    var globals: [String: String] = [:]
    var evaluated: [String] = []
    var closed = false
    var solveResponse: String
    var failSolveWith: JSEngineError?
    init(solveResponse: String = "") { self.solveResponse = solveResponse }

    func setGlobal(_ name: String, string: String) async throws { lock.lock(); globals[name] = string; lock.unlock() }
    func evaluate(_ code: String, timeoutMs: Int64) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        evaluated.append(code)
        if code.hasPrefix("JSON.stringify(jsc(") {
            if let failSolveWith { throw failSolveWith }
            return solveResponse
        }
        if code == "__gtLoad(__gtPlayerSource)" { return globals["__gtPlayerSource"] == "BAD" ? "ERR:kaputt" : "ok" }
        if code == "globalThis.__gtPlayer" { return "PREPROCESSED" }
        return "ok"
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var solveCalls: Int { lock.lock(); defer { lock.unlock() }; return evaluated.filter { $0.hasPrefix("JSON.stringify(jsc(") }.count }
}

private let okResponse = #"{"type":"result","responses":[{"type":"result","data":{"aaa":"AAA","bbb":"BBB"}},{"type":"result","data":{"sss":"SSS"}}]}"#

final class EJSChallengeSolverTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ejs-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func solver(_ engines: @escaping @Sendable () -> FakeEngine, player: @escaping @Sendable (String) async throws -> String = { _ in "SRC" }, directory: URL?? = nil) -> EJSChallengeSolver {
        EJSChallengeSolver(directory: directory ?? dir, makeEngine: { engines() }, libSource: { "LIB" }, coreSource: { "CORE" }, playerScript: player)
    }

    func testSolvesAndCaches() async throws {
        let engine = FakeEngine(solveResponse: okResponse)
        let s = solver { engine }
        let r = try await s.solve(playerId: "abc12345", nChallenges: ["aaa", "bbb"], sigChallenges: ["sss"])
        XCTAssertEqual(r.n, ["aaa": "AAA", "bbb": "BBB"])
        XCTAssertEqual(r.sig, ["sss": "SSS"])
        // Zweiter Aufruf: komplett aus dem Zwischenspeicher, keine neue Engine-Anfrage.
        _ = try await s.solve(playerId: "abc12345", nChallenges: ["aaa"], sigChallenges: ["sss"])
        XCTAssertEqual(engine.solveCalls, 1)
    }

    func testRequestOnlyContainsOpenChallengesInOrder() async throws {
        let engine = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"zzz":"Z"}}]}"#)
        let s = solver { engine }
        _ = try await s.solve(playerId: "p1", nChallenges: ["zzz"], sigChallenges: [])
        let call = engine.evaluated.first { $0.hasPrefix("JSON.stringify(jsc(") }!
        XCTAssertTrue(call.contains("{\"type\":\"n\",\"challenges\":[\"zzz\"]}"))
        XCTAssertFalse(call.contains("\"type\":\"sig\""))
        XCTAssertTrue(call.contains("preprocessed_player:globalThis.__gtPlayer"))
    }

    func testPlayerLoadedOnceAndLibsOrder() async throws {
        let engine = FakeEngine(solveResponse: okResponse)
        let counter = Counter()
        let s = solver({ engine }, player: { _ in await counter.bump(); return "SRC" })
        _ = try await s.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: [])
        _ = try await s.solve(playerId: "p1", nChallenges: ["bbb"], sigChallenges: [])
        let loads = await counter.value
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(engine.evaluated[0].hasPrefix("LIB"))
        XCTAssertTrue(engine.evaluated[0].contains("Object.assign(globalThis, lib)"))
        XCTAssertTrue(engine.evaluated[1].hasPrefix("CORE"))
        XCTAssertEqual(engine.globals["__gtPlayerSource"], "SRC")
    }

    func testSolutionsSurviveRestartButOnlyForSamePlayer() async throws {
        let first = FakeEngine(solveResponse: okResponse)
        _ = try await solver { first }.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: ["sss"])
        let second = FakeEngine()
        let again = solver { second }
        let r = try await again.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: ["sss"])
        XCTAssertEqual(r.n["aaa"], "AAA")
        XCTAssertEqual(second.solveCalls, 0)
        // Anderer Player: gespeicherte Lösungen gelten nicht.
        let third = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"aaa":"NEU"}}]}"#)
        let other = try await solver { third }.solve(playerId: "p2", nChallenges: ["aaa"], sigChallenges: [])
        XCTAssertEqual(other.n["aaa"], "NEU")
    }

    func testPreprocessedPlayerIsStoredAndReused() async throws {
        let first = FakeEngine(solveResponse: okResponse)
        _ = try await solver { first }.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: [])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("preprocessed-p1.js")), "PREPROCESSED")
        // Neuer Solver, neue Challenge: Player-Skript wird nicht erneut geladen, analysierte Datei kommt von der Platte.
        let second = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"ccc":"C"}}]}"#)
        let counter = Counter()
        let s = solver({ second }, player: { _ in await counter.bump(); return "SRC" })
        _ = try await s.solve(playerId: "p1", nChallenges: ["ccc"], sigChallenges: [])
        let loads = await counter.value
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(second.globals["__gtPlayer"], "PREPROCESSED")
    }

    func testOnlyNewestPreprocessedFilesKept() async throws {
        for id in ["p1", "p2", "p3", "p4"] {
            let e = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"x":"y"}}]}"#)
            _ = try await solver { e }.solve(playerId: id, nChallenges: ["x"], sigChallenges: [])
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("preprocessed-") }
        XCTAssertEqual(files.count, EJSChallengeSolver.keepPreprocessedFiles)
        XCTAssertTrue(files.contains("preprocessed-p4.js"))
    }

    func testPlayerIdWithPathTricksIsNeverUsedAsFileName() async throws {
        let e = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"x":"y"}}]}"#)
        _ = try await solver { e }.solve(playerId: "../evil", nChallenges: ["x"], sigChallenges: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("preprocessed-../evil.js").path))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix("preprocessed-") })
    }

    func testTimeoutResetsEngineAndReportsError() async throws {
        let engine = FakeEngine()
        engine.failSolveWith = .timeout
        let engines = EngineBox([engine, FakeEngine(solveResponse: okResponse)])
        let s = solver { engines.next() }
        do { _ = try await s.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: []); XCTFail() }
        catch let e as SolverError { XCTAssertTrue(e.message.contains("Zeitlimit")) }
        XCTAssertTrue(engine.closed)
        let statusText = await s.status()
        XCTAssertTrue(statusText.hasPrefix("Fehler"))
        // Nächster Versuch legt eine neue Engine an und gelingt.
        let r = try await s.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: [])
        XCTAssertEqual(r.n["aaa"], "AAA")
    }

    func testBrokenPlayerAnalysisThrowsAndIsNotStored() async throws {
        let engine = FakeEngine()
        let s = solver({ engine }, player: { _ in "BAD" })
        do { _ = try await s.solve(playerId: "p1", nChallenges: ["aaa"], sigChallenges: []); XCTFail() }
        catch let e as SolverError { XCTAssertTrue(e.message.contains("Player-Analyse")) }
        XCTAssertTrue(engine.closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("preprocessed-p1.js").path))
    }

    func testErrorAndUnsolvableResponses() async throws {
        let err = FakeEngine(solveResponse: #"{"type":"error","error":"boom"}"#)
        do { _ = try await solver { err }.solve(playerId: "p1", nChallenges: ["a"], sigChallenges: []); XCTFail() }
        catch let e as SolverError { XCTAssertTrue(e.message.contains("boom")) }
        let bad = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"error","error":"nope"}]}"#)
        do { _ = try await solver({ bad }, directory: .some(nil)).solve(playerId: "p1", nChallenges: ["a"], sigChallenges: []); XCTFail() }
        catch let e as SolverError { XCTAssertTrue(e.message.contains("nope")) }
        let short = FakeEngine(solveResponse: #"{"type":"result","responses":[]}"#)
        do { _ = try await solver({ short }, directory: .some(nil)).solve(playerId: "p1", nChallenges: ["a"], sigChallenges: []); XCTFail() }
        catch is SolverError {}
    }

    func testParallelCallsAreSerialized() async throws {
        let engine = FakeEngine(solveResponse: #"{"type":"result","responses":[{"type":"result","data":{"x":"y"}}]}"#)
        let counter = Counter()
        let s = solver({ engine }, player: { _ in await counter.bump(); try await Task.sleep(nanoseconds: 30_000_000); return "SRC" })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await s.solve(playerId: "p1", nChallenges: ["x"], sigChallenges: []) } }
            try await group.waitForAll()
        }
        let loads = await counter.value
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(engine.solveCalls, 1)
    }

    func testCacheEvictsOldestAndJSONEscaping() {
        var c = SolutionCache(capacity: 2)
        c.set("a", "1"); c.set("b", "2"); _ = c.get("a"); c.set("c", "3")
        XCTAssertNil(c.get("b"))
        XCTAssertEqual(c.get("a"), "1")
        XCTAssertEqual(SolverWire.jsonArray(["a\"b", "x\u{2028}y", "p/q"]), #"["a\"b","x\u2028y","p\/q"]"#)
    }
}

private actor Counter { var value = 0; func bump() { value += 1 } }
private final class EngineBox: @unchecked Sendable {
    private let lock = NSLock(); private var list: [FakeEngine]
    init(_ l: [FakeEngine]) { list = l }
    func next() -> FakeEngine { lock.lock(); defer { lock.unlock() }; return list.count > 1 ? list.removeFirst() : list[0] }
}
