import Foundation
import Network
import SwiftUI
import GuevenCore

/// iPhone als Fernbedienung für den Android-TV (Gegenstück zu `PhoneLinkClient`): suchen, koppeln, verbinden, steuern.
/// Der Handshake selbst (`LinkClient`) ist in GuevenCore getestet; Netzwerk und Oberfläche hier sind Apple-only, ungetestet.
@MainActor
final class LinkModel: ObservableObject {
    enum Connection: Equatable {
        case idle
        case connecting(String)
        case awaitingApproval(name: String, code: String)
        case connected(tvId: String, name: String)
        case failed(String)
    }

    /// Gemeinsame Instanz statt `environmentObject`: ein fehlendes Environment (z. B. in einem Sheet) würde sonst abstürzen.
    static let shared = LinkModel()
    private init() {}

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var tvState = LinkPlayerState()
    @Published private(set) var discovered: [DiscoveredTv] = []
    @Published private(set) var paired: [PairedDevice] = []

    private let env = AppEnvironment.shared
    private let client = LinkClient(crypto: CryptoKitLinkPrimitives())
    private let discovery = TvDiscovery()
    private var channel: LinkChannel?
    private var job: Task<Void, Never>?
    private var reconnectTvId: String?
    private static let maxProgress = 200
    private static let videoId = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")

    var isConnected: Bool { if case .connected = connection { return true } else { return false } }

    func refreshPaired() async { paired = await env.link.load() }

    // MARK: Suche

    func startDiscovery() {
        discovery.onChange = { [weak self] found in Task { @MainActor in self?.discovered = found } }
        discovery.start()
        Task { await refreshPaired() }
    }

    func stopDiscovery() { discovery.stop() }

    // MARK: Koppeln und Verbinden

    /// Kopplung über den Vergleichscode (Code erscheint hier und am Fernseher; dort bestätigen).
    func pair(with tv: DiscoveredTv) {
        startPair(name: tv.name, fingerprint: tv.fingerprint, token: nil) { try await NWFrameTransport.connect(endpoint: tv.endpoint) }
    }

    /// Kopplung über den QR-Code (Fingerabdruck + Token, ohne Rückfrage).
    func pair(with request: PairRequest) {
        startPair(name: request.name, fingerprint: request.fingerprint, token: request.token) {
            try await NWFrameTransport.connect(host: request.host, port: request.port)
        }
    }

    private func startPair(name: String, fingerprint: [UInt8]?, token: String?, open: @escaping () async throws -> NWFrameTransport) {
        disconnect()
        connection = .connecting(name)
        job = Task { [weak self] in
            guard let self else { return }
            let transport: NWFrameTransport
            do { transport = try await open() } catch {
                if !Task.isCancelled { connection = .failed("\(name) ist nicht erreichbar. Sind beide Geräte im selben WLAN?") }
                return
            }
            do {
                let id = await env.link.deviceId(), me = await env.link.deviceName()
                let result = try await client.pair(transport: transport, deviceId: id, deviceName: me, expectedFingerprint: fingerprint, token: token) { code in
                    let spaced = stride(from: 0, to: code.count, by: 3).map { i -> String in
                        let a = code.index(code.startIndex, offsetBy: i), b = code.index(a, offsetBy: 3, limitedBy: code.endIndex) ?? code.endIndex
                        return String(code[a..<b])
                    }.joined(separator: " ")
                    Task { @MainActor in self.connection = .awaitingApproval(name: name, code: spaced) }
                }
                var device = result.device
                if let r = transport.remote { device.host = r.host; device.port = r.port }
                try? await env.link.save(device)
                await refreshPaired()
                await runSession(result.channel, tvId: device.id)
            } catch let e as LinkRejectedError {
                transport.close()
                connection = .failed(Self.message(forPairRejection: e.reason))
            } catch {
                transport.close()
                if !Task.isCancelled { connection = .failed("Kopplung fehlgeschlagen. Bitte am Fernseher einen neuen QR-Code öffnen.") }
            }
        }
    }

    private static func message(forPairRejection reason: String) -> String {
        switch reason {
        case "denied": return "Am Fernseher abgelehnt."
        case "fingerprint", "signature": return "Der Fernseher konnte nicht sicher erkannt werden."
        default: return "Kopplung abgelehnt (\(reason))."
        }
    }

