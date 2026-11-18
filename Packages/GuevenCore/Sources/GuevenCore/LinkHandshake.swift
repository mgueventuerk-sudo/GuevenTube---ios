import Foundation

/// Gekoppeltes Gerät (auf beiden Seiten gespeichert).
public struct PairedDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Gemeinsamer Kopplungsschlüssel (32 Byte, Base64url).
    public var linkKey: String
    /// Nur auf dem Handy: Identität des Fernsehers (SPKI, Base64url), bei jeder Verbindung geprüft.
    public var identity: String?
    public var host: String?
    public var port: Int?
    public var pairedAt: Int64
    public init(id: String, name: String, linkKey: String, identity: String? = nil, host: String? = nil, port: Int? = nil, pairedAt: Int64 = 0) {
        self.id = id; self.name = name; self.linkKey = linkKey; self.identity = identity; self.host = host; self.port = port; self.pairedAt = pairedAt
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name); linkKey = try c.decode(String.self, forKey: .linkKey)
        identity = try c.decodeIfPresent(String.self, forKey: .identity); host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port); pairedAt = try c.decodeIfPresent(Int64.self, forKey: .pairedAt) ?? 0
    }
    private enum K: String, CodingKey { case id, name, linkKey, identity, host, port, pairedAt }
}

public struct PairingResult: Sendable {
    public var device: PairedDevice
    public var channel: LinkChannel
}

/// Reine Rechenschritte des Protokolls (bitgleich zu Android `LinkCrypto`).
public enum LinkMath {
    static func lengthPrefix(_ n: Int) -> [UInt8] { [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

    /// SHA-256 über Teile, jeweils mit 4-Byte-Längenpräfix.
    public static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var all: [UInt8] = []
        for p in parts { all += lengthPrefix(p.count); all += p }
        return SHA256Hash.digest(all)
    }

    /// HKDF-SHA256 (RFC 5869).
    public static func hkdf(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let prk = Pbkdf2.hmacSHA256(key: salt, message: ikm)
        var out: [UInt8] = [], previous: [UInt8] = [], counter: UInt8 = 1
        while out.count < length {
            previous = Pbkdf2.hmacSHA256(key: prk, message: previous + info + [counter])
            out += previous.prefix(length - out.count); counter &+= 1
        }
        return out
    }

    /// Kurzer Fingerabdruck einer Identität (QR-Code, Anzeige): 16 Byte.
    public static func fingerprint(_ publicKey: [UInt8]) -> [UInt8] { Array(sha256(Array("gt-fp".utf8), publicKey).prefix(16)) }

    /// Sechsstelliger Vergleichscode (wie Bluetooth „Numeric Comparison“).
    public static func sas(_ transcript: [UInt8]) -> String {
        let d = sha256(Array("gt-sas".utf8), transcript)
        let v = UInt64(d[0]) << 24 | UInt64(d[1]) << 16 | UInt64(d[2]) << 8 | UInt64(d[3])
        let s = String(v % 1_000_000)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var r: UInt8 = 0; for i in 0..<a.count { r |= a[i] ^ b[i] }; return r == 0
    }

    static func helloTranscript(mode: String?, clientPk: [UInt8], serverPk: [UInt8], binding: [UInt8], serverNonce: [UInt8]) -> [UInt8] {
        sha256(Array("gt-hello".utf8), Array((mode ?? "").utf8), clientPk, serverPk, binding, serverNonce)
    }
    static func sessionTranscript(mode: String?, clientPk: [UInt8], serverPk: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8]) -> [UInt8] {
        sha256(Array("gt-session".utf8), Array((mode ?? "").utf8), clientPk, serverPk, clientNonce, serverNonce)
    }

    /// (Handy→TV, TV→Handy). Bei Wiederverbindung fließt der Kopplungsschlüssel ein.
    static func sessionKeys(mode: String?, shared: [UInt8], linkKey: [UInt8]?, transcript: [UInt8]) -> (clientToServer: [UInt8], serverToClient: [UInt8]) {
        let m = mode == LinkMessage.modeResume
            ? hkdf(ikm: shared + (linkKey ?? []), salt: transcript, info: Array("gt-link-resume".utf8), length: 64)
            : hkdf(ikm: shared, salt: transcript, info: Array("gt-link-pair".utf8), length: 64)
        return (Array(m[0..<32]), Array(m[32..<64]))
    }
}

