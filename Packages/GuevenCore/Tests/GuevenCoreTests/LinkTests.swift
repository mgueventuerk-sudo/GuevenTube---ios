import XCTest
@testable import GuevenCore

// MARK: Test-Hilfen

/// Unsichere, aber symmetrische Stellvertreter für ECDH/ECDSA/AES-GCM – prüfen den Ablauf, nicht die Mathematik.
final class FakeLinkCrypto: LinkCryptoPrimitives, @unchecked Sendable {
    private let lock = NSLock(); private var n: UInt64 = 0
    private let seed: UInt8
    init(seed: UInt8 = 0) { self.seed = seed }
    func randomBytes(_ count: Int) -> Data {
        lock.withLock { n += 1; return Data(Pbkdf2.hmacSHA256(key: [seed], message: Array("\(n)".utf8)).prefix(count) + [UInt8](repeating: 7, count: max(0, count - 32))) }
    }
    func newKeyPair() throws -> LinkKeyPair { let k = randomBytes(32); return LinkKeyPair(publicKey: k, privateKey: k) }
    func ecdh(privateKey: Data, peerPublicKey: Data) throws -> Data {
        let a = [UInt8](privateKey), b = [UInt8](peerPublicKey)
        return Data(SHA256Hash.digest(a.lexicographicallyPrecedes(b) ? a + b : b + a))
    }
    func sign(privateKey: Data, message: Data) throws -> Data { Data(Pbkdf2.hmacSHA256(key: [UInt8](privateKey), message: [UInt8](message))) }
    func verify(publicKey: Data, message: Data, signature: Data) -> Bool { (try? sign(privateKey: publicKey, message: message)) == signature }
    private func stream(_ key: Data, _ nonce: Data, _ n: Int) -> [UInt8] {
        var out: [UInt8] = []; var i: UInt8 = 0
        while out.count < n { out += Pbkdf2.hmacSHA256(key: [UInt8](key), message: [UInt8](nonce) + [i]); i += 1 }
        return Array(out.prefix(n))
    }
    func seal(key: Data, nonce: Data, plaintext: Data) throws -> Data {
        let ct = zip([UInt8](plaintext), stream(key, nonce, plaintext.count)).map { $0 ^ $1 }
        return Data(ct + Pbkdf2.hmacSHA256(key: [UInt8](key), message: [UInt8](nonce) + ct).prefix(16))
    }
    func open(key: Data, nonce: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw LinkError("kurz") }
        let ct = [UInt8](ciphertext.dropLast(16)), tag = [UInt8](ciphertext.suffix(16))
        guard Array(Pbkdf2.hmacSHA256(key: [UInt8](key), message: [UInt8](nonce) + ct).prefix(16)) == tag else { throw LinkError("Tag") }
        return Data(zip(ct, stream(key, nonce, ct.count)).map { $0 ^ $1 })
    }
}

/// Zwei verbundene Enden im Speicher.
final class PipeEnd: LinkFrameTransport, @unchecked Sendable {
    private let box: Inbox; private var peer: PipeEnd?
    actor Inbox {
        var queue: [Data] = []; var waiters: [CheckedContinuation<Data, Error>] = []; var closed = false
        func push(_ d: Data) { if waiters.isEmpty { queue.append(d) } else { waiters.removeFirst().resume(returning: d) } }
        func pop() async throws -> Data {
            if !queue.isEmpty { return queue.removeFirst() }
            if closed { throw LinkError("zu") }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        func close() { closed = true; waiters.forEach { $0.resume(throwing: LinkError("zu")) }; waiters = [] }
    }
    init() { box = Inbox() }
    static func pair() -> (PipeEnd, PipeEnd) { let a = PipeEnd(), b = PipeEnd(); a.peer = b; b.peer = a; return (a, b) }
    private(set) var tamper: (@Sendable (Data) -> Data)?
    func setTamper(_ f: @escaping @Sendable (Data) -> Data) { tamper = f }
    func read() async throws -> Data { try await box.pop() }
    func write(_ frame: Data) async throws { await peer!.box.push(tamper?(frame) ?? frame) }
    func close() { Task { await box.close(); await peer?.box.close() } }
}

/// TV-Seite (Port von `LinkHandshake.server`) für die Gegenprobe.
struct TestTv {
    let crypto: LinkCryptoPrimitives
    let identity: LinkKeyPair
    let tvId = "tv-1", tvName = "Wohnzimmer"
    var knownKeys: [String: Data] = [:]
    var tokens: Set<String> = []
    var approve = true
    var sasSeen: (@Sendable (String) -> Void)?
    var tamperSignature = false

