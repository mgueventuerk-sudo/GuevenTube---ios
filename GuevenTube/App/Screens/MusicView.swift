import SwiftUI
import GuevenCore

struct MusicView: View {
    @EnvironmentObject var music: MusicModel
    @EnvironmentObject var app: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let e = music.error { Text(e).foregroundStyle(.red) }
                ForEach(Array(music.sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        let songs = section.items.compactMap { item -> MusicSong? in if case .song(let s) = item { return s }; return nil }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            row(item, songs: songs)
                        }
                    }
                }
            }
            .gtList()
            .overlay { if music.loading && music.sections.isEmpty { ProgressView() } }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .navigationTitle("Musik")
            .navigationDestination(for: MusicCollection.self) { MusicDetailView(collection: $0) }
            .searchable(text: $query, prompt: "Songs, Alben, Interpreten")
            .onSubmit(of: .search) { Task { await music.search(query) } }
            .task { if music.sections.isEmpty { await music.loadHome() } }
        }
    }

    @ViewBuilder private func row(_ item: MusicItem, songs: [MusicSong]) -> some View {
        let content = HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(item.title).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        if case .song(let s) = item {
            Button { music.play(songs, index: songs.firstIndex(of: s) ?? 0) } label: { content }.buttonStyle(.plain)
        } else {
            if case .collection(let c) = item { NavigationLink(value: c) { content } }
        }
    }
}

/// Kleine Steuerleiste unten, solange ein Titel läuft.
struct MiniPlayer: View {
    @EnvironmentObject var music: MusicModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let song = music.queue.current {
            HStack {
                VStack(alignment: .leading) {
                    Text(song.title).font(.subheadline).lineLimit(1)
                    Text(song.artists ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { music.previous() } label: { Image(systemName: "backward.fill") }
                Button { app.player.toggle() } label: { Image(systemName: app.player.state == .playing ? "pause.fill" : "play.fill") }
                Button { music.next() } label: { Image(systemName: "forward.fill") }
            }
            .padding().background(.regularMaterial)
        }
    }
}

/// Album, Playlist oder Interpret: Kopf, Titel zum Abspielen und weitere Abschnitte (Alben, Ähnliches).
struct MusicDetailView: View {
    @EnvironmentObject var music: MusicModel
    let collection: MusicCollection
    @State private var detail: MusicDetail?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText) }
            if let d = detail {
                Section {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: d.thumbnailUrl ?? collection.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                            .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(d.title.isEmpty ? collection.title : d.title).font(.headline)
                            if let s = d.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if !d.tracks.isEmpty {
                        Button { music.play(d.tracks, index: 0) } label: { Label("Alle abspielen", systemImage: "play.fill") }
                    }
                }
                if !d.tracks.isEmpty {
                    Section("Titel") {
                        ForEach(Array(d.tracks.enumerated()), id: \.offset) { i, t in
                            Button { music.play(d.tracks, index: i) } label: {
                                VStack(alignment: .leading) {
                                    Text(t.title).lineLimit(1)
                                    if let a = t.artists { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                ForEach(Array(d.sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .collection(let c): NavigationLink(value: c) { Text(c.title).lineLimit(1) }
                            case .song(let s): Button(s.title) { music.play([s]) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if detail == nil && error == nil { ProgressView() } }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let d = try await music.detail(collection.browseId)
            detail = d
            if d.tracks.isEmpty && d.sections.isEmpty { error = "Keine Inhalte gefunden." }
        } catch { self.error = GTError.text(error) }
    }
}
