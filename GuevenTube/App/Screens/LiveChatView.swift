import SwiftUI
import GuevenCore

/// Live-Chat eines laufenden Livestreams (nur lesen). Die Abruflogik steckt getestet in `LiveChatSession`. Apple-only, ungetestet.
struct LiveChatView: View {
    let videoId: String
    @State private var messages: [ChatMessage] = []
    @State private var state: LoadState = .loading
    @Environment(\.dismiss) private var dismiss

    private enum LoadState { case loading, running, unavailable }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(messages) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.author).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(m.text)
                        if let h = m.highlight { Text(h).font(.caption.bold()).foregroundStyle(.orange) }
                    }
                    .id(m.id)
                }
                .gtList()
                .onChange(of: messages.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            .overlay {
                switch state {
                case .loading: ProgressView()
                case .unavailable: Text("Kein Live-Chat verfügbar.").foregroundStyle(.secondary)
                case .running: if messages.isEmpty { Text("Noch keine Nachrichten.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Live-Chat").navigationBarTitleDisplayMode(.inline)
            .doneToolbar { dismiss() }
            .task(id: videoId) { await run() }
        }
    }

    private func run() async {
        state = .loading; messages = []
        let service = AppEnvironment.shared.innerTube
        guard let next = try? await service.webNext(videoId: videoId),
              let token = CommunityParser.findLiveChatToken(next) else { state = .unavailable; return }
        state = .running
        await LiveChatSession(startToken: token).run(
            fetch: { try await service.liveChat(continuation: $0) },
            sleep: { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
            onUpdate: { m in await MainActor.run { messages = m } })
        if messages.isEmpty { state = .unavailable }
    }
}