    /// Verbindet mit einem gekoppelten Fernseher (aktuelle Adresse aus Bonjour, sonst die zuletzt gespeicherte).
    func connect(_ tv: PairedDevice) {
        disconnect()
        connection = .connecting(tv.name)
        job = Task { [weak self] in
            guard let self else { return }
            let live = discovered.first { $0.tvId == tv.id }
            let transport: NWFrameTransport
            do {
                if let live { transport = try await NWFrameTransport.connect(endpoint: live.endpoint) }
                else if let host = tv.host, let port = tv.port { transport = try await NWFrameTransport.connect(host: host, port: port) }
                else { connection = .failed("\(tv.name) wurde im WLAN nicht gefunden. Ist GuevenTube am Fernseher geöffnet?"); return }
            } catch {
                if !Task.isCancelled { connection = .failed("\(tv.name) ist nicht erreichbar. Ist GuevenTube am Fernseher geöffnet?") }
                return
            }
            do {
                let channel = try await client.resume(transport: transport, deviceId: await env.link.deviceId(),
                                                      deviceName: await env.link.deviceName(), tv: tv)
                await runSession(channel, tvId: tv.id)
            } catch let e as LinkRejectedError {
                transport.close()
                if e.reason == "unknown" { try? await env.link.remove(tv.id); await refreshPaired() }
                connection = .failed(e.reason == "unknown" ? "Der Fernseher kennt dieses iPhone nicht mehr. Bitte neu koppeln." : "Verbindung abgelehnt.")
            } catch {
                transport.close()
                if !Task.isCancelled { connection = .failed("Verbindung zu \(tv.name) fehlgeschlagen.") }
            }
        }
    }

    func disconnect() {
        job?.cancel(); job = nil
        if let c = channel { Task { try? await c.send(LinkMessage(t: LinkMessage.bye)); c.close() } }
        channel = nil
        tvState = LinkPlayerState()
        connection = .idle
    }

    func forget(_ tvId: String) {
        if case .connected(let id, _) = connection, id == tvId { disconnect() }
        Task { try? await env.link.remove(tvId); await refreshPaired() }
    }

    /// Im Hintergrund hält iOS Sockets nicht offen: schließen und beim Zurückkehren wiederherstellen.
    func suspendForBackground() {
        if case .connected(let id, _) = connection { reconnectTvId = id; disconnect() }
    }

    func resumeFromBackground() {
        guard let id = reconnectTvId else { return }
        reconnectTvId = nil
        Task { await refreshPaired(); if let tv = paired.first(where: { $0.id == id }) { connect(tv) } }
    }

    // MARK: Sitzung

    private func runSession(_ channel: LinkChannel, tvId: String) async {
        self.channel = channel
        connection = .connected(tvId: tvId, name: channel.peerName)
        // Verlauf abgleichen: eigene neueste Einträge senden, Antwort übernehmen (wie Android).
        let mine = await env.library.recentProgress(limit: Self.maxProgress).map(LinkProgress.init)
        try? await channel.send(LinkMessage(t: LinkMessage.progress, progress: mine))
        let keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                do { try await channel.send(LinkMessage(t: LinkMessage.ping)) } catch { channel.close(); return }
            }
        }
        defer { keepAlive.cancel(); channel.close() }
        do {
            while true {
                let m = try await channel.receive()
                switch m.t {
                case LinkMessage.state: if let s = m.state { tvState = s }
                case LinkMessage.progress:
                    let valid = (m.progress ?? []).prefix(Self.maxProgress).filter(Self.isVideoId)
                    _ = await env.library.mergeProgress(valid.map(\.entry))
                case LinkMessage.bye: throw LinkError("bye")
                default: break
                }
            }
        } catch {}
        if self.channel === channel {
            self.channel = nil; tvState = LinkPlayerState()
            if case .connected = connection { connection = .idle }
        }
    }

    private static func isVideoId(_ p: LinkProgress) -> Bool {
        videoId.firstMatch(in: p.videoId, range: NSRange(p.videoId.startIndex..., in: p.videoId)) != nil
    }

    // MARK: Befehle

    func play(_ v: VideoItem, startMs: Int64? = nil) { send(LinkMessage(t: LinkMessage.play, video: Self.link(v), startMs: startMs)) }
    func addToQueue(_ v: VideoItem) { send(LinkMessage(t: LinkMessage.queueAdd, video: Self.link(v))) }
    func clearQueue() { send(LinkMessage(t: LinkMessage.queueClear)) }
    func control(_ action: String, value: Int64? = nil) { send(LinkMessage(t: LinkMessage.control, action: action, value: value)) }
    func sendText(_ text: String, submit: Bool) { send(LinkMessage(t: LinkMessage.text, text: text, submit: submit)) }

    private func send(_ m: LinkMessage) {
        guard let c = channel else { return }
        Task { do { try await c.send(m) } catch { c.close() } }
    }

    private static func link(_ v: VideoItem) -> LinkVideo {
        LinkVideo(videoId: v.videoId, title: v.title, channelName: v.channelName, channelId: v.channelId, thumbnailUrl: v.thumbnailUrl,
                  durationSeconds: v.durationSeconds, isLive: v.isLive)
    }
}
