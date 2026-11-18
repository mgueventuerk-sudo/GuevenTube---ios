import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: Nachrichten (kompatibel zu Android `LinkProtocol.kt`)

/// Ein Video, wie es zwischen Handy und TV übertragen wird (nur öffentliche Metadaten).
public struct LinkVideo: Codable, Equatable, Sendable {
    public var videoId: String
    public var title: String
    public var channelName: String?
    public var channelId: String?
    public var thumbnailUrl: String?
    public var durationSeconds: Int64?
    public var isLive: Bool
    public init(videoId: String, title: String = "", channelName: String? = nil, channelId: String? = nil, thumbnailUrl: String? = nil, durationSeconds: Int64? = nil, isLive: Bool = false) {
        self.videoId = videoId; self.title = title; self.channelName = channelName; self.channelId = channelId
        self.thumbnailUrl = thumbnailUrl; self.durationSeconds = durationSeconds; self.isLive = isLive
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        durationSeconds = try c.decodeIfPresent(Int64.self, forKey: .durationSeconds)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
    }
    private enum K: String, CodingKey { case videoId, title, channelName, channelId, thumbnailUrl, durationSeconds, isLive }
}

/// Wiedergabezustand des Fernsehers für die Fernbedienung am Handy.
public struct LinkPlayerState: Codable, Equatable, Sendable {
    public var videoId: String?
    public var title = ""
    public var author = ""
    public var thumbnailUrl: String?
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public var isPlaying = false
    public var isBuffering = false
    public var isLive = false
    public var queue: [LinkVideo] = []
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        isBuffering = try c.decodeIfPresent(Bool.self, forKey: .isBuffering) ?? false
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        queue = try c.decodeIfPresent([LinkVideo].self, forKey: .queue) ?? []
    }
    private enum K: String, CodingKey { case videoId, title, author, thumbnailUrl, positionMs, durationMs, isPlaying, isBuffering, isLive, queue }
}

/// Fortschritt eines Videos für den Abgleich des Verlaufs.
public struct LinkProgress: Codable, Equatable, Sendable {
    public var videoId: String
    public var positionMs: Int64
    public var durationMs: Int64
    public var updatedAt: Int64
    public var title: String?
    public var channelName: String?
    public var thumbnailUrl: String?
    public init(videoId: String, positionMs: Int64, durationMs: Int64, updatedAt: Int64, title: String? = nil, channelName: String? = nil, thumbnailUrl: String? = nil) {
        self.videoId = videoId; self.positionMs = positionMs; self.durationMs = durationMs; self.updatedAt = updatedAt
        self.title = title; self.channelName = channelName; self.thumbnailUrl = thumbnailUrl
    }
    public init(_ e: WatchProgressEntry) { self.init(videoId: e.videoId, positionMs: e.positionMs, durationMs: e.durationMs, updatedAt: e.updatedAt, title: e.title, channelName: e.channelName, thumbnailUrl: e.thumbnailUrl) }
    public var entry: WatchProgressEntry { WatchProgressEntry(videoId: videoId, positionMs: positionMs, durationMs: durationMs, updatedAt: updatedAt, title: title, channelName: channelName, thumbnailUrl: thumbnailUrl) }
}

/// Eine Nachricht. Flach statt polymorph; unbekannte Felder werden ignoriert, `nil` wird nicht geschrieben.
public struct LinkMessage: Codable, Equatable, Sendable {
    public var t: String
    public var v: Int?, mode: String?, deviceId: String?, name: String?, pk: String?, identity: String?, signature: String?
    public var commit: String?, nonce: String?, token: String?, linkKey: String?, reason: String?
    public var video: LinkVideo?, startMs: Int64?, action: String?, value: Int64?, text: String?, submit: Bool?
    public var state: LinkPlayerState?, progress: [LinkProgress]?
    public init(t: String, v: Int? = nil, mode: String? = nil, deviceId: String? = nil, name: String? = nil, pk: String? = nil, identity: String? = nil,
                signature: String? = nil, commit: String? = nil, nonce: String? = nil, token: String? = nil, linkKey: String? = nil, reason: String? = nil,
                video: LinkVideo? = nil, startMs: Int64? = nil, action: String? = nil, value: Int64? = nil, text: String? = nil, submit: Bool? = nil,
                state: LinkPlayerState? = nil, progress: [LinkProgress]? = nil) {
        self.t = t; self.v = v; self.mode = mode; self.deviceId = deviceId; self.name = name; self.pk = pk; self.identity = identity
        self.signature = signature; self.commit = commit; self.nonce = nonce; self.token = token; self.linkKey = linkKey; self.reason = reason
        self.video = video; self.startMs = startMs; self.action = action; self.value = value; self.text = text; self.submit = submit
        self.state = state; self.progress = progress
    }

