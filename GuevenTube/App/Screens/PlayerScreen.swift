import SwiftUI
import AVKit
import GuevenCore

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

/// Bildschirm-Ausrichtung gezielt anfordern (funktioniert auch bei gesperrter Drehung per Knopf).
enum OrientationControl {
    @MainActor static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/// Alle Aktionen des Players an einer Stelle; Reihenfolge der Chips ist fest: speichern → laden → Info.
struct PlayerActions {
    var close: () -> Void = {}
    var minimize: () -> Void = {}
    var skip: () -> Void = {}
    var openChannel: () -> Void = {}
    var watchLater: () -> Void = {}
    var showTranscript: () -> Void = {}
    var showComments: () -> Void = {}
    var showChat: () -> Void = {}
    var toggleAudioOnly: () -> Void = {}
    var showAlternatives: () -> Void = {}
}

/// Reine Darstellung des Players (ohne AVPlayer): Hochformat = Bild oben, Details darunter; Querformat = Bild füllt den Schirm.
/// Getrennt vom `PlayerScreen`, damit CI Bilder beider Ausrichtungen rendern kann.
struct PlayerContent<Surface: View, Playlist: View, Download: View>: View {
    let isLandscape: Bool
    let video: VideoItem
    let hasCaptions: Bool
    let qualityText: String?
    let errorText: String?
    let isLoading: Bool
    let skipLabel: String?
    let actions: PlayerActions
    var related: [VideoItem] = []
    var audioOnly = false
    var diagnostics: String? = nil
    var pathLabel: String? = nil
    let surface: Surface
    let playlistMenu: Playlist
    let downloadMenu: Download

    init(isLandscape: Bool, video: VideoItem, hasCaptions: Bool, qualityText: String?, errorText: String?, isLoading: Bool,
         skipLabel: String?, actions: PlayerActions, related: [VideoItem] = [], audioOnly: Bool = false, diagnostics: String? = nil, pathLabel: String? = nil,
         @ViewBuilder surface: () -> Surface, @ViewBuilder playlistMenu: () -> Playlist, @ViewBuilder downloadMenu: () -> Download) {
        self.isLandscape = isLandscape; self.video = video; self.hasCaptions = hasCaptions; self.qualityText = qualityText
        self.errorText = errorText; self.isLoading = isLoading; self.skipLabel = skipLabel; self.actions = actions; self.related = related; self.audioOnly = audioOnly
        self.diagnostics = diagnostics; self.pathLabel = pathLabel
        self.surface = surface(); self.playlistMenu = playlistMenu(); self.downloadMenu = downloadMenu()
    }

    var body: some View {
        Group {
            if isLandscape {
                videoArea.ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    videoArea
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black.ignoresSafeArea(edges: .top))
                    details
                }
            }
        }
        .background(isLandscape ? Color.black : GT.background)
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            surface
            if isLoading && errorText == nil { ProgressView().tint(.white) }
            if let errorText {
                ScrollView { Text(errorText).font(.system(.caption2, design: .monospaced)).foregroundStyle(.white).padding(8).textSelection(.enabled) }
            }
        }
        // Links oben immer „Schließen“, rechts oben „Ausrichtung“; unten rechts „Überspringen“.
        .overlay(alignment: .topLeading) {
            overlayButton("chevron.down", label: "Player minimieren", action: actions.minimize)
        }
        .overlay(alignment: .topTrailing) {
            overlayButton(isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          label: isLandscape ? "Hochformat" : "Querformat") {
                OrientationControl.request(isLandscape ? .portrait : .landscape)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let pathLabel {
                Text(pathLabel).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.55), in: Capsule()).padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let skipLabel {
                Button(skipLabel, action: actions.skip).buttonStyle(.borderedProminent).padding(.trailing, 12).padding(.bottom, 56)
            }
        }
    }

    private func overlayButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
                .frame(width: GT.Metric.touch, height: GT.Metric.touch).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .padding(4)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(video.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                channelRow
                if let qualityText { Text(qualityText).font(.caption).foregroundStyle(GT.secondaryText) }
                if let diagnostics {
                    DisclosureGroup("Details zum Fehler") {
                        Text(diagnostics).font(.system(.caption2, design: .monospaced)).foregroundStyle(GT.secondaryText).textSelection(.enabled)
                    }.font(.caption)
                }
                chips
                if !related.isEmpty {
                    Text("Empfohlen").font(.headline).padding(.top, 12)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(related, id: \.videoId) { VideoRow(item: $0, style: .compact) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GT.Metric.page).padding(.top, 12)
        }
    }

    @ViewBuilder private var channelRow: some View {
        if video.channelId != nil, let name = video.channelName {
            Button(action: actions.openChannel) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(GT.secondaryText)
                    Text(name).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(GT.secondaryText)
                }
                .frame(minHeight: GT.Metric.touch).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let name = video.channelName {
            Text(name).font(.subheadline).foregroundStyle(GT.secondaryText)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !video.isLive {
                    ChipButton(title: audioOnly ? "Mit Bild" : "Nur Ton", systemImage: audioOnly ? "play.rectangle" : "headphones", action: actions.toggleAudioOnly)
                }
                ChipButton(title: "Anderer Weg", systemImage: "arrow.triangle.branch", action: actions.showAlternatives)
                ChipButton(title: "Später ansehen", systemImage: "clock", action: actions.watchLater)
                playlistMenu
                downloadMenu
                if hasCaptions { ChipButton(title: "Transkript", systemImage: "text.alignleft", action: actions.showTranscript) }
                if video.isLive { ChipButton(title: "Live-Chat", systemImage: "bubble.left.and.bubble.right", action: actions.showChat) }
                else { ChipButton(title: "Kommentare", systemImage: "text.bubble", action: actions.showComments) }
            }
            .padding(.vertical, 2)
        }
    }
}

