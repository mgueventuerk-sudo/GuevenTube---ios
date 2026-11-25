import SwiftUI
import GuevenCore

/// Aktionen für einen Titel (lange drücken): als Nächstes, ans Ende der Warteschlange, zu einer Musik-Playlist.
struct SongQueueActions: View {
    let song: MusicSong
    @ObservedObject var music: MusicModel
    var body: some View {
        Button { music.playNext(song) } label: { Label("Als Nächstes spielen", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { music.enqueue(song) } label: { Label("Zur Warteschlange hinzufügen", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Menu {
            if music.playlists.isEmpty { Text("Noch keine Playlist (Mediathek → Musik)") }
            ForEach(music.playlists, id: \.id) { p in Button(p.name) { music.add(song, toPlaylist: p.id) } }
        } label: { Label("Zu Playlist hinzufügen", systemImage: "text.badge.plus") }
    }
}

/// Eine Titelzeile mit Cover (Verlauf, Playlists).
struct MusicSongRow: View {
    let song: MusicSong
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: song.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(song.title).lineLimit(1)
                if let a = song.artists { Text(a).font(.caption).foregroundStyle(GT.secondaryText).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }
}

private func musicSongs(from items: [LocalPlaylistItem]) -> [MusicSong] {
    items.map { MusicSong(videoId: $0.videoId, title: $0.title, artists: $0.channelName, album: nil, thumbnailUrl: $0.thumbnailUrl, durationSeconds: $0.durationSeconds) }
}

/// Eigene Musik-Playlists (getrennt von den Video-Playlists).
struct MusicPlaylistsView: View {
    @EnvironmentObject var music: MusicModel
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
            if lists.isEmpty {
                Text("Noch keine Musik-Playlist. Mit „+“ anlegen, dann Titel lange drücken → „Zu Playlist hinzufügen“.").foregroundStyle(GT.secondaryText)
            }
            ForEach(lists, id: \.id) { p in
                NavigationLink { MusicPlaylistDetailView(playlist: p) } label: {
                    HStack { Text(p.name); Spacer(); Text("\(p.itemCount)").foregroundStyle(.secondary) }
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) { Task { await library.deletePlaylist(p.id); await reload() } }
                    Button("Umbenennen") { renameText = p.name; renaming = p }.tint(.blue)
                }
            }
        }
        .gtList()
        .navigationTitle("Musik-Playlists")
        .toolbar { Button { newName = ""; showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("Neue Playlist") }
        .alert("Neue Musik-Playlist", isPresented: $showNew) {
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

    private func reload() async { lists = await library.musicPlaylists(); await music.reloadPlaylists() }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if await library.musicPlaylistId(named: name) == nil { message = "Dieser Name ist reserviert oder schon vergeben." } else { message = nil }
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

struct MusicPlaylistDetailView: View {
    @EnvironmentObject var music: MusicModel
    let playlist: LocalPlaylistWithCount
    @State private var songs: [MusicSong] = []
    @StateObject private var downloads = DownloadsModel()
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            if songs.isEmpty {
                Text("Die Playlist ist leer. Titel lange drücken → „Zu Playlist hinzufügen“.").foregroundStyle(GT.secondaryText)
            } else {
                Button { music.play(songs, index: 0) } label: { Label("Alle abspielen", systemImage: "play.fill") }
                Button { downloads.enqueue(songs: songs) } label: { Label("Alle herunterladen (\(songs.count))", systemImage: "arrow.down.circle") }
            }
            ForEach(songs, id: \.videoId) { s in
                Button { music.play(songs, index: songs.firstIndex(of: s) ?? 0) } label: { MusicSongRow(song: s) }.buttonStyle(.plain)
                    .swipeActions { Button("Entfernen", role: .destructive) { Task { await library.remove(videoId: s.videoId, from: playlist.id); await reload() } } }
                    .contextMenu {
                        SongQueueActions(song: s, music: music)
                        Button { downloads.enqueue(songs: [s]) } label: { Label("Herunterladen", systemImage: "arrow.down.circle") }
                    }
            }
        }
        .gtList()
        .navigationTitle(playlist.name)
        .downloadNotice(downloads)
        .task { await reload() }
    }

    private func reload() async { songs = musicSongs(from: await library.items(in: playlist.id)) }
}

/// „Zuletzt gehört“: die letzten gespielten Musiktitel, neueste zuerst.
struct MusicHistoryView: View {
    @EnvironmentObject var music: MusicModel
    @State private var songs: [MusicSong] = []
    @State private var confirmClear = false
    @StateObject private var downloads = DownloadsModel()
    private let library = AppEnvironment.shared.library

    var body: some View {
        List {
            if songs.isEmpty {
                Text("Noch nichts gehört.").foregroundStyle(GT.secondaryText)
            }
            ForEach(songs, id: \.videoId) { s in
                Button { music.play(songs, index: songs.firstIndex(of: s) ?? 0) } label: { MusicSongRow(song: s) }.buttonStyle(.plain)
                    .contextMenu {
                        SongQueueActions(song: s, music: music)
                        Button { downloads.enqueue(songs: [s]) } label: { Label("Herunterladen", systemImage: "arrow.down.circle") }
                    }
            }
        }
        .gtList()
        .navigationTitle("Zuletzt gehört")
        .downloadNotice(downloads)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !songs.isEmpty { Button("Leeren", role: .destructive) { confirmClear = true } }
            }
        }
        .confirmationDialog("Verlauf löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Verlauf löschen", role: .destructive) { Task { await library.clearMusicHistory(); await reload() } }
        }
        .task { await reload() }
        // Ein neu gestarteter Titel soll sofort oben stehen.
        .onChange(of: music.queue.current?.videoId) { _, _ in Task { try? await Task.sleep(nanoseconds: 300_000_000); await reload() } }
    }

    private func reload() async { songs = musicSongs(from: await library.musicHistoryItems()) }
}