    // Handshake
    public static let hello = "hello", reveal = "reveal", auth = "auth", paired = "paired", welcome = "welcome", rejected = "rejected"
    // Handy → TV
    public static let play = "play", queueAdd = "queueAdd", queueClear = "queueClear", control = "ctl", text = "text", getState = "getState"
    // TV → Handy
    public static let state = "state"
    // beide Richtungen
    public static let progress = "progress", ping = "ping", pong = "pong", bye = "bye"
    public static let modePair = "pair", modeResume = "resume"
    public static let actionToggle = "toggle", actionPlay = "play", actionPause = "pause", actionSeekTo = "seekTo", actionSeekBy = "seekBy", actionStop = "stop", actionNext = "next"
    public static let protocolVersion = 1

    static func encode(_ m: LinkMessage) throws -> Data { try JSONEncoder().encode(m) }
    static func decode(_ d: Data) throws -> LinkMessage { try JSONDecoder().decode(LinkMessage.self, from: d) }
}

public enum LinkB64 {
    /// Base64url ohne Auffüllung (wie `Base64.getUrlEncoder().withoutPadding()`).
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if t.contains("=") { return nil }
        switch t.count % 4 { case 0: break; case 2: t += "=="; case 3: t += "="; default: return nil }
        return Data(base64Encoded: t)
    }
}

public struct LinkError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(_ m: String) { message = m }
}

/// Die Gegenstelle hat die Verbindung abgelehnt (`unknown`, `denied`, `fingerprint`, `identity`, `signature` …).
public struct LinkRejectedError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public var description: String { "Verbindung abgelehnt: \(reason)" }
}

// MARK: Rahmen

/// Längenpräfix (4 Byte, Big Endian) mit fester Obergrenze gegen Speicher-Angriffe.
public enum LinkFraming {
    public static let maxFrame = 256 * 1024
    public static func encode(_ frame: Data) throws -> Data {
        guard frame.count <= maxFrame else { throw LinkError("Rahmen zu groß") }
        let n = UInt32(frame.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) + frame
    }
    public static func length(ofHeader h: Data) throws -> Int {
        guard h.count == 4 else { throw LinkError("Ungültiger Kopf") }
        let b = [UInt8](h)
        let n = Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        guard n > 0, Int(n) <= maxFrame else { throw LinkError("Ungültige Rahmenlänge \(n)") }
        return Int(n)
    }
}

/// Rohe Rahmen über TCP (iOS: Network.framework). Muss die Aufrufreihenfolge von `write` einhalten.
public protocol LinkFrameTransport: Sendable {
    func read() async throws -> Data
    func write(_ frame: Data) async throws
    func close()
}

// MARK: Kryptografie

public struct LinkKeyPair: Sendable {
    /// X.509/SPKI (wie Android `PublicKey.encoded`).
    public var publicKey: Data
    /// Undurchsichtig; wird nur an denselben Anbieter zurückgegeben.
    public var privateKey: Data
    public init(publicKey: Data, privateKey: Data) { self.publicKey = publicKey; self.privateKey = privateKey }
}

/// Plattform-Bausteine: P-256-ECDH/ECDSA und AES-256-GCM (Apple: CryptoKit).
public protocol LinkCryptoPrimitives: Sendable {
    func randomBytes(_ count: Int) -> Data
    func newKeyPair() throws -> LinkKeyPair
    /// Gemeinsames Geheimnis = X-Koordinate (32 Byte), wie JCA `KeyAgreement("ECDH")`.
    func ecdh(privateKey: Data, peerPublicKey: Data) throws -> Data
    func sign(privateKey: Data, message: Data) throws -> Data
    func verify(publicKey: Data, message: Data, signature: Data) -> Bool
    /// Ausgabe: Chiffretext ‖ 16-Byte-Tag (wie JCA `AES/GCM/NoPadding`).
    func seal(key: Data, nonce: Data, plaintext: Data) throws -> Data
    func open(key: Data, nonce: Data, ciphertext: Data) throws -> Data
}

