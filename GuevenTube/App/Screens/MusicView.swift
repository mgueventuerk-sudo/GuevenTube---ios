import SwiftUI
import GuevenCore

struct MusicView: View {
    @EnvironmentObject var music: MusicModel
    @EnvironmentObject var app: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { FavoriteSongsView() } label: {
                    Label("Lieblingssongs (\(music.favorites.count))", systemImage: "heart.fill").foregroundStyle(GT.accent)
                }
                if !music.searchQuery.isEmpty { filterChips }
                if let e = music.error { Text(e).foregroundStyle(music.sections.isEmpty ? Color.secondary : Color.red) }
                ForEach(Array(music.sections.enumerated()), id: \.offset) { index, section in
                    Section(section.title) {
                        let songs = section.items.compactMap { item -> MusicSong? in if case .song(let s) = item { return s }; return nil }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { i, item in
                            row(item, songs: songs)
                                .onAppear {
                                    if index == music.sections.count - 1, i >= section.items.count - 3 { Task { await music.loadMore() } }
                                }
                        }
                    }
                }
                if music.loadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .gtList()
            .overlay { if music.loading && music.sections.isEmpty { ProgressView() } }
            .navigationTitle("Musik")
            .toolbar {
                // Immer sichtbar (auch während der Suche), nicht nur als Listenzeile.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { FavoriteSongsView() } label: { Image(systemName: "heart.fill").foregroundStyle(GT.accent) }
                        .accessibilityLabel("Lieblingssongs")
                }
            }
            .navigationDestination(for: MusicCollection.self) { MusicDetailView(collection: $0) }
            .searchable(text: $query, prompt: "Songs, Alben, Interpreten")
            .onSubmit(of: .search) { Task { await music.search(query) } }
            .onChange(of: query) { _, new in
                // Suchfeld geleert: zurück zur Startseite (sonst bleiben alte Treffer stehen).
                if new.isEmpty, !music.searchQuery.isEmpty { Task { await music.loadHome() } }
            }
            .task { if music.sections.isEmpty { await music.loadHome() } }
        }
    }

    private func likeButton(_ s: MusicSong) -> some View {
        Button { music.toggleFavorite(s) } label: {
            Label(music.isFavorite(s) ? "Gefällt mir nicht mehr" : "Gefällt mir", systemImage: music.isFavorite(s) ? "heart.slash" : "heart")
        }.tint(GT.accent)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicModel.SearchFilter.allCases) { f in
                    Button { Task { await music.setFilter(f) } } label: {
                        Text(f.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 34)
                            .background(music.filter == f ? GT.accent : GT.surface, in: Capsule())
                            .foregroundStyle(music.filter == f ? Color.white : Color.primary)
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)).listRowBackground(Color.clear)
    }

    @ViewBuilder private func row(_ item: MusicItem, songs: [MusicSong]) -> some View {
        let content = HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(item.title).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if case .song(let s) = item {
            Button { music.play(songs, index: songs.firstIndex(of: s) ?? 0) } label: { content }.buttonStyle(.plain)
                .swipeActions(edge: .trailing) { likeButton(s) }
                .contextMenu { likeButton(s) }
        } else {
            if case .collection(let c) = item { NavigationLink(value: c) { content } }
        }
    }
}

/// Symbol der Play-Taste: zeigt den echten Zustand (Laden, Pause-Symbol beim Spielen, sonst Play).
struct PlayPauseIcon: View {
    let state: PlayerManager.State
    var body: some View {
        switch state {
        case .loading: ProgressView()
        case .playing: Image(systemName: "pause.fill")
        default: Image(systemName: "play.fill")
        }
    }
}

/// Kleine Steuerleiste unten, solange ein Titel läuft. Antippen öffnet den großen Player.
extension View {
    /// Mini-Player über der Tab-Leiste; gilt auch für alle Seiten, die im Tab geöffnet werden.
    func withMiniPlayer() -> some View { safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() } }
}

struct MiniPlayer: View {
    @EnvironmentObject var music: MusicModel
    @EnvironmentObject var app: AppModel
    @State private var showFull = false

    var body: some View {
        Group {
            if let song = music.queue.current, app.current?.videoId == song.videoId {
                // Der Player ist ein eigenes ObservableObject: nur so zeichnet sich die Leiste bei Zustandswechseln neu.
                MiniPlayerBar(song: song, player: app.player) { showFull = true }
            } else if let v = app.current, !app.showPlayer {
                VideoMiniBar(video: v, player: app.player)
            }
        }
        .sheet(isPresented: $showFull) {
            NowPlayingView(player: app.player).environmentObject(music).environmentObject(app)
        }
    }
}

