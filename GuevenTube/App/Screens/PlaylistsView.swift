import SwiftUI
import GuevenCore

/// Eigene (lokale) Merklisten: anlegen, umbenennen, löschen. „Später ansehen“ hat in der Mediathek einen eigenen Abschnitt.
struct PlaylistsView: View {
    @State private var lists: [LocalPlaylistWithCount] = []
    @State private var newName = ""
    @State private var showNew = false
    @State private var renaming: LocalPlaylistWithCount?
    @State private var renameText = ""
    @State private var message: String?
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.red).font(.footnote) }
            if lists.isEmpty { Text("Noch keine Playlist.").foregroundStyle(.secondary) }
            ForEach(lists, id: \.id) { p in
                NavigationLink { PlaylistDetailView(playlist: p) } label: {
                    HStack { Text(p.name); Spacer(); Text("\(p.itemCount)").foregroundStyle(.secondary) }
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) { Task { await library.deletePlaylist(p.id); await reload() } }
                    Button("Umbenennen") { renameText = p.name; renaming = p }.tint(.blue)
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar { Button { newName = ""; showNew = true } label: { Image(systemName: "plus") } }
        .alert("Neue Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Anlegen") { Task { await create() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Speichern") { Task { await rename() } }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
        .task { await reload() }
    }

    private func reload() async { lists = await library.playlists().filter { $0.name != LocalLibrary.watchLater } }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name == LocalLibrary.watchLater { message = "Dieser Name ist reserviert."; return }
        message = nil
        await library.playlistId(named: name)
        await reload()
    }

    private func rename() async {
        guard let p = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty else { return }
        if name == LocalLibrary.watchLater { message = "Dieser Name ist reserviert."; return }
        do { try await library.renamePlaylist(p.id, to: name); message = nil }
        catch { message = "Es gibt schon eine Playlist mit diesem Namen." }
        await reload()
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var app: AppModel
    let playlist: LocalPlaylistWithCount
    @State private var items: [VideoItem] = []
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            if items.isEmpty { Text("Die Playlist ist leer. Im Player über „Zu Playlist“ hinzufügen.").foregroundStyle(.secondary) }
            if !items.isEmpty {
                Button { app.playQueue(items) } label: { Label("Alle abspielen", systemImage: "play.fill") }
            }
            ForEach(items, id: \.videoId) { v in
                Button { app.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                    .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.remove(videoId: v.videoId, from: playlist.id); await reload() } } }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .task { await reload() }
    }

    private func reload() async {
        items = await library.items(in: playlist.id).map {
            VideoItem(videoId: $0.videoId, title: $0.title, channelName: $0.channelName, channelId: nil, thumbnailUrl: $0.thumbnailUrl,
                      durationSeconds: $0.durationSeconds, viewCountText: nil, publishedText: nil, isLive: false)
        }
    }
}

/// Menü „Zu Playlist“ im Player; legt auf Wunsch eine neue Liste an.
struct AddToPlaylistMenu: View {
    let video: VideoItem
    @State private var lists: [LocalPlaylistWithCount] = []
    @State private var showNew = false
    @State private var newName = ""
    private let library = AppEnvironment.shared.library

    var body: some View {
        Menu("Zu Playlist") {
            ForEach(lists, id: \.id) { p in
                Button(p.name) { Task { await library.add(video, to: p.id) } }
            }
            Button("Neue Playlist …") { newName = ""; showNew = true }
        }
        .onAppear { Task { lists = await library.playlists().filter { $0.name != LocalLibrary.watchLater } } }
        .alert("Neue Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Anlegen und hinzufügen") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != LocalLibrary.watchLater else { return }
                Task { let id = await library.playlistId(named: name); await library.add(video, to: id) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}
