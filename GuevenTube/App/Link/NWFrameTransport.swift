import Foundation
import Network
import GuevenCore

/// `LinkFrameTransport` über Network.framework (TCP). Apple-only, ungetestet.
final class NWFrameTransport: LinkFrameTransport, @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    /// Adresse des Gegenübers (für `PairedDevice.host/port`); IPv6-Zonen-ID abgeschnitten.
    var remote: (host: String, port: Int)? {
        guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else { return nil }
        let text = "\(host)"
        return (String(text.split(separator: "%").first ?? ""), Int(port.rawValue))
    }

    static func connect(host: String, port: Int, timeout: TimeInterval = 4) async throws -> NWFrameTransport {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw LinkError("Ungültiger Port") }
        return try await connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p), timeout: timeout)
    }

    /// Wartet bis die Verbindung steht; scheitert nach `timeout` Sekunden.
    static func connect(endpoint: NWEndpoint, timeout: TimeInterval = 4) async throws -> NWFrameTransport {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3   // tote Verbindung nach ~30 s erkennen
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        let queue = DispatchQueue(label: "de.gueventube.link.transport")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWFrameTransport, Error>) in
                var finished = false   // nur auf `queue` benutzt
                connection.stateUpdateHandler = { state in
                    guard !finished else { return }
                    switch state {
                    case .ready:
                        finished = true; connection.stateUpdateHandler = nil
                        cont.resume(returning: NWFrameTransport(connection))
                    case .failed(let e):
                        finished = true; connection.cancel(); cont.resume(throwing: e)
                    case .cancelled:
                        finished = true; cont.resume(throwing: LinkError("Verbindung abgebrochen"))
                    case .waiting:
                        break   // kein Netz/keine Route: weiter warten, Zeitgrenze greift
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { if !finished { connection.cancel() } }
                connection.start(queue: queue)
            }
        } onCancel: { connection.cancel() }
    }

    func read() async throws -> Data {
        let header = try await receive(4)
        return try await receive(try LinkFraming.length(ofHeader: header))
    }

    private func receive(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == n { cont.resume(returning: data) }
                else { cont.resume(throwing: LinkError(isComplete ? "Verbindung beendet" : "Unvollständig gelesen")) }
            }
        }
    }

    func write(_ frame: Data) async throws {
        let data = try LinkFraming.encode(frame)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() { connection.cancel() }
}
