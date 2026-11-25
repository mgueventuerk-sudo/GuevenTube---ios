import SwiftUI
import Network
import GuevenCore

/// Kurze Rückmeldungen als Banner über der Tab-Leiste (ersetzt Alerts, z. B. nach „Herunterladen“).
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()
    @Published private(set) var text: String?
    private var hide: Task<Void, Never>?

    func show(_ message: String) {
        text = message
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.text = nil }
        }
    }
    func dismiss() { hide?.cancel(); text = nil }
}

struct NoticeBanner: View {
    @ObservedObject var center: NoticeCenter
    var body: some View {
        if let t = center.text {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(GT.accent)
                Text(t).font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { center.dismiss() } label: { Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 32, height: 32) }
                    .accessibilityLabel("Hinweis schließen")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Netzstatus: beim Start ohne Netz öffnet die App die Mediathek (Downloads sind offline nutzbar).
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var isOffline = false
    /// Erster gemeldeter Zustand (nur einmal gesetzt).
    @Published private(set) var firstStatusOffline: Bool?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.isOffline = offline
                if self.firstStatusOffline == nil { self.firstStatusOffline = offline }
            }
        }
        monitor.start(queue: DispatchQueue(label: "gueventube.network"))
    }
}

final class TabRouter: ObservableObject { @Published var tab = 0 }

/// Wischen nach unten schließt eine Mini-Leiste (Video und Musik gleich).
extension View {
    func swipeToClose(_ close: @escaping () -> Void) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { g in
            if g.translation.height > 40, abs(g.translation.width) < 60 { close() }
        })
    }
}

/// „⋯“ für Zeilen, die sonst nur per langem Drücken Aktionen haben.
struct MoreIcon: View {
    var body: some View {
        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(GT.secondaryText)
            .frame(width: GT.Metric.touch, height: GT.Metric.touch).contentShape(Rectangle())
            .accessibilityLabel("Weitere Aktionen")
    }
}

/// Große Kachel für die Mediathek.
struct LibraryTile: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(GT.accent)
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(GT.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
