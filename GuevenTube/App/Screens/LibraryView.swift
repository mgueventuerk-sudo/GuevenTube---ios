import SwiftUI
import GuevenCore

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var music: MusicModel
    /// Gemerkt: wer nur Musik nutzt, sieht beim nächsten Öffnen sofort die Musik-Mediathek.
    @AppStorage(AppMode.key) private var mode = "video"
    @State private var continueWatching: [VideoItem] = []
    @State private var watchLater: [VideoItem] = []
    @State private var signedIn = false
    private let library = AppEnvironment.shared.library

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Bereich", selection: $mode) { Text("Video").tag("video"); Text("Musik").tag("music") }.pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                if mode == "music" {
                    Section {
                        NavigationLink { FavoriteSongsView() } label: {
                            Label("Lieblingssongs (\(music.favorites.count))", systemImage: "heart.fill").foregroundStyle(GT.accent)
                        }
                        NavigationLink { MusicPlaylistsView() } label: { Label("Meine Playlists", systemImage: "music.note.list") }
                        NavigationLink { MusicHistoryView() } label: { Label("Zuletzt gehört", systemImage: "clock.arrow.circlepath") }
                        NavigationLink { DownloadsView(kind: .audio) } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                    }
                } else {
                Section {
                    NavigationLink("Meine Playlists") { PlaylistsView() }
                    NavigationLink("Abos") { SubscriptionsView() }
                    NavigationLink { DownloadsView(kind: .video) } label: { Label("Downloads", systemImage: "arrow.down.circle") }
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
                            VideoRow(item: v)
                                .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.removeProgress(v.videoId); await reload() } } }
                        }
                    }
                }
                if !watchLater.isEmpty {
                    Section("Später ansehen") {
                        ForEach(watchLater, id: \.videoId) { v in
                            VideoRow(item: v)
                                .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.removeFromWatchLater(v.videoId); await reload() } } }
                        }
                    }
                }
                }
            }
            .gtList()
            .navigationTitle("Mediathek")
            .modeToolbar(picker: false)
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