/// Handy-Seite des Handshakes (der iPhone-Teil; die TV-Seite bleibt bei Android).
public struct LinkClient: Sendable {
    static let nonceSize = 32
    static let maxField = 128
    private let crypto: LinkCryptoPrimitives
    private let nowMs: @Sendable () -> Int64
    public init(crypto: LinkCryptoPrimitives, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.crypto = crypto; self.nowMs = nowMs }

    private struct ServerHello { var tvId: String; var tvName: String; var pkBytes: [UInt8]; var identityBytes: [UInt8]; var nonce: [UInt8] }

    /// Kopplung. Mit `expectedFingerprint` und `token` (QR-Code) ohne Rückfrage; sonst zeigt `onSas` den Vergleichscode,
    /// den der Nutzer am Fernseher bestätigt.
    public func pair(transport: LinkFrameTransport, deviceId: String, deviceName: String, expectedFingerprint: [UInt8]?, token: String?, onSas: (String) -> Void) async throws -> PairingResult {
        let eph = try crypto.newKeyPair()
        let clientNonce = [UInt8](crypto.randomBytes(Self.nonceSize))
        let commit = LinkMath.sha256(clientNonce)
        let clientPk = [UInt8](eph.publicKey)
        try await writeMessage(transport, LinkMessage(
            t: LinkMessage.hello, v: LinkMessage.protocolVersion, mode: LinkMessage.modePair, deviceId: deviceId, name: deviceName,
            pk: LinkB64.encode(eph.publicKey), commit: LinkB64.encode(Data(commit))))
        let server = try await readServerHello(transport, mode: LinkMessage.modePair, clientPk: clientPk, binding: commit)
        if let expected = expectedFingerprint, !LinkMath.constantTimeEquals(LinkMath.fingerprint(server.identityBytes), expected) { throw LinkRejectedError(reason: "fingerprint") }
        try await writeMessage(transport, LinkMessage(t: LinkMessage.reveal, nonce: LinkB64.encode(Data(clientNonce))))
        let transcript = LinkMath.sessionTranscript(mode: LinkMessage.modePair, clientPk: clientPk, serverPk: server.pkBytes, clientNonce: clientNonce, serverNonce: server.nonce)
        let shared = [UInt8](try crypto.ecdh(privateKey: eph.privateKey, peerPublicKey: Data(server.pkBytes)))
        let keys = LinkMath.sessionKeys(mode: LinkMessage.modePair, shared: shared, linkKey: nil, transcript: transcript)
        let channel = makeChannel(transport, keys, server)
        if token == nil { onSas(LinkMath.sas(transcript)) }
        try await channel.send(LinkMessage(t: LinkMessage.auth, token: token))
        let answer = try await channel.receive()
        if answer.t == LinkMessage.rejected { throw LinkRejectedError(reason: answer.reason ?? "denied") }
        guard answer.t == LinkMessage.paired, let linkKey = answer.linkKey else { throw LinkError("Unerwartete Antwort \(answer.t)") }
        return PairingResult(device: PairedDevice(id: server.tvId, name: server.tvName, linkKey: linkKey, identity: LinkB64.encode(Data(server.identityBytes)), pairedAt: nowMs()), channel: channel)
    }

