import SwiftUI
import WebKit
import GuevenCore

/// Gemeinsamer Modus der App (Start, Mediathek, Suche-Vorauswahl): "video" oder "music".
enum AppMode { static let key = "appMode" }

/// Umschalter Video | Musik in der Navigationsleiste und Konto-Avatar links (ersetzt den Konto-Tab).
private struct ModeToolbar: ViewModifier {
    @AppStorage(AppMode.key) private var mode = "video"
    @State private var showAccount = false
    let showPicker: Bool

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAccount = true } label: { Image(systemName: "person.crop.circle").font(.title3) }
                        .accessibilityLabel("Konto und Einstellungen")
                }
                if showPicker {
                    ToolbarItem(placement: .principal) {
                        Picker("Bereich", selection: $mode) { Text("Video").tag("video"); Text("Musik").tag("music") }
                            .pickerStyle(.segmented).frame(width: 180)
                    }
                }
            }
            .sheet(isPresented: $showAccount) { AccountSheet() }
    }
}

extension View {
    func modeToolbar(picker: Bool = true) -> some View { modifier(ModeToolbar(showPicker: picker)) }
}

private struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var music: MusicModel
    @EnvironmentObject var kids: KidsModel

    var body: some View {
        AccountView()
            .environmentObject(app).environmentObject(music).environmentObject(kids)
            .overlay(alignment: .topTrailing) {
                Button("Fertig") { dismiss() }.padding(.horizontal, 16).frame(minHeight: GT.Metric.touch)
            }
    }
}

/// Start: je nach Modus Video-Startseite oder Musik-Startseite.
struct HomeView: View {
    @AppStorage(AppMode.key) private var mode = "video"
    var body: some View {
        if mode == "music" { MusicView() } else { StartView() }
    }
}

// MARK: Alternative Wege zur Wiedergabe

/// Eingebetteter YouTube-Player (eigener Weg, unabhängig von der eigenen Stream-Auflösung).
struct EmbeddedYouTubeView: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false; web.backgroundColor = .black; web.scrollView.isScrollEnabled = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != videoId, let id = Optional(videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !id.isEmpty,
              let url = URL(string: "https://www.youtube.com/embed/\(id)?playsinline=1&autoplay=1&rel=0") else { return }
        context.coordinator.loaded = videoId
        web.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: String? }
}

/// „Anderer Weg“: wenn die eigene Wiedergabe hakt oder ausfällt.
struct AlternativePlaybackSheet: View {
    let video: VideoItem
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var embedded = false

    var body: some View {
        NavigationStack {
            List {
                Section("Weitere Wege für dieses Video") {
                    Button { dismiss(); retry() } label: { Label("Erneut versuchen (nächste Route)", systemImage: "arrow.clockwise") }
                    Button { embedded = true } label: { Label("Eingebetteter YouTube-Player", systemImage: "play.rectangle") }
                    Button { open("https://www.youtube.com/watch?v=\(video.videoId)") } label: { Label("In YouTube / Safari öffnen", systemImage: "arrow.up.right.square") }
                    Button { open("https://music.youtube.com/watch?v=\(video.videoId)") } label: { Label("In YouTube Music öffnen", systemImage: "music.note") }
                }
                Section { Text("Die Wege sind voneinander unabhängig: fällt die eigene Auflösung aus, funktionieren Einbettung und YouTube selbst weiter.")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Anderer Weg")
            .navigationBarTitleDisplayMode(.inline)
            .doneToolbar { dismiss() }
            .fullScreenCover(isPresented: $embedded) {
                ZStack(alignment: .topTrailing) {
                    EmbeddedYouTubeView(videoId: video.videoId).ignoresSafeArea()
                    Button { embedded = false } label: { Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white) }.padding()
                }.background(Color.black)
            }
        }
    }

    private func open(_ s: String) { if let u = URL(string: s) { openURL(u) } }
}