#if canImport(CryptoKit)
public struct CryptoKitLinkPrimitives: LinkCryptoPrimitives {
    public init() {}
    public func randomBytes(_ count: Int) -> Data { var g = SystemRandomNumberGenerator(); return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }) }
    public func newKeyPair() throws -> LinkKeyPair {
        let k = P256.KeyAgreement.PrivateKey()
        return LinkKeyPair(publicKey: k.publicKey.derRepresentation, privateKey: k.rawRepresentation)
    }
    public func ecdh(privateKey: Data, peerPublicKey: Data) throws -> Data {
        let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peer = try P256.KeyAgreement.PublicKey(derRepresentation: peerPublicKey)
        return try priv.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
    public func sign(privateKey: Data, message: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: message).derRepresentation
    }
    public func verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let k = try? P256.Signing.PublicKey(derRepresentation: publicKey), let s = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return k.isValidSignature(s, for: message)
    }
    public func seal(key: Data, nonce: Data, plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        return box.ciphertext + box.tag
    }
    public func open(key: Data, nonce: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw LinkError("Rahmen zu kurz") }
        let split = ciphertext.count - 16
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.prefix(split), tag: ciphertext.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }
}
#endif

/// Verschlüsselung einer Richtung: AES-256-GCM mit Zähler-Nonce (Richtung ‖ Zähler). Nicht threadsicher – je Richtung ein Objekt.
public final class LinkFrameCipher: @unchecked Sendable {
    public static let clientToServer: Int32 = 1
    public static let serverToClient: Int32 = 2
    private let key: Data, direction: Int32, crypto: LinkCryptoPrimitives
    private var counter: UInt64 = 0
    public init(key: Data, direction: Int32, crypto: LinkCryptoPrimitives) { self.key = key; self.direction = direction; self.crypto = crypto }

    func nonce(_ value: UInt64) -> Data {
        var n = Data(); let d = UInt32(bitPattern: direction)
        for s in stride(from: 24, through: 0, by: -8) { n.append(UInt8((d >> UInt32(s)) & 0xFF)) }
        for s in stride(from: 56, through: 0, by: -8) { n.append(UInt8((value >> UInt64(s)) & 0xFF)) }
        return n
    }
    public func seal(_ plaintext: Data) throws -> Data { defer { counter += 1 }; return try crypto.seal(key: key, nonce: nonce(counter), plaintext: plaintext) }
    /// Wirft bei Manipulation, falscher Reihenfolge oder Wiederholung; der Zähler rückt nur bei Erfolg vor.
    public func open(_ ciphertext: Data) throws -> Data {
        let p = try crypto.open(key: key, nonce: nonce(counter), ciphertext: ciphertext); counter += 1; return p
    }
}

/// Verschlüsselter Kanal nach erfolgreichem Handshake. `send` ist aufrufreihenfolge-sicher, `receive` nur aus einer Leseschleife.
public final class LinkChannel: @unchecked Sendable {
    private let transport: LinkFrameTransport
    private let sendCipher: LinkFrameCipher, receiveCipher: LinkFrameCipher
    private let sendGate = AsyncLimiter(1)
    public let peerId: String, peerName: String

    init(transport: LinkFrameTransport, sendCipher: LinkFrameCipher, receiveCipher: LinkFrameCipher, peerId: String, peerName: String) {
        self.transport = transport; self.sendCipher = sendCipher; self.receiveCipher = receiveCipher; self.peerId = peerId; self.peerName = peerName
    }

    public func send(_ message: LinkMessage) async throws {
        await sendGate.acquire()
        do {
            try await transport.write(try sendCipher.seal(try LinkMessage.encode(message)))
            await sendGate.release()
        } catch { await sendGate.release(); throw error }
    }
    public func receive() async throws -> LinkMessage { try LinkMessage.decode(try receiveCipher.open(try await transport.read())) }
    public func close() { transport.close() }
}
