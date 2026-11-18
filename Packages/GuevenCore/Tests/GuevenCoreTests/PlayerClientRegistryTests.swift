import XCTest
@testable import GuevenCore

final class PlayerClientRegistryTests: XCTestCase {
    private func file(_ clients: String) -> String { #"{"clients":[\#(clients)]}"# }
    private func client(_ id: String, enabled: Bool = true, ua: String = "UA") -> String {
        #"{"id":"\#(id)","label":"L","clientName":"WEB","clientNameId":1,"clientVersion":"2","userAgent":"\#(ua)","enabled":\#(enabled)}"#
    }
    private func ok(_ s: String) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(s.utf8))) }
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pr\(UUID().uuidString)/clients.json") }
    private func registry(_ t: FakeTransport, cache: URL, url: String? = nil, signed: SignedConfig? = nil) -> PlayerClientRegistry {
        PlayerClientRegistry(transport: t, cacheFile: cache, profilesUrl: { url }, signedConfig: { signed })
    }
    private func signedConfig(_ profiles: [PlayerClientProfile]?, version: Int64 = 7) -> SignedConfig {
        SignedConfig(schema: 1, version: version, issuedAt: nil, clients: profiles, solver: nil, flags: [:])
    }
    private func profile(_ id: String, enabled: Bool = true, ua: String = "UA") -> PlayerClientProfile {
        var p = PlayerClientProfile(id: id, label: "L", clientName: "WEB", clientNameId: 1, clientVersion: "2", userAgent: ua); p.enabled = enabled; return p
    }

    func testBuiltInByDefault() async {
        let r = registry(FakeTransport([]), cache: tmp())
        let p = await r.profiles(); XCTAssertEqual(p.map(\.id), DefaultPlayerClients.all.filter(\.enabled).map(\.id))
        let s = await r.currentStatus(); XCTAssertEqual(s.source, "Eingebaut"); XCTAssertNil(s.error)
    }

    func testSignedPackageOverridesBuiltInButOnlyValidOnes() async {
        let good = signedConfig([profile("a"), profile("b", enabled: false), profile("c", ua: "  ")])
        let r = registry(FakeTransport([]), cache: tmp(), signed: good)
        let s = await r.reload(); XCTAssertEqual(s.source, "Signiertes Paket v7"); XCTAssertEqual(s.profiles.map(\.id), ["a", "b"])
        let p = await r.profiles(); XCTAssertEqual(p.map(\.id), ["a"], "ausgeschaltete werden nicht geliefert")
        let allOff = await registry(FakeTransport([]), cache: tmp(), signed: signedConfig([profile("x", enabled: false)])).reload(); XCTAssertEqual(allOff.source, "Eingebaut")
        let none = await registry(FakeTransport([]), cache: tmp(), signed: signedConfig(nil)).reload(); XCTAssertEqual(none.source, "Eingebaut")
    }

    func testUrlWinsOverSignedAndIsCached() async {
        let c = tmp(); defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        let net = FakeTransport([ok(file(client("u1")))])
        let r = registry(net, cache: c, url: " https://x/p.json ", signed: signedConfig([profile("a")]))
        let s = await r.reload(); XCTAssertEqual(s.source, "URL (https://x/p.json)"); XCTAssertEqual(s.profiles.map(\.id), ["u1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
        let again = await registry(FakeTransport([]), cache: c, url: "https://x/p.json").reload(fetchRemote: false)
        XCTAssertEqual(again.source, "Gespeicherte Kopie der URL"); XCTAssertEqual(again.profiles.map(\.id), ["u1"]); XCTAssertNil(again.error)
    }

    func testBrokenUrlFallsBackToCacheThenBuiltIn() async {
        let c = tmp(); defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        _ = await registry(FakeTransport([ok(file(client("u1")))]), cache: c, url: "https://x").reload()
        let cached = await registry(FakeTransport([.response(HTTPResponse(code: 500))]), cache: c, url: "https://x").reload()
        XCTAssertEqual(cached.source, "Gespeicherte Kopie der URL"); XCTAssertEqual(cached.profiles.map(\.id), ["u1"]); XCTAssertEqual(cached.error, "URL nicht nutzbar (HTTP 500)")
        let bad = await registry(FakeTransport([ok("kein json")]), cache: c, url: "https://x").reload()
        XCTAssertEqual(bad.source, "Gespeicherte Kopie der URL"); XCTAssertEqual(bad.error, "URL nicht nutzbar (kein gültiges JSON)")
        let fresh = tmp()
        let none = await registry(FakeTransport([.failure]), cache: fresh, url: "https://x").reload()
        XCTAssertEqual(none.source, "Eingebaut"); XCTAssertEqual(none.profiles, DefaultPlayerClients.all); XCTAssertTrue(none.error!.hasPrefix("URL nicht nutzbar"))
    }

    func testInvalidFilesAreRejectedNotCached() async {
        let c = tmp(); defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        let off = await registry(FakeTransport([ok(file(client("x", enabled: false)))]), cache: c, url: "https://x").reload()
        XCTAssertEqual(off.source, "Eingebaut"); XCTAssertEqual(off.error, "URL nicht nutzbar (keine aktiven Profile)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
        let noUa = await registry(FakeTransport([ok(file(client("x", ua: " ")))]), cache: c, url: "https://x").reload()
        XCTAssertEqual(noUa.error, "URL nicht nutzbar (Profil x ohne User-Agent)")
    }

    func testCachedCopyUsedWithoutFetchAndMissingCacheReported() async {
        let c = tmp()
        let miss = await registry(FakeTransport([]), cache: c, url: "https://x").reload(fetchRemote: false)
        XCTAssertEqual(miss.source, "Eingebaut")   // ohne Kopie wird dann doch geladen; Netz liefert hier nichts → Fehler
        XCTAssertNotNil(miss.error)
    }

    func testRemovingUrlReturnsToSignedOrBuiltIn() async {
        final class U: @unchecked Sendable { var url: String? = "https://x" }
        let u = U(); let c = tmp(); defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        let r = PlayerClientRegistry(transport: FakeTransport([ok(file(client("u1")))]), cacheFile: c, profilesUrl: { u.url }, signedConfig: { nil })
        let a = await r.reload(); XCTAssertEqual(a.profiles.map(\.id), ["u1"])
        u.url = nil
        let b = await r.reload(); XCTAssertEqual(b.source, "Eingebaut")
    }
}
