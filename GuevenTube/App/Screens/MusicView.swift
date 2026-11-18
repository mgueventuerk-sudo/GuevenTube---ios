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
            .listStyle(.plain)
            .overlay { if music.loading && music.sections.isEmpty { ProgressView() } }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .navigationTitle("Musik")
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
            content.opacity(0.6) // Alben/Playlists/Interpreten: Detailseite folgt
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