/// Minimierter Video-Player: Ton läuft weiter; Antippen öffnet wieder, X beendet.
private struct VideoMiniBar: View {
    let video: VideoItem
    @ObservedObject var player: PlayerManager
    @EnvironmentObject var app: AppModel

    init(video: VideoItem, player: PlayerManager) { self.video = video; self._player = ObservedObject(wrappedValue: player) }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: min(1, Double(player.positionMs) / Double(max(1, player.durationMs))))
                .tint(GT.accent).scaleEffect(x: 1, y: 0.5)
            HStack(spacing: 4) {
                Button { app.showPlayer = true } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: video.thumbnailUrl)) { $0.resizable().scaledToFill() } placeholder: { GT.surface }
                            .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(video.channelName ?? "").font(.caption).foregroundStyle(GT.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Player öffnen")
                Button { player.toggle() } label: { PlayPauseIcon(state: player.state).font(.title2).frame(width: 44, height: 44) }
                    .accessibilityLabel(player.state == .playing ? "Pause" : "Abspielen")
                Button { app.closePlayer() } label: { Image(systemName: "xmark").frame(width: 40, height: 44) }
                    .accessibilityLabel("Wiedergabe beenden")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .tint(GT.accent).background(.regularMaterial)
    }
}

private struct MiniPlayerBar: View {
    let song: MusicSong
    @ObservedObject var player: PlayerManager
    @EnvironmentObject var music: MusicModel
    let onOpen: () -> Void

    init(song: MusicSong, player: PlayerManager, onOpen: @escaping () -> Void) {
        self.song = song; self._player = ObservedObject(wrappedValue: player); self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: min(1, Double(player.positionMs) / Double(max(1, player.durationMs))))
                .tint(GT.accent).scaleEffect(x: 1, y: 0.5)
            HStack(spacing: 4) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: song.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { GT.surface }
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(song.artists ?? "").font(.caption).foregroundStyle(GT.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Player öffnen")
                control("backward.fill", "Vorheriger Titel") { music.previous() }
                Button { player.toggle() } label: { PlayPauseIcon(state: player.state).font(.title2).frame(width: 44, height: 44) }
                    .accessibilityLabel(player.state == .playing ? "Pause" : "Abspielen")
                control("forward.fill", "Nächster Titel") { music.next() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .tint(GT.accent).background(.regularMaterial)
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 40, height: 44) }.accessibilityLabel(label)
    }
}

/// Großer Player: Cover, Titel, Fortschritt, Steuerung, Zufall und Wiederholen.
struct NowPlayingView: View {
    @ObservedObject var player: PlayerManager
    @EnvironmentObject var music: MusicModel
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?

    init(player: PlayerManager) { self._player = ObservedObject(wrappedValue: player) }