    func serve(_ t: LinkFrameTransport) async throws -> (LinkChannel, PairedDevice?) {
        let hello = try LinkMessage.decode(try await t.read())
        guard hello.t == LinkMessage.hello, hello.v == 1 else { throw LinkError("Protokoll") }
        let deviceId = hello.deviceId!, deviceName = hello.name ?? "Handy"
        let clientPk = LinkB64.decode(hello.pk!)!
        let mode = hello.mode
        let binding = mode == LinkMessage.modePair ? LinkB64.decode(hello.commit!)! : LinkB64.decode(hello.nonce!)!
        var resumeKey: Data?
        if mode == LinkMessage.modeResume {
            guard let k = knownKeys[deviceId] else {
                try await t.write(try LinkMessage.encode(LinkMessage(t: LinkMessage.rejected, reason: "unknown")))
                throw LinkRejectedError(reason: "unknown")
            }
            resumeKey = k
        }
        let eph = try crypto.newKeyPair(); let serverNonce = [UInt8](crypto.randomBytes(32))
        let ht = LinkMath.helloTranscript(mode: mode, clientPk: [UInt8](clientPk), serverPk: [UInt8](eph.publicKey), binding: [UInt8](binding), serverNonce: serverNonce)
        var sig = try crypto.sign(privateKey: identity.privateKey, message: Data(ht))
        if tamperSignature { sig[0] ^= 1 }
        try await t.write(try LinkMessage.encode(LinkMessage(t: LinkMessage.hello, v: 1, deviceId: tvId, name: tvName, pk: LinkB64.encode(eph.publicKey),
            identity: LinkB64.encode(identity.publicKey), signature: LinkB64.encode(sig), nonce: LinkB64.encode(Data(serverNonce)))))
        var clientNonce = [UInt8](binding)
        if mode == LinkMessage.modePair {
            let reveal = try LinkMessage.decode(try await t.read())
            let nonce = [UInt8](LinkB64.decode(reveal.nonce!)!)
            guard LinkMath.sha256(nonce) == [UInt8](binding) else { throw LinkError("Commitment") }
            clientNonce = nonce
        }
        let transcript = LinkMath.sessionTranscript(mode: mode, clientPk: [UInt8](clientPk), serverPk: [UInt8](eph.publicKey), clientNonce: clientNonce, serverNonce: serverNonce)
        let shared = [UInt8](try crypto.ecdh(privateKey: eph.privateKey, peerPublicKey: clientPk))
        let keys = LinkMath.sessionKeys(mode: mode, shared: shared, linkKey: resumeKey.map { [UInt8]($0) }, transcript: transcript)
        let ch = LinkChannel(transport: t, sendCipher: LinkFrameCipher(key: Data(keys.serverToClient), direction: LinkFrameCipher.serverToClient, crypto: crypto),
                             receiveCipher: LinkFrameCipher(key: Data(keys.clientToServer), direction: LinkFrameCipher.clientToServer, crypto: crypto), peerId: deviceId, peerName: deviceName)
        let auth = try await ch.receive()
        guard auth.t == LinkMessage.auth else { throw LinkError("auth") }
        if mode == LinkMessage.modeResume { try await ch.send(LinkMessage(t: LinkMessage.welcome, deviceId: tvId, name: tvName)); return (ch, nil) }
        let sas = LinkMath.sas(transcript); sasSeen?(sas)
        let ok = (auth.token.map { tokens.contains($0) } ?? false) || approve
        guard ok else { try? await ch.send(LinkMessage(t: LinkMessage.rejected, reason: "denied")); throw LinkRejectedError(reason: "denied") }
        let linkKey = crypto.randomBytes(32)
        try await ch.send(LinkMessage(t: LinkMessage.paired, deviceId: tvId, name: tvName, linkKey: LinkB64.encode(linkKey)))
        return (ch, PairedDevice(id: deviceId, name: deviceName, linkKey: LinkB64.encode(linkKey)))
    }
}

final class SasBox: @unchecked Sendable { var value: String?; let lock = NSLock(); func set(_ v: String) { lock.withLock { value = v } } }

// MARK: Tests

final class LinkMathTests: XCTestCase {
    func testAgainstPythonReferenceValues() {
        XCTAssertEqual(Data(LinkMath.fingerprint(Array(0..<91))).hex, "c93cd0bd04ea3a859ae7991c8928d316")
        let t = LinkMath.sessionTranscript(mode: "pair", clientPk: [1, 2], serverPk: [3, 4], clientNonce: [UInt8](repeating: 110, count: 32), serverNonce: [UInt8](repeating: 109, count: 32))
        XCTAssertEqual(Data(t).hex, "4c55d49c8f21e8537758e596328b2eadf4078e75888771597b7d516b0898d6fa")
        XCTAssertEqual(LinkMath.sas(t), "465961")
        XCTAssertEqual(Data(LinkMath.hkdf(ikm: Array("shared".utf8) + Array("shared".utf8) + Array("shared".utf8) + Array("shared".utf8) + Array("shared".utf8) + Array("shared".utf8), salt: t, info: Array("gt-link-pair".utf8), length: 64)).hex,
                       "f1ff679d183fba5dc8d41dd1d8fc9bfc3aed5f6335f39834eac524c0fd8b64696b3c65549914fdb47bea14a2017604df7d9529ec7de30c544fae9f19adb3395c")
        XCTAssertEqual(Data(LinkMath.hkdf(ikm: [UInt8](repeating: 65, count: 70), salt: Array("salt".utf8), info: Array("info".utf8), length: 100)).hex,
                       "18a1a0f4df72fd1cd467b8e017f46828049345394580e5de8752a7f5f7af575bc048add7e7f97ba320b4ff181d89300c4682df9d4e653cc7d0f49511843518c4aaea8aad670d54ca8e633b43025ab18b9a5e74cbbbf99c62064148a5cdf58d390a56536a")
        XCTAssertEqual(Data(LinkMath.sha256([], [97], [98, 99])).hex, "412265430b9e0d19e7ed0867645c6799ed2462ce9cc0ef43dad549a3eeb9828e")
    }

