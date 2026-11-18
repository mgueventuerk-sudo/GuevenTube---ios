import XCTest
@testable import GuevenCore

/// Stellvertreter für ECDSA: gültig, wenn die „Signatur“ die SHA-256 der Nachricht ist.
struct HashVerifier: SignatureVerifying {
    func isValid(signature: Data, for message: Data) -> Bool { signature == Data(SHA256Hash.digest([UInt8](message))) }
}

final class SignedConfigTests: XCTestCase {
    private func signed(_ json: String) -> (Data, String) {
        let d = Data(json.utf8); return (d, Data(SHA256Hash.digest([UInt8](d))).base64EncodedString())
    }
    private func cfg(version: Int, extra: String = "", schema: Int = 1) -> String {
        #"{"schema":\#(schema),"version":\#(version),"flags":{"a":true,"b":false}\#(extra)}"#
    }
    private let verifier = SignedConfigVerifier(HashVerifier())
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sc\(UUID().uuidString)") }
    private func ok(_ d: Data) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: d)) }
    private func repo(_ dir: URL, _ t: FakeTransport, url: String? = "https://x/config.json", now: @escaping @Sendable () -> Int64 = { 1_000 }) -> SignedConfigRepository {
        SignedConfigRepository(directory: dir, transport: t, verifier: verifier, sourceUrl: { url }, nowMs: now)
    }

    func testVerifyOkAndFlags() throws {
        let (d, s) = signed(cfg(version: 5))
        let c = try verifier.verify(d, signatureBase64: "  " + s + "\n", minimumVersion: 5)
        XCTAssertEqual(c.version, 5); XCTAssertTrue(c.flag("a")); XCTAssertFalse(c.flag("b", default: true)); XCTAssertTrue(c.flag("zz", default: true))
    }

    func testRejections() {
        func err(_ d: Data, _ s: String, min: Int64 = 0) -> String? {
            do { _ = try verifier.verify(d, signatureBase64: s, minimumVersion: min); return nil } catch { return (error as? SignedConfigError)?.message }
        }
        let (d, s) = signed(cfg(version: 5))
        XCTAssertEqual(err(d, "§§§"), "Signatur ist kein Base64")
        XCTAssertEqual(err(d, Data([1, 2, 3]).base64EncodedString()), "Signatur ungültig")
        XCTAssertEqual(err(Data((cfg(version: 5) + " ").utf8), s), "Signatur ungültig")
        let (d2, s2) = signed(cfg(version: 5, schema: 2)); XCTAssertEqual(err(d2, s2), "Unbekanntes Schema 2")
        XCTAssertTrue(err(d, s, min: 6)!.contains("Rückspielschutz"))
        let (d3, s3) = signed("kein json"); XCTAssertEqual(err(d3, s3), "Paket nicht lesbar")
        let (d4, s4) = signed(cfg(version: 1, extra: #","solver":{"url":"http://x","sha256":"\#(String(repeating: "a", count: 64))","version":"1"}"#))
        XCTAssertEqual(err(d4, s4), "Entschlüssler-URL ohne HTTPS")
        let (d5, s5) = signed(cfg(version: 1, extra: #","solver":{"url":"https://x","sha256":"ABC","version":"1"}"#))
        XCTAssertEqual(err(d5, s5), "Ungültige Prüfsumme")
        let big = Data(repeating: 0x20, count: SignedConfigFormat.maxConfigBytes + 1)
        XCTAssertEqual(err(big, s), "Paket zu groß")
    }

    func testClientsDecoded() throws {
        let (d, s) = signed(cfg(version: 1, extra: #","clients":[{"id":"x","label":"X","clientName":"WEB","clientNameId":1,"clientVersion":"2","userAgent":"UA","requiresPoToken":true}]"#))
        let c = try verifier.verify(d, signatureBase64: s, minimumVersion: 0)
        XCTAssertEqual(c.clients?.count, 1); XCTAssertTrue(c.clients![0].requiresPoToken); XCTAssertTrue(c.clients![0].requiresJsPlayer)
        XCTAssertEqual(c.clients![0].referer, HTTPConstants.youtubeTvReferer)
    }

    func testRefreshStoresAndReloads() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d, s) = signed(cfg(version: 3))
        let t = FakeTransport([ok(d), ok(Data(s.utf8))])
        let r = repo(dir, t)
        let st = await r.refresh()
        XCTAssertEqual(st.config?.version, 3); XCTAssertNil(st.error)
        XCTAssertEqual(t.requests.map(\.url.absoluteString), ["https://x/config.json", "https://x/config.json.sig"])
        let again = await repo(dir, FakeTransport([])).current(); XCTAssertEqual(again?.version, 3)
    }

    func testIntervalAndForce() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d, s) = signed(cfg(version: 3))
        let t = FakeTransport([ok(d), ok(Data(s.utf8)), ok(d), ok(Data(s.utf8))])
        let r = repo(dir, t)
        await r.refresh(); await r.refresh()
        XCTAssertEqual(t.requests.count, 2)
        await r.refresh(force: true)
        XCTAssertEqual(t.requests.count, 4)
    }

    func testDowngradeAndSameVersionDifferentContentRejected() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d5, s5) = signed(cfg(version: 5)); let (d4, s4) = signed(cfg(version: 4))
        let (d5b, s5b) = signed(cfg(version: 5, extra: #","clients":[]"#))
        let t = FakeTransport([ok(d5), ok(Data(s5.utf8)), ok(d4), ok(Data(s4.utf8)), ok(d5b), ok(Data(s5b.utf8))])
        let r = repo(dir, t)
        await r.refresh(force: true)
        let down = await r.refresh(force: true)
        XCTAssertTrue(down.error!.contains("Rückspielschutz")); XCTAssertEqual(down.config?.version, 5)
        let same = await r.refresh(force: true)
        XCTAssertTrue(same.error!.contains("anderem Inhalt")); XCTAssertEqual(same.config?.version, 5)
    }

    func testFloorSurvivesDeletedBundle() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d5, s5) = signed(cfg(version: 5))
        let r = repo(dir, FakeTransport([ok(d5), ok(Data(s5.utf8))]))
        await r.refresh(force: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("config.bundle"))
        let (d2, s2) = signed(cfg(version: 2))
        let r2 = repo(dir, FakeTransport([ok(d2), ok(Data(s2.utf8))]))
        let st = await r2.refresh(force: true)
        XCTAssertNil(st.config); XCTAssertTrue(st.error!.contains("Rückspielschutz"))
    }

    func testTamperedStoredBundleDiscarded() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d, s) = signed(cfg(version: 3))
        await repo(dir, FakeTransport([ok(d), ok(Data(s.utf8))])).refresh(force: true)
        let f = dir.appendingPathComponent("config.bundle")
        var raw = try Data(contentsOf: f); raw[raw.count - 2] ^= 0x01; try raw.write(to: f)
        let cur = await repo(dir, FakeTransport([])).current()
        XCTAssertNil(cur); XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testErrorsKeepStoredVersion() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (d, s) = signed(cfg(version: 3))
        let t = FakeTransport([ok(d), ok(Data(s.utf8)), .failure, .response(HTTPResponse(code: 404)), ok(Data(count: 300_000))])
        let r = repo(dir, t)
        await r.refresh(force: true)
        let offline = await r.refresh(force: true); XCTAssertEqual(offline.error, "Nicht erreichbar"); XCTAssertEqual(offline.config?.version, 3)
        let nf = await r.refresh(force: true); XCTAssertEqual(nf.error, "Nicht erreichbar")
        let big = await r.refresh(force: true); XCTAssertEqual(big.error, "Nicht erreichbar"); XCTAssertEqual(big.config?.version, 3)
    }

    func testSourceValidation() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let none = await repo(dir, FakeTransport([]), url: nil).refresh(force: true); XCTAssertEqual(none.error, "Keine Paket-Quelle eingestellt")
        let blank = await repo(dir, FakeTransport([]), url: "  ").refresh(force: true); XCTAssertEqual(blank.error, "Keine Paket-Quelle eingestellt")
        let http = await repo(dir, FakeTransport([]), url: "http://x/c.json").refresh(force: true); XCTAssertEqual(http.error, "Paket-Quelle muss mit https:// beginnen")
        let bad = await repo(dir, FakeTransport([]), url: "kein url").refresh(force: true); XCTAssertEqual(bad.error, "Paket-Quelle ist keine gültige URL")
    }
}