/// „Nur Ton“: Cover statt Bild, mit eigener Steuerung (der System-Player zeigt bei reinem Ton keine).
struct AudioOnlySurface: View {
    let url: String
    @ObservedObject var player: PlayerManager
    @State private var scrubbing: Double?

    var body: some View {
        ZStack {
            AsyncImage(url: URL(string: url)) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                .blur(radius: 24).opacity(0.5).clipped()
            VStack(spacing: 10) {
                Label("Nur Ton", systemImage: "headphones").font(.subheadline.weight(.semibold))
                Button { player.toggle() } label: { PlayPauseIcon(state: player.state).font(.system(size: 36)).frame(width: 64, height: 64) }
                    .accessibilityLabel(player.state == .playing ? "Pause" : "Abspielen")
                Slider(value: Binding(get: { scrubbing ?? Double(player.positionMs) }, set: { scrubbing = $0 }),
                       in: 0...Double(max(1, player.durationMs))) { editing in
                    if !editing, let s = scrubbing { player.seek(toMs: Int64(s)); scrubbing = nil }
                }
                .disabled(player.durationMs <= 0).accessibilityLabel("Position").padding(.horizontal, 24)
            }.foregroundStyle(.white)
        }
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var player: PlayerManager
    @StateObject private var downloads = DownloadsModel()
    @State private var showTranscript = false
    @State private var showComments = false
    @State private var showChat = false
    @State private var showAlternatives = false
    /// "auto": eigener Player, bei Ausfall eingebettet; "embedded": immer eingebettet.
    @AppStorage("playbackPath") private var playbackPath = "auto"
    @State private var manualEmbedded = false
    private var useEmbedded: Bool { manualEmbedded || playbackPath == "embedded" || errorText != nil }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if let v = app.current {
                    PlayerContent(
                        isLandscape: landscape, video: v, hasCaptions: !app.captions.isEmpty,
                        qualityText: errorText != nil ? Self.friendlyError : useEmbedded ? "Eingebetteter YouTube-Player: Warteschlange, Hintergrund und Nur-Ton sind hier nicht verfügbar." : player.plan.map { $0.qualityLabel + ($0.throttled ? " · gedrosselt" : "") + (player.startTiming.map { " · " + $0 } ?? "") },
                        errorText: nil, isLoading: { if case .loading = player.state { return true } else { return false } }(),
                        skipLabel: app.skipPrompt.map { "\($0.category.displayName) überspringen" },
                        actions: PlayerActions(
                            close: { app.closePlayer() }, minimize: { app.showPlayer = false }, skip: { app.skipPrompted() },
                            openChannel: { if let id = v.channelId, let name = v.channelName { app.channelRoute = ChannelRef(channelId: id, name: name) } },
                            watchLater: { Task { await AppEnvironment.shared.library.addToWatchLater(v) } },
                            showTranscript: { showTranscript = true }, showComments: { showComments = true }, showChat: { showChat = true },
                            toggleAudioOnly: { app.setAudioOnly(!app.lastAudioOnly) },
                            showAlternatives: { showAlternatives = true }),
                        related: app.related,
                        audioOnly: app.lastAudioOnly,
                        diagnostics: errorText, pathLabel: useEmbedded ? "Eingebettet" : nil,
                        surface: {
                            if useEmbedded { EmbeddedYouTubeView(videoId: v.videoId) }
                            else if app.lastAudioOnly { AudioOnlySurface(url: v.thumbnailUrl, player: player) } else { SystemPlayer(player: player.player) }
                        },
                        playlistMenu: {
                            AddToPlaylistMenu(video: v) { ChipLabel(title: "Playlist", systemImage: "text.badge.plus") }
                        },
                        downloadMenu: {
                            Menu {
                                ForEach([DownloadQuality.audioOnly, .hd, .fullHd], id: \.self) { q in
                                    Button(q.label) { downloads.enqueue(v, quality: q) }
                                }
                            } label: { ChipLabel(title: "Herunterladen", systemImage: "arrow.down.circle") }
                                .frame(minHeight: GT.Metric.touch)
                        })
                } else {
                    Color.black
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .statusBarHidden(landscape)
            .persistentSystemOverlays(landscape ? .hidden : .automatic)
        }
        .sheet(isPresented: $showAlternatives) {
            if let v = app.current { AlternativePlaybackSheet(video: v, embedded: $manualEmbedded) { app.reresolve() }.environmentObject(app) }
        }
        .onChange(of: useEmbedded) { _, on in if on { player.pause() } }
        .sheet(isPresented: $showTranscript) { TranscriptView().environmentObject(app) }
        .sheet(isPresented: $showComments) { if let v = app.current { CommentsView(videoId: v.videoId) } }
        .sheet(isPresented: $showChat) { if let v = app.current { LiveChatView(videoId: v.videoId) } }
        .sheet(item: Binding(get: { app.showPlayer ? app.channelRoute : nil }, set: { app.channelRoute = $0 })) { c in
            NavigationStack { ChannelView(channel: c).doneToolbar { app.channelRoute = nil } }
                .environmentObject(app)
        }
    }

    static let friendlyError = "Dieses Video lässt sich über den eigenen Player gerade nicht laden. Ich habe es eingebettet geöffnet; über „Anderer Weg“ kannst du einen anderen Weg wählen."

    private var errorText: String? {
        if let e = app.playbackError { return e }
        if case .failed(let m) = player.state { return m }
        return nil
    }
}
