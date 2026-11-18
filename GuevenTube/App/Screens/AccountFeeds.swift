import SwiftUI
import GuevenCore

/// Verlauf des angemeldeten Kontos (`FEhistory`), mit Nachladen.
struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var videos: [VideoItem] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(videos, id: \.videoId) { v in
                Button { app.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                    .onAppear { if v.videoId == videos.last?.videoId { Task { await more() } } }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && videos.isEmpty { ProgressView() } }
        .navigationTitle("Verlauf")
        .refreshable { await first() }
        .task { if videos.isEmpty { await first() } }
    }

    private func first() async {
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseFeed(try await app.env.innerTube.browse(browseId: InnerTubeService.browseHistory), defaultShelfTitle: "Verlauf")
            videos = dedupe(page.shelves.flatMap(\.items)); continuation = page.continuation
            error = videos.isEmpty ? "Kein Verlauf gefunden (Anmeldung nötig?)." : nil
        } catch { self.error = String(describing: error) }
    }

    private func more() async {
        guard let c = continuation, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseFeed(try await app.env.innerTube.browse(browseId: nil, continuation: c), defaultShelfTitle: "Verlauf")
            videos = dedupe(videos + page.shelves.flatMap(\.items)); continuation = page.continuation
        } catch { continuation = nil }   // Weiterladen scheitert still: bisherige Liste bleibt.
    }

    private func dedupe(_ items: [VideoItem]) -> [VideoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.videoId).inserted }
    }
}

/// Abonnierte Kanäle (`FEsubscriptions`); Kanalseiten gibt es noch nicht, deshalb nur die Liste.
struct SubscriptionsView: View {
    @EnvironmentObject var app: AppModel
    @State private var channels: [SubscribedChannel] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(channels, id: \.channelId) { c in
                HStack(spacing: 12) {
                    AsyncImage(url: c.avatarUrl.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 40, height: 40).clipShape(Circle())
                    Text(c.name)
                    Spacer()
                    if c.hasNewContent { Circle().fill(.blue).frame(width: 8, height: 8) }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && channels.isEmpty { ProgressView() } }
        .navigationTitle("Abos")
        .refreshable { await load() }
        .task { if channels.isEmpty { await load() } }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            channels = InnerTubeParser.parseSubscriptionChannels(try await app.env.innerTube.browse(browseId: InnerTubeService.browseSubscriptions))
            error = channels.isEmpty ? "Keine Abos gefunden (Anmeldung nötig?)." : nil
        } catch { self.error = String(describing: error) }
    }
}
