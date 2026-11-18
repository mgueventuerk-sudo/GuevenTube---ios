import XCTest
@testable import GuevenCore

final class PlayerScriptRepositoryTests: XCTestCase {
    private func ok(_ s: String) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(s.utf8))) }
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ps\(UUID().uuidString)") }
    private let api = #"var scriptUrl = 'https:\/\/www.youtube.com\/s\/player\/c271e571\/www-widgetapi.vflset\/www-widgetapi.js';"#
    private let script = "var x={signatureTimestamp:20380,foo:1};"

    func testPlayerIdParsedAndCachedForOneHour() async throws {
        final class T: @unchecked Sendable { var now: Int64 = 0 }
        let t = T(); let net = FakeTransport([ok(api), ok(api)])
        let r = PlayerScriptRepository(transport: net, directory: dir(), clock: { t.now })
        let a = try await r.currentPlayerId(); XCTAssertEqual(a, "c271e571")
        t.now = PlayerScriptRepository.idTtlMs - 1; _ = try await r.currentPlayerId(); XCTAssertEqual(net.requests.count, 1)
        t.now = PlayerScriptRepository.idTtlMs; _ = try await r.currentPlayerId(); XCTAssertEqual(net.requests.count, 2)
        XCTAssertEqual(net.requests[0].url.absoluteString, PlayerScriptRepository.iframeApiUrl)
        XCTAssertEqual(net.requests[0].headers["User-Agent"], HTTPConstants.desktopUserAgent)
    }

    func testPlayerIdFailures() async {
        let r1 = PlayerScriptRepository(transport: FakeTransport([ok("nichts")]), directory: dir())
        do { _ = try await r1.currentPlayerId(); XCTFail() } catch { XCTAssertEqual((error as? SolverError)?.message, "Player-ID nicht in iframe_api gefunden") }
        let r2 = PlayerScriptRepository(transport: FakeTransport([.response(HTTPResponse(code: 503))]), directory: dir())
        do { _ = try await r2.currentPlayerId(); XCTFail() } catch { XCTAssertEqual((error as? SolverError)?.message, "HTTP 503") }
    }

    func testForceRefreshAndClear() async throws {
        let net = FakeTransport([ok(api), ok(api), ok(api)])
        let r = PlayerScriptRepository(transport: net, directory: dir(), clock: { 0 })
        _ = try await r.currentPlayerId(); _ = try await r.currentPlayerId(forceRefresh: true); XCTAssertEqual(net.requests.count, 2)
        await r.clear(); _ = try await r.currentPlayerId(); XCTAssertEqual(net.requests.count, 3)
    }

    func testScriptFetchedStoredAndReusedAfterRestart() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let net = FakeTransport([ok(script)])
        let r = PlayerScriptRepository(transport: net, directory: d)
        let s = try await r.script("c271e571"); XCTAssertEqual(s, script)
        _ = try await r.script("c271e571"); XCTAssertEqual(net.requests.count, 1)
        XCTAssertEqual(net.requests[0].url.absoluteString, "https://www.youtube.com/s/player/c271e571/player_ias.vflset/en_US/base.js")
        let net2 = FakeTransport([])
        let again = try await PlayerScriptRepository(transport: net2, directory: d).script("c271e571")
        XCTAssertEqual(again, script); XCTAssertEqual(net2.requests.count, 0, "nach Neustart von der Platte")
    }

    func testStsExtractionAndInvalidInput() async throws {
        let r = PlayerScriptRepository(transport: FakeTransport([ok(script), ok("sts : 19999 ")]), directory: dir())
        let sts = try await r.signatureTimestamp(playerId: "c271e571"); XCTAssertEqual(sts, 20380)
        let other = try await r.signatureTimestamp(playerId: "aaaaaaaa"); XCTAssertEqual(other, 19999)
        let none = try await PlayerScriptRepository(transport: FakeTransport([ok("var sts;")]), directory: dir()).signatureTimestamp(playerId: "bbbbbbbb"); XCTAssertNil(none)
        for bad in ["../etc/pw", "c271e57", "c271e571x", "zzzzzzzz", ""] {
            do { _ = try await r.script(bad); XCTFail(bad) } catch { XCTAssertEqual((error as? SolverError)?.message, "Ungültige Player-ID") }
        }
    }

    func testNonPlayerResponseNotStored() async {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let r = PlayerScriptRepository(transport: FakeTransport([ok("<html>Fehlerseite</html>")]), directory: d)
        do { _ = try await r.script("c271e571"); XCTFail() } catch { XCTAssertEqual((error as? SolverError)?.message, "Antwort ist kein Player-Skript") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("c271e571.js").path))
    }

    func testKeepsOnlyTwoNewestScripts() async throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let ids = ["aaaaaaa1", "aaaaaaa2", "aaaaaaa3"]
        let r = PlayerScriptRepository(transport: FakeTransport(ids.map { _ in ok(script) }), directory: d)
        for id in ids { _ = try await r.script(id); try await Task.sleep(nanoseconds: 1_100_000_000) }
        let left = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".js") }.sorted()
        XCTAssertEqual(left, ["aaaaaaa2.js", "aaaaaaa3.js"])
    }

    func testConcurrentCallsFetchOnce() async throws {
        let net = FakeTransport([ok(script), ok(script)])
        let r = PlayerScriptRepository(transport: net, directory: dir())
        await withTaskGroup(of: Void.self) { g in for _ in 0..<5 { g.addTask { _ = try? await r.script("c271e571") } } }
        XCTAssertEqual(net.requests.count, 1)
    }
}
