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
    var skip: () -> Void = {}
    var openChannel: () -> Void = {}
    var watchLater: () -> Void = {}
    var showTranscript: () -> Void = {}
    var showComments: () -> Void = {}
    var showChat: () -> Void = {}
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
    @ViewBuilder var surface: Surface
    @ViewBuilder var playlistMenu: Playlist
    @ViewBuilder var downloadMenu: Download

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
            overlayButton("chevron.down", label: "Player schließen", action: actions.close)
        }
        .overlay(alignment: .topTrailing) {
            overlayButton(isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          label: isLandscape ? "Hochformat" : "Querformat") {
                OrientationControl.request(isLandscape ? .portrait : .landscape)
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
                chips
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

struct PlayerScreen: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var player: PlayerManager
    @StateObject private var downloads = DownloadsModel()
    @State private var showTranscript = false
    @State private var showComments = false
    @State private var showChat = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if let v = app.current {
                    PlayerContent(
                        isLandscape: landscape, video: v, hasCaptions: !app.captions.isEmpty,
                        qualityText: player.plan.map { $0.qualityLabel + ($0.throttled ? " · gedrosselt" : "") },
                        errorText: errorText, isLoading: { if case .loading = player.state { return true } else { return false } }(),
                        skipLabel: app.skipPrompt.map { "\($0.category.displayName) überspringen" },
                        actions: PlayerActions(
                            close: { app.closePlayer() }, skip: { app.skipPrompted() },
                            openChannel: { if let id = v.channelId, let name = v.channelName { app.channelRoute = ChannelRef(channelId: id, name: name) } },
                            watchLater: { Task { await AppEnvironment.shared.library.addToWatchLater(v) } },
                            showTranscript: { showTranscript = true }, showComments: { showComments = true }, showChat: { showChat = true }),
                        surface: { SystemPlayer(player: player.player) },
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
        .sheet(isPresented: $showTranscript) { TranscriptView().environmentObject(app) }
        .sheet(isPresented: $showComments) { if let v = app.current { CommentsView(videoId: v.videoId) } }
        .sheet(isPresented: $showChat) { if let v = app.current { LiveChatView(videoId: v.videoId) } }
        .sheet(item: Binding(get: { app.showPlayer ? app.channelRoute : nil }, set: { app.channelRoute = $0 })) { c in
            NavigationStack { ChannelView(channel: c).doneToolbar { app.channelRoute = nil } }
                .environmentObject(app)
        }
    }

    private var errorText: String? {
        if let e = app.playbackError { return e }
        if case .failed(let m) = player.state { return m }
        return nil
    }
}