    /// Wiederverbindung mit einem gekoppelten Fernseher; prüft dessen gespeicherte Identität.
    public func resume(transport: LinkFrameTransport, deviceId: String, deviceName: String, tv: PairedDevice) async throws -> LinkChannel {
        let eph = try crypto.newKeyPair()
        let clientNonce = [UInt8](crypto.randomBytes(Self.nonceSize))
        let clientPk = [UInt8](eph.publicKey)
        try await writeMessage(transport, LinkMessage(t: LinkMessage.hello, v: LinkMessage.protocolVersion, mode: LinkMessage.modeResume, deviceId: deviceId, name: deviceName,
                                                      pk: LinkB64.encode(eph.publicKey), nonce: LinkB64.encode(Data(clientNonce))))
        let server = try await readServerHello(transport, mode: LinkMessage.modeResume, clientPk: clientPk, binding: clientNonce)
        guard let stored = tv.identity.flatMap(LinkB64.decode), LinkMath.constantTimeEquals([UInt8](stored), server.identityBytes) else { throw LinkRejectedError(reason: "identity") }
        guard let linkKey = LinkB64.decode(tv.linkKey) else { throw LinkError("Kopplungsschlüssel unlesbar") }
        let transcript = LinkMath.sessionTranscript(mode: LinkMessage.modeResume, clientPk: clientPk, serverPk: server.pkBytes, clientNonce: clientNonce, serverNonce: server.nonce)
        let shared = [UInt8](try crypto.ecdh(privateKey: eph.privateKey, peerPublicKey: Data(server.pkBytes)))
        let keys = LinkMath.sessionKeys(mode: LinkMessage.modeResume, shared: shared, linkKey: [UInt8](linkKey), transcript: transcript)
        let channel = makeChannel(transport, keys, server)
        try await channel.send(LinkMessage(t: LinkMessage.auth))
        let answer = try await channel.receive()
        guard answer.t == LinkMessage.welcome else { throw LinkRejectedError(reason: answer.reason ?? answer.t) }
        return channel
    }

    private func writeMessage(_ t: LinkFrameTransport, _ m: LinkMessage) async throws { try await t.write(try LinkMessage.encode(m)) }
    private func readMessage(_ t: LinkFrameTransport) async throws -> LinkMessage { try LinkMessage.decode(try await t.read()) }

    private func readServerHello(_ transport: LinkFrameTransport, mode: String, clientPk: [UInt8], binding: [UInt8]) async throws -> ServerHello {
        let hello = try await readMessage(transport)
        if hello.t == LinkMessage.rejected { throw LinkRejectedError(reason: hello.reason ?? "rejected") }
        guard hello.t == LinkMessage.hello, hello.v == LinkMessage.protocolVersion else { throw LinkError("Unbekanntes Protokoll") }
        guard let pk = hello.pk.flatMap(LinkB64.decode) else { throw LinkError("Schlüssel fehlt") }
        guard let ident = hello.identity.flatMap(LinkB64.decode) else { throw LinkError("Identität fehlt") }
        guard let nonce = hello.nonce.flatMap(LinkB64.decode), nonce.count == Self.nonceSize else { throw LinkError("Nonce fehlt") }
        guard let sig = hello.signature.flatMap(LinkB64.decode) else { throw LinkError("Signatur fehlt") }
        let transcript = LinkMath.helloTranscript(mode: mode, clientPk: clientPk, serverPk: [UInt8](pk), binding: binding, serverNonce: [UInt8](nonce))
        guard crypto.verify(publicKey: ident, message: Data(transcript), signature: sig) else { throw LinkRejectedError(reason: "signature") }
        guard let id = hello.deviceId else { throw LinkError("TV-ID fehlt") }
        return ServerHello(tvId: String(id.prefix(Self.maxField)), tvName: String((hello.name ?? "Fernseher").prefix(Self.maxField)), pkBytes: [UInt8](pk), identityBytes: [UInt8](ident), nonce: [UInt8](nonce))
    }

    private func makeChannel(_ transport: LinkFrameTransport, _ keys: (clientToServer: [UInt8], serverToClient: [UInt8]), _ s: ServerHello) -> LinkChannel {
        LinkChannel(transport: transport,
                    sendCipher: LinkFrameCipher(key: Data(keys.clientToServer), direction: LinkFrameCipher.clientToServer, crypto: crypto),
                    receiveCipher: LinkFrameCipher(key: Data(keys.serverToClient), direction: LinkFrameCipher.serverToClient, crypto: crypto),
                    peerId: s.tvId, peerName: s.tvName)
    }
}
