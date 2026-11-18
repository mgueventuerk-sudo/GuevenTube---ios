import XCTest
import Network
import GuevenCore
@testable import GuevenTube

/// Prüft die Network.framework-Schicht gegen einen lokalen Echo-Server (der Link-Handshake selbst ist in GuevenCore getestet).
final class LinkTransportTests: XCTestCase {
    func testFrameRoundTripOverLoopback() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.listener")
        listener.newConnectionHandler = { c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data { c.send(content: data, completion: .contentProcessed { _ in }) }
            }
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let transport = try await NWFrameTransport.connect(host: "127.0.0.1", port: Int(try XCTUnwrap(listener.port).rawValue))
        defer { transport.close() }
        let payload = Data("hallo fernseher".utf8)
        try await transport.write(payload)
        let echoed = try await transport.read()
        XCTAssertEqual(echoed, payload)
    }

    func testConnectToClosedPortFails() async {
        do {
            _ = try await NWFrameTransport.connect(host: "127.0.0.1", port: 1, timeout: 2)
            XCTFail("Verbindung zu einem geschlossenen Port darf nicht gelingen")
        } catch {}
    }

    @MainActor
    func testLinkModelStartsIdle() {
        XCTAssertEqual(LinkModel.shared.connection, .idle)
        XCTAssertFalse(LinkModel.shared.isConnected)
    }
}