    var body: some View {
        // Alle Größen kommen aus der echten Sheet-Breite. Ohne feste Breite machten Cover (scaledToFill, Pixelgröße)
        // und Liedtext den Inhalt breiter als den Bildschirm: Der Player war nach rechts verschoben und abgeschnitten.
        GeometryReader { geo in
            let w = max(240, geo.size.width - 48)
            ScrollView {
                content(width: w).frame(width: w).padding(.horizontal, 24).padding(.bottom, 24).frame(width: geo.size.width)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .tint(GT.accent)
        .presentationDragIndicator(.visible)
        .task(id: music.queue.current?.videoId) { await music.loadLyrics() }
    }

    private func content(width w: CGFloat) -> some View {
        VStack(spacing: 20) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Schließen")
            if let song = music.queue.current {
                let side = min(w, 340)
                AsyncImage(url: URL(string: song.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { GT.surface }
                    .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Text(song.title).font(.title3.weight(.bold)).multilineTextAlignment(.center).lineLimit(2)
                        Text(song.artists ?? "").foregroundStyle(GT.secondaryText).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                    Button { music.toggleFavorite(song) } label: {
                        Image(systemName: music.isFavorite(song) ? "heart.fill" : "heart").font(.title2)
                            .foregroundStyle(music.isFavorite(song) ? GT.accent : Color.primary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(music.isFavorite(song) ? "Gefällt mir entfernen" : "Gefällt mir")
                }
                if case .failed = player.state {
                    Text("Der Titel lässt sich nicht abspielen. Tippe auf „Nächster Titel“ oder versuche es später erneut.")
                        .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                progress
                controls
                lyricsSection(width: w)
            }
        }
    }

    @ViewBuilder private func lyricsSection(width w: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Liedtext").font(.headline)
            switch music.lyricsState {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .loaded:
                if let l = music.lyrics {
                    Text(l.text).font(.body).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .frame(width: w, alignment: .leading)
                    if let source = l.source { Text(source).font(.caption).foregroundStyle(GT.secondaryText) }
                }
            case .none: Text("Für diesen Titel gibt es keinen Liedtext.").font(.subheadline).foregroundStyle(GT.secondaryText)
            case .failed:
                Text("Der Liedtext konnte nicht geladen werden.").font(.subheadline).foregroundStyle(GT.secondaryText)
                Button("Erneut versuchen") { Task { await music.loadLyrics(retry: true) } }
            }
        }
        .frame(width: w, alignment: .leading).padding(.top, 8)
    }

    private var progress: some View {
        let total = Double(max(1, player.durationMs))
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { scrubbing ?? Double(player.positionMs) }, set: { scrubbing = $0 }), in: 0...total) { editing in
                if !editing, let s = scrubbing { player.seek(toMs: Int64(s)); scrubbing = nil }
            }.disabled(player.durationMs <= 0).accessibilityLabel("Position")
            HStack {
                Text(Self.time(scrubbing ?? Double(player.positionMs)))
                Spacer()
                Text(Self.time(Double(player.durationMs)))
            }.font(.caption.monospacedDigit()).foregroundStyle(GT.secondaryText)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { music.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(music.queue.shuffle ? GT.accent : GT.secondaryText).frame(maxWidth: .infinity, minHeight: 56)
            }.accessibilityLabel(music.queue.shuffle ? "Zufall aus" : "Zufall an")
            Button { music.previous() } label: { Image(systemName: "backward.fill").font(.title2).frame(maxWidth: .infinity, minHeight: 56) }
                .accessibilityLabel("Vorheriger Titel")
            Button { player.toggle() } label: { PlayPauseIcon(state: player.state).font(.system(size: 40)).frame(maxWidth: .infinity, minHeight: 64) }
                .accessibilityLabel(player.state == .playing ? "Pause" : "Abspielen")
            Button { music.next() } label: { Image(systemName: "forward.fill").font(.title2).frame(maxWidth: .infinity, minHeight: 56) }
                .accessibilityLabel("Nächster Titel")
            Button { music.cycleRepeat() } label: {
                Image(systemName: music.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(music.queue.repeatMode == .off ? GT.secondaryText : GT.accent).frame(maxWidth: .infinity, minHeight: 56)
            }.accessibilityLabel("Wiederholen")
        }.foregroundStyle(.primary)
    }

    static func time(_ ms: Double) -> String {
        let s = max(0, Int(ms / 1000))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(t.title).lineLimit(1)
                                        if let a = t.artists { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "heart.fill").foregroundStyle(GT.accent).opacity(music.isFavorite(t) ? 1 : 0)
                                    .accessibilityHidden(!music.isFavorite(t)).allowsHitTesting(false)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { music.toggleFavorite(t) } label: {
                                    Label(music.isFavorite(t) ? "Gefällt mir nicht mehr" : "Gefällt mir", systemImage: music.isFavorite(t) ? "heart.slash" : "heart")
                                }.tint(GT.accent)
                            }
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


/// Lieblingssongs: alle gelikten Titel, neueste zuerst; „Alle abspielen“ und Zufallswiedergabe.
struct FavoriteSongsView: View {
    @EnvironmentObject var music: MusicModel

    var body: some View {
        List {
            if music.favorites.isEmpty {
                Text("Noch keine Lieblingssongs. Tippe im Player auf das Herz oder wische bei einem Titel nach links.")
                    .foregroundStyle(GT.secondaryText).listRowBackground(GT.background)
            } else {
                Button { music.play(music.favorites, index: 0) } label: { Label("Alle abspielen", systemImage: "play.fill") }
                ForEach(music.favorites, id: \.videoId) { s in
                    Button { music.play(music.favorites, index: music.favorites.firstIndex(of: s) ?? 0) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: s.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(s.title).lineLimit(1)
                                if let a = s.artists { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .swipeActions { Button("Entfernen", role: .destructive) { music.toggleFavorite(s) } }
                }
            }
        }
        .gtList()
        .navigationTitle("Lieblingssongs")
        .task { await music.reloadFavorites() }
    }
}
