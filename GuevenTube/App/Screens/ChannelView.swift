import SwiftUI
import GuevenCore

struct ChannelRef: Identifiable, Hashable {
    var id: String { channelId }
    let channelId: String
    var name: String
    var avatarUrl: String?
}

/// Kanalseite: Videos des Kanals (`browse` mit Kanal-ID) und lokales Abonnieren.
struct ChannelView: View {
    @EnvironmentObject var app: AppModel
    let channel: ChannelRef
    @State private var shelves: [Shelf] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var error: String?
    @State private var subscribed = false
    @StateObject private var downloads = DownloadsModel()
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            // Abonnieren steht im Inhalt, nicht in der Leiste: Dort sitzt im Sheet schon „Fertig“.
            HStack {
                Button { Task { await toggle() } } label: {
                    Label(subscribed ? "Abonniert" : "Abonnieren", systemImage: subscribed ? "checkmark" : "bell")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 36)
                        .background(subscribed ? GT.surface : GT.accent, in: Capsule())
                        .foregroundStyle(subscribed ? Color.primary : Color.white)
                }
                .buttonStyle(.plain).frame(minHeight: GT.Metric.touch)
                Spacer()
                let videos = shelves.flatMap(\.items).filter { !$0.isLive }
                if !videos.isEmpty {
                    DownloadQualityMenu(title: "\(Set(videos.map(\.videoId)).count) Videos laden") { downloads.enqueue(videos, quality: $0) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .listRowBackground(GT.background).listRowSeparator(.hidden)
            if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText).listRowBackground(GT.background) }
            ForEach(Array(shelves.enumerated()), id: \.offset) { _, shelf in
                Section(shelf.title) {
                    ForEach(shelf.items, id: \.videoId) { v in
                        VideoRow(item: v, style: .card, onPlay: { Task { await open(v) } })
                    }
                }
            }
            if continuation != nil {
                Button("Mehr laden") { Task { await more() } }.disabled(loading)
            }
        }
        .gtList()
        .overlay { if loading && shelves.isEmpty { ProgressView() } }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .downloadNotice(downloads)
        .task { subscribed = await library.isSubscribed(channel.channelId); if shelves.isEmpty { await first() } }
    }

    /// Das Kanal-Sheet muss weg sein, bevor der Player als Vollbild erscheint; sonst verwirft SwiftUI die zweite Präsentation.
    private func open(_ v: VideoItem) async {
        let wasPlayerShown = app.showPlayer
        app.channelRoute = nil
        if !wasPlayerShown { try? await Task.sleep(nanoseconds: 400_000_000) }
        app.play(v)
    }

    private func toggle() async {
        if subscribed { await library.unsubscribe(channel.channelId) }
        else { await library.subscribe(channelId: channel.channelId, name: channel.name, avatarUrl: channel.avatarUrl) }
        subscribed = await library.isSubscribed(channel.channelId)
    }

    private func first() async {
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseFeed(try await app.env.innerTube.browse(browseId: channel.channelId), defaultShelfTitle: "Videos")
            shelves = page.shelves; continuation = page.continuation
            error = shelves.isEmpty ? "Keine Videos gefunden." : nil
        } catch { self.error = GTError.text(error) }
    }

    private func more() async {
        guard let c = continuation, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseFeed(try await app.env.innerTube.browse(browseId: nil, continuation: c), defaultShelfTitle: "Mehr")
            shelves += page.shelves; continuation = page.continuation
        } catch { continuation = nil }
    }
}
