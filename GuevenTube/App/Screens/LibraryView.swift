import SwiftUI
import GuevenCore

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @State private var continueWatching: [VideoItem] = []
    @State private var watchLater: [VideoItem] = []
    @State private var signedIn = false
    private let library = AppEnvironment.shared.library

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Meine Playlists") { PlaylistsView() }
                    NavigationLink("Abos") { SubscriptionsView() }
                }
                if signedIn {
                    Section("YouTube-Konto") {
                        NavigationLink("Verlauf") { HistoryView() }
                    }
                }
                if continueWatching.isEmpty && watchLater.isEmpty { Text("Noch nichts gespeichert.").foregroundStyle(.secondary) }
                if !continueWatching.isEmpty {
                    Section("Weiterschauen") {
                        ForEach(continueWatching, id: \.videoId) { v in
                            Button { app.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                                .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.removeProgress(v.videoId); await reload() } } }
                        }
                    }
                }
                if !watchLater.isEmpty {
                    Section("Später ansehen") {
                        ForEach(watchLater, id: \.videoId) { v in
                            Button { app.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                                .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.removeFromWatchLater(v.videoId); await reload() } } }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Mediathek")
            .task { await reload() }
            .refreshable { await reload() }
            .onChange(of: app.showPlayer) { _, shown in if !shown { Task { await reload() } } }
        }
    }

    private func reload() async {
        signedIn = await app.env.innerTube.hasAccount()
        continueWatching = await library.continueWatching()
        watchLater = await library.watchLaterItems()
    }
}
