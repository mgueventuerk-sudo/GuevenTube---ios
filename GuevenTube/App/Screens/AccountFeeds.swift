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
            if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText) }
            ForEach(videos, id: \.videoId) { v in
                VideoRow(item: v)
                    .onAppear { if v.videoId == videos.last?.videoId { Task { await more() } } }
            }
        }
        .gtList()
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
        } catch { self.error = GTError.text(error) }
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
    @State private var localChannels: [LocalSubscription] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if !localChannels.isEmpty {
                Section("Auf diesem Gerät") {
                    ForEach(localChannels, id: \.channelId) { c in
                        Button { app.channelRoute = ChannelRef(channelId: c.channelId, name: c.name, avatarUrl: c.avatarUrl) } label: { Text(c.name) }.buttonStyle(.plain)
                            .swipeActions { Button("Entfernen", role: .destructive) { Task { await AppEnvironment.shared.library.unsubscribe(c.channelId); await loadLocal() } } }
                    }
                }
            }
            if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText) }
            ForEach(channels, id: \.channelId) { c in
                Button { app.channelRoute = ChannelRef(channelId: c.channelId, name: c.name, avatarUrl: c.avatarUrl) } label: { HStack(spacing: 12) {
                    AsyncImage(url: c.avatarUrl.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 40, height: 40).clipShape(Circle())
                    Text(c.name)
                    Spacer()
                    if c.hasNewContent { Circle().fill(.blue).frame(width: 8, height: 8) }
                } }.buttonStyle(.plain)
            }
        }
        .gtList()
        .overlay { if loading && channels.isEmpty { ProgressView() } }
        .navigationTitle("Abos")
        .refreshable { await load() }
        .task { await loadLocal(); if channels.isEmpty { await load() } }
    }

    private func loadLocal() async { localChannels = await AppEnvironment.shared.library.subscriptions() }

    private func load() async {
        loading = true; defer { loading = false }
        guard await app.env.innerTube.hasAccount() else { error = nil; return }
        do {
            channels = InnerTubeParser.parseSubscriptionChannels(try await app.env.innerTube.browse(browseId: InnerTubeService.browseSubscriptions))
            error = channels.isEmpty && localChannels.isEmpty ? "Keine Abos gefunden." : nil
        } catch { self.error = GTError.text(error) }
    }
}
