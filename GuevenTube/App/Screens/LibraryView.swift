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
                Section { tiles }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                if mode != "music" {
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

    /// Große Kacheln: die häufigsten Ziele ohne Scrollen.
    @ViewBuilder private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            if mode == "music" {
                NavigationLink { FavoriteSongsView() } label: { LibraryTile(title: "Lieblingssongs (\(music.favorites.count))", icon: "heart.fill") }.buttonStyle(.plain)
                NavigationLink { MusicPlaylistsView() } label: { LibraryTile(title: "Playlists", icon: "music.note.list") }.buttonStyle(.plain)
                NavigationLink { MusicHistoryView() } label: { LibraryTile(title: "Zuletzt gehört", icon: "clock.arrow.circlepath") }.buttonStyle(.plain)
                NavigationLink { DownloadsView(kind: .audio) } label: { LibraryTile(title: "Downloads", icon: "arrow.down.circle") }.buttonStyle(.plain)
            } else {
                NavigationLink { DownloadsView(kind: .video) } label: { LibraryTile(title: "Downloads", icon: "arrow.down.circle") }.buttonStyle(.plain)
                NavigationLink { PlaylistsView() } label: { LibraryTile(title: "Playlists", icon: "list.bullet.rectangle") }.buttonStyle(.plain)
                NavigationLink { SubscriptionsView() } label: { LibraryTile(title: "Abos", icon: "person.2") }.buttonStyle(.plain)
                if signedIn {
                    NavigationLink { HistoryView() } label: { LibraryTile(title: "Verlauf", icon: "clock") }.buttonStyle(.plain)
                }
            }
        }
    }

    private func reload() async {
        signedIn = await app.env.innerTube.hasAccount()
        continueWatching = await library.continueWatching()
        watchLater = await library.watchLaterItems()
    }
}