    func testSasHasSixDigitsWithLeadingZeros() {
        for i in 0..<200 { let s = LinkMath.sas([UInt8(i)]); XCTAssertEqual(s.count, 6); XCTAssertTrue(s.allSatisfy(\.isNumber)) }
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LinkMath.constantTimeEquals([1, 2], [1, 2])); XCTAssertFalse(LinkMath.constantTimeEquals([1, 2], [1, 3])); XCTAssertFalse(LinkMath.constantTimeEquals([1], [1, 2]))
    }

    func testBase64UrlNoPadding() {
        XCTAssertEqual(LinkB64.encode(Data([0xFB, 0xFF, 0xFE])), "-__-"); XCTAssertEqual(LinkB64.encode(Data([1])), "AQ")
        XCTAssertEqual(LinkB64.decode("AQ"), Data([1])); XCTAssertEqual(LinkB64.decode("-__-"), Data([0xFB, 0xFF, 0xFE]))
        XCTAssertNil(LinkB64.decode("AQ==")); XCTAssertNil(LinkB64.decode("A"))
        let d = Data((0..<200).map { UInt8($0) }); XCTAssertEqual(LinkB64.decode(LinkB64.encode(d)), d)
    }

    func testFraming() throws {
        let f = try LinkFraming.encode(Data([9, 9, 9])); XCTAssertEqual([UInt8](f), [0, 0, 0, 3, 9, 9, 9])
        XCTAssertEqual(try LinkFraming.length(ofHeader: Data([0, 0, 1, 0])), 256)
        XCTAssertThrowsError(try LinkFraming.length(ofHeader: Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try LinkFraming.length(ofHeader: Data([0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try LinkFraming.length(ofHeader: Data([0, 4, 0, 1])))
        XCTAssertThrowsError(try LinkFraming.encode(Data(count: LinkFraming.maxFrame + 1)))
        XCTAssertNoThrow(try LinkFraming.encode(Data(count: LinkFraming.maxFrame)))
    }

    func testMessageCompatibility() throws {
        let kotlin = #"{"t":"state","state":{"videoId":"abc","title":"T","positionMs":5,"queue":[{"videoId":"q"}]},"neu":1}"#
        let m = try LinkMessage.decode(Data(kotlin.utf8))
        XCTAssertEqual(m.state?.videoId, "abc"); XCTAssertEqual(m.state?.author, ""); XCTAssertEqual(m.state?.durationMs, 0)
        XCTAssertEqual(m.state?.queue.first?.title, ""); XCTAssertEqual(m.state?.queue.first?.isLive, false)
        let out = String(decoding: try LinkMessage.encode(LinkMessage(t: "ping")), as: UTF8.self)
        XCTAssertEqual(out, #"{"t":"ping"}"#)
        let p = try LinkMessage.decode(Data(#"{"t":"progress","progress":[{"videoId":"v","positionMs":1,"durationMs":2,"updatedAt":3}]}"#.utf8))
        XCTAssertEqual(p.progress?.first?.entry, WatchProgressEntry(videoId: "v", positionMs: 1, durationMs: 2, updatedAt: 3))
    }
}

final class LinkCipherTests: XCTestCase {
    func testNonceLayoutMatchesAndroid() {
        let c = LinkFrameCipher(key: Data(count: 32), direction: LinkFrameCipher.serverToClient, crypto: FakeLinkCrypto())
        XCTAssertEqual([UInt8](c.nonce(258)), [0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1, 2])
    }

    func testOrderReplayAndTamper() throws {
        let cr = FakeLinkCrypto(); let k = Data(repeating: 5, count: 32)
        let tx = LinkFrameCipher(key: k, direction: 1, crypto: cr), rx = LinkFrameCipher(key: k, direction: 1, crypto: cr)
        let a = try tx.seal(Data("a".utf8)), b = try tx.seal(Data("b".utf8))
        XCTAssertThrowsError(try rx.open(b))                       // falsche Reihenfolge
        XCTAssertEqual(try rx.open(a), Data("a".utf8))             // Zähler nicht vorgerückt → a noch möglich
        XCTAssertThrowsError(try rx.open(a))                       // Wiederholung
        var bad = b; bad[0] ^= 1
        XCTAssertThrowsError(try rx.open(bad))                     // Manipulation
        XCTAssertEqual(try rx.open(b), Data("b".utf8))
        let other = LinkFrameCipher(key: k, direction: 2, crypto: cr)
        XCTAssertThrowsError(try other.open(try tx.seal(Data("c".utf8))))   // Richtung
    }
}

final class LinkHandshakeTests: XCTestCase {
    private let client = FakeLinkCrypto(seed: 1), tvCrypto = FakeLinkCrypto(seed: 2)
    private func tv(_ edit: (inout TestTv) -> Void = { _ in }) throws -> TestTv {
        var t = TestTv(crypto: tvCrypto, identity: try tvCrypto.newKeyPair()); edit(&t); return t
    }
    private func run<T: Sendable>(_ tv: TestTv, _ body: @escaping @Sendable (PipeEnd) async throws -> T) async -> (T?, Error?, (LinkChannel, PairedDevice?)?, Error?) {
        let (a, b) = PipeEnd.pair()
        async let server: Result<(LinkChannel, PairedDevice?), Error> = { do { return .success(try await tv.serve(b)) } catch { a.close(); return .failure(error) } }()
        var cv: T?, ce: Error?
        do { cv = try await body(a) } catch { ce = error; b.close() }
        let s = await server
        switch s { case .success(let v): return (cv, ce, v, nil); case .failure(let e): return (cv, ce, nil, e) }
    }

    func testPairWithQrTokenNoSas() async throws {
        let t = try tv { $0.tokens = ["tok"] }
        let sasCalled = SasBox()
        let lc = LinkClient(crypto: client, nowMs: { 42 })
        let fp = LinkMath.fingerprint([UInt8](t.identity.publicKey))
        let (res, ce, srv, se) = await run(t) { end in try await lc.pair(transport: end, deviceId: "ph", deviceName: "iPhone", expectedFingerprint: fp, token: "tok", onSas: { sasCalled.set($0) }) }
        XCTAssertNil(ce); XCTAssertNil(se); XCTAssertNil(sasCalled.value)
        XCTAssertEqual(res?.device.id, "tv-1"); XCTAssertEqual(res?.device.name, "Wohnzimmer"); XCTAssertEqual(res?.device.pairedAt, 42)
        XCTAssertEqual(res?.device.identity, LinkB64.encode(t.identity.publicKey)); XCTAssertEqual(res?.device.linkKey, srv?.1?.linkKey)
        XCTAssertEqual(srv?.0.peerName, "iPhone")
        // Der Kanal funktioniert in beide Richtungen.
        try await res!.channel.send(LinkMessage(t: LinkMessage.play, video: LinkVideo(videoId: "v")))
        let got = try await srv!.0.receive(); XCTAssertEqual(got.video?.videoId, "v")
        try await srv!.0.send(LinkMessage(t: LinkMessage.state, state: LinkPlayerState()))
        let back = try await res!.channel.receive(); XCTAssertEqual(back.t, LinkMessage.state)
    }

    func testPairWithSasBothSidesSeeSameCode() async throws {
        let sasTv = SasBox(); let sasPhone = SasBox()
        let t = try tv { $0.sasSeen = { sasTv.set($0) } }
        let lc = LinkClient(crypto: client)
        let (res, ce, _, se) = await run(t) { end in try await lc.pair(transport: end, deviceId: "ph", deviceName: "iPhone", expectedFingerprint: nil, token: nil, onSas: { sasPhone.set($0) }) }
        XCTAssertNil(ce); XCTAssertNil(se); XCTAssertNotNil(res)
        XCTAssertNotNil(sasPhone.value); XCTAssertEqual(sasPhone.value, sasTv.value)
    }

    func testPairDeniedAtTv() async throws {
        let t = try tv { $0.approve = false }
        let lc = LinkClient(crypto: client)
        let (res, ce, _, _) = await run(t) { end in try await lc.pair(transport: end, deviceId: "ph", deviceName: "i", expectedFingerprint: nil, token: nil, onSas: { _ in }) }
        XCTAssertNil(res); XCTAssertEqual(ce as? LinkRejectedError, LinkRejectedError(reason: "denied"))
    }

    func testWrongFingerprintAbortsBeforeReveal() async throws {
        let t = try tv()
        let lc = LinkClient(crypto: client)
        let (res, ce, srv, _) = await run(t) { end in try await lc.pair(transport: end, deviceId: "ph", deviceName: "i", expectedFingerprint: [UInt8](repeating: 0, count: 16), token: nil, onSas: { _ in }) }
        XCTAssertNil(res); XCTAssertNil(srv); XCTAssertEqual(ce as? LinkRejectedError, LinkRejectedError(reason: "fingerprint"))
    }

    func testBadHelloSignatureRejected() async throws {
        let t = try tv { $0.tamperSignature = true }
        let lc = LinkClient(crypto: client)
        let (_, ce, _, _) = await run(t) { end in try await lc.pair(transport: end, deviceId: "ph", deviceName: "i", expectedFingerprint: nil, token: nil, onSas: { _ in }) }
        XCTAssertEqual(ce as? LinkRejectedError, LinkRejectedError(reason: "signature"))
    }

    func testResumeSuccessAndFailures() async throws {
        let linkKey = Data(repeating: 9, count: 32)
        let t = try tv { $0.knownKeys = ["ph": linkKey] }
        let device = PairedDevice(id: "tv-1", name: "TV", linkKey: LinkB64.encode(linkKey), identity: LinkB64.encode(t.identity.publicKey))
        let lc = LinkClient(crypto: client)
        let (ch, ce, srv, se) = await run(t) { end in try await lc.resume(transport: end, deviceId: "ph", deviceName: "i", tv: device) }
        XCTAssertNil(ce); XCTAssertNil(se); XCTAssertEqual(ch?.peerName, "Wohnzimmer"); XCTAssertNotNil(srv)

        var wrongId = device; wrongId.identity = LinkB64.encode(Data(repeating: 1, count: 32))
        let (_, e1, _, _) = await run(t) { end in try await lc.resume(transport: end, deviceId: "ph", deviceName: "i", tv: wrongId) }
        XCTAssertEqual(e1 as? LinkRejectedError, LinkRejectedError(reason: "identity"))

        var noId = device; noId.identity = nil
        let (_, e2, _, _) = await run(t) { end in try await lc.resume(transport: end, deviceId: "ph", deviceName: "i", tv: noId) }
        XCTAssertEqual(e2 as? LinkRejectedError, LinkRejectedError(reason: "identity"))

        let (_, e3, _, _) = await run(t) { end in try await lc.resume(transport: end, deviceId: "fremd", deviceName: "i", tv: device) }
        XCTAssertEqual(e3 as? LinkRejectedError, LinkRejectedError(reason: "unknown"))

        var wrongKey = device; wrongKey.linkKey = LinkB64.encode(Data(repeating: 8, count: 32))
        let (_, e4, _, se4) = await run(t) { end in try await lc.resume(transport: end, deviceId: "ph", deviceName: "i", tv: wrongKey) }
        XCTAssertNotNil(e4); XCTAssertNotNil(se4)   // falscher Kopplungsschlüssel: Entschlüsselung der ersten Nachricht scheitert
    }

    func testConcurrentSendsArriveInOrder() async throws {
        let linkKey = Data(repeating: 9, count: 32)
        let t = try tv { $0.knownKeys = ["ph": linkKey] }
        let device = PairedDevice(id: "tv-1", name: "TV", linkKey: LinkB64.encode(linkKey), identity: LinkB64.encode(t.identity.publicKey))
        let lc = LinkClient(crypto: client)
        let (ch, _, srv, _) = await run(t) { end in try await lc.resume(transport: end, deviceId: "ph", deviceName: "i", tv: device) }
        let sender = ch!, receiver = srv!.0
        await withTaskGroup(of: Void.self) { g in for i in 0..<50 { g.addTask { try? await sender.send(LinkMessage(t: LinkMessage.control, value: Int64(i))) } } }
        var seen = Set<Int64>()
        for _ in 0..<50 { if let m = try? await receiver.receive(), let v = m.value { seen.insert(v) } }
        XCTAssertEqual(seen.count, 50)   // keine Nachricht durch falsche Nonce-Reihenfolge verloren
    }
}

final class LinkStoreTests: XCTestCase {
    func testGuardLocksAfterFiveFailuresAndExpires() {
        final class T: @unchecked Sendable { var now: Int64 = 0 }
        let t = T(); let g = PairingGuard(nowMs: { t.now })
        for i in 0..<4 { XCTAssertFalse(g.recordFailure("a"), "\(i)") }
        XCTAssertTrue(g.allowed("a")); XCTAssertTrue(g.recordFailure("a")); XCTAssertFalse(g.allowed("a")); XCTAssertTrue(g.allowed("b"))
        t.now = PairingGuard.lockMs - 1; XCTAssertFalse(g.allowed("a"))
        t.now = PairingGuard.lockMs; XCTAssertTrue(g.allowed("a"))
    }

    func testGuardWindowAndSuccessReset() {
        final class T: @unchecked Sendable { var now: Int64 = 0 }
        let t = T(); let g = PairingGuard(nowMs: { t.now })
        for _ in 0..<4 { g.recordFailure("a") }
        t.now = PairingGuard.windowMs + 1; XCTAssertFalse(g.recordFailure("a"))   // alte Fehler verfallen
        for _ in 0..<3 { g.recordFailure("a") }; g.recordSuccess("a")
        for _ in 0..<4 { XCTAssertFalse(g.recordFailure("a")) }
    }

    func testAuditLogKeeps30NewestAndTruncates() {
        final class T: @unchecked Sendable { var now: Int64 = 0 }
        let t = T(); let log = LinkAuditLog(store: InMemoryStringStore(), nowMs: { t.now += 1; return t.now })
        for i in 0..<40 { log.add("e\(i)") }
        let e = log.entries(); XCTAssertEqual(e.count, 30); XCTAssertEqual(e.first?.text, "e39"); XCTAssertEqual(e.last?.text, "e10")
        log.add(String(repeating: "x", count: 500)); XCTAssertEqual(log.entries().first?.text.count, 120)
        log.clear(); XCTAssertTrue(log.entries().isEmpty)
    }

    func testStoreDeviceIdStableAndDevicesCapped() async throws {
        let secrets = FakeSecrets()
        let s = LinkStore(secrets: secrets, deviceModel: "iPhone 15")
        let id1 = await s.deviceId(); let id2 = await s.deviceId(); XCTAssertEqual(id1, id2)
        let n = await s.deviceName(); XCTAssertEqual(n, "iPhone 15")
        for i in 0..<10 { try await s.save(PairedDevice(id: "d\(i)", name: "n", linkKey: "k")) }
        try await s.save(PairedDevice(id: "d9", name: "neu", linkKey: "k2"))
        let all = await s.load()
        XCTAssertEqual(all.map(\.id), ["d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9"]); XCTAssertEqual(all.last?.name, "neu")
        try await s.remove("d3"); let after = await s.load(); XCTAssertEqual(after.count, 7)
        let again = await LinkStore(secrets: secrets, deviceModel: "x").deviceId(); XCTAssertEqual(again, id1)
    }

    func testStoreToleratesCorruptData() async {
        let secrets = FakeSecrets(); secrets.store["link.devices"] = "kaputt"
        let s = LinkStore(secrets: secrets, deviceModel: " ")
        let d = await s.load(); XCTAssertTrue(d.isEmpty)
        let n = await s.deviceName(); XCTAssertEqual(n, "iPhone")
    }
}

extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
