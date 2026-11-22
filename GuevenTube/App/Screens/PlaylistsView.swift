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

    private func reload() async { lists = await library.playlists().filter { !LocalLibrary.reservedNames.contains($0.name) } }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if LocalLibrary.reservedNames.contains(name) { message = "Dieser Name ist reserviert."; return }
        message = nil
        await library.playlistId(named: name)
        await reload()
    }

    private func rename() async {
        guard let p = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty else { return }
        if LocalLibrary.reservedNames.contains(name) { message = "Dieser Name ist reserviert."; return }
        do { try await library.renamePlaylist(p.id, to: name); message = nil }
        catch { message = "Es gibt schon eine Playlist mit diesem Namen." }
        await reload()
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var app: AppModel
    let playlist: LocalPlaylistWithCount
    @State private var items: [VideoItem] = []
    @StateObject private var downloads = DownloadsModel()
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            if items.isEmpty { Text("Die Playlist ist leer. Im Player über „Zu Playlist“ hinzufügen.").foregroundStyle(.secondary) }
            if !items.isEmpty {
                Button { app.playQueue(items) } label: { Label("Alle abspielen", systemImage: "play.fill") }
                DownloadAllMenu(videos: items, downloads: downloads)
            }
            ForEach(items, id: \.videoId) { v in
                VideoRow(item: v)
                    .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.remove(videoId: v.videoId, from: playlist.id); await reload() } } }
            }
        }
        .gtList()
        .navigationTitle(playlist.name)
        .downloadNotice(downloads)
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
struct AddToPlaylistMenu<MenuLabel: View>: View {
    let video: VideoItem
    private let label: MenuLabel

    init(video: VideoItem, @ViewBuilder label: () -> MenuLabel) { self.video = video; self.label = label() }
    @State private var lists: [LocalPlaylistWithCount] = []
    @State private var showNew = false
    @State private var newName = ""
    @State private var accountLists: [AccountPlaylist]?
    @State private var newAccountList = false
    @State private var accountError: String?
    private let library = AppEnvironment.shared.library
    private let account = AccountPlaylists(service: AppEnvironment.shared.innerTube)

    var body: some View {
        Menu {
            ForEach(lists, id: \.id) { p in
                Button(p.name) { Task { await library.add(video, to: p.id) } }
            }
            Button("Neue Playlist …") { newName = ""; showNew = true }
            if let accountLists {
                Section("YouTube-Konto") {
                    ForEach(accountLists) { p in
                        Button { toggle(p) } label: { Label(p.title, systemImage: p.containsVideo ? "checkmark.circle.fill" : "plus.circle") }
                    }
                    Button("Neue Konto-Playlist …") { newName = ""; newAccountList = true }
                }
            }
        } label: { label }
        .frame(minHeight: GT.Metric.touch)
        .onAppear {
            Task { lists = await library.playlists().filter { !LocalLibrary.reservedNames.contains($0.name) } }
            Task { await loadAccountLists() }
        }
        .alert("Neue Konto-Playlist", isPresented: $newAccountList) {
            TextField("Name", text: $newName)
            Button("Anlegen (privat)") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    do { try await account.create(title: name, videoId: video.videoId); await loadAccountLists() }
                    catch { accountError = "Playlist konnte nicht angelegt werden." }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("YouTube-Konto", isPresented: Binding(get: { accountError != nil }, set: { if !$0 { accountError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(accountError ?? "") }
        .alert("Neue Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Anlegen und hinzufügen") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !LocalLibrary.reservedNames.contains(name) else { return }
                Task { let id = await library.playlistId(named: name); await library.add(video, to: id) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func loadAccountLists() async {
        guard await AppEnvironment.shared.innerTube.hasAccount() else { accountLists = nil; return }
        accountLists = try? await account.playlists(for: video.videoId)
    }

    private func toggle(_ p: AccountPlaylist) {
        Task {
            do {
                if p.containsVideo { try await account.remove(playlistId: p.playlistId, videoId: video.videoId) }
                else { try await account.add(playlistId: p.playlistId, videoId: video.videoId) }
                await loadAccountLists()
            } catch { accountError = "Änderung im Konto fehlgeschlagen." }
        }
    }
}
