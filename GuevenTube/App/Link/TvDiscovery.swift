import Foundation
import Network
import GuevenCore

struct DiscoveredTv: Identifiable, Equatable {
    var id: String { tvId }
    let tvId: String
    let name: String
    let fingerprint: [UInt8]?
    let endpoint: NWEndpoint
}

/// Sucht `_gueventube._tcp` im WLAN (wie Android NsdManager). Braucht NSBonjourServices + NSLocalNetworkUsageDescription.
/// Die Auflösung zu IP/Port übernimmt `NWConnection` selbst. Apple-only, ungetestet.
final class TvDiscovery {
    static let serviceType = "_gueventube._tcp"
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "de.gueventube.link.browser")
    var onChange: (@Sendable ([DiscoveredTv]) -> Void)?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredTv] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint,
                      case let .bonjour(txt) = r.metadata, let id = txt["id"], !id.isEmpty else { return nil }
                return DiscoveredTv(tvId: id, name: name.hasPrefix("GuevenTube ") ? String(name.dropFirst(11)) : name,
                                    fingerprint: txt["fp"].flatMap { LinkB64.decode($0) }.map { [UInt8]($0) }, endpoint: r.endpoint)
            }
            self?.onChange?(found)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}
