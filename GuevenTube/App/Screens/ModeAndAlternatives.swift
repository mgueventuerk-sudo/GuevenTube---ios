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

/// „Anderer Weg“: Wiedergabeweg für dieses Video wählen. Der eingebettete Weg läuft im Player selbst weiter.
struct AlternativePlaybackSheet: View {
    let video: VideoItem
    @Binding var embedded: Bool
    let reresolve: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var app: AppModel
    @State private var choices: [(id: String, label: String)] = []
    @State private var pinned: String? = UserDefaults.standard.string(forKey: StreamResolver.preferredClientKey)

    var body: some View {
        NavigationStack {
            List {
                Section("Wiedergabeweg") {
                    Button { embedded = false; dismiss() } label: { check("Eigener Player (Warteschlange, Nur-Ton, Hintergrund, PiP)", !embedded) }
                    Button { embedded = true; dismiss() } label: { check("Eingebetteter YouTube-Player (ohne Hintergrund/Sperrbildschirm)", embedded) }
                }
                Section("Weg des eigenen Players (voller Funktionsumfang)") {
                    Button { pin(nil) } label: { check("Automatisch", pinned == nil) }
                    ForEach(choices, id: \.id) { c in Button { pin(c.id) } label: { check(c.label, pinned == c.id) } }
                }
                Section("Eigenen Player reparieren") {
                    Button { embedded = false; dismiss(); reresolve() } label: { Label("Neu auflösen (Zwischenspeicher verwerfen)", systemImage: "arrow.clockwise") }
                }
                Section("Außerhalb der App") {
                    Button { open("https://www.youtube.com/watch?v=\(video.videoId)") } label: { Label("In YouTube / Safari öffnen", systemImage: "arrow.up.right.square") }
                    Button { open("https://music.youtube.com/watch?v=\(video.videoId)") } label: { Label("In YouTube Music öffnen", systemImage: "music.note") }
                }
                Section { Text("Fällt der eigene Player aus, wechselt die App bei „Automatisch“ selbst auf den eingebetteten Weg (Einstellungen → Wiedergabe).")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Anderer Weg")
            .navigationBarTitleDisplayMode(.inline)
            .doneToolbar { dismiss() }
            .task { choices = await app.env.resolver.clientChoices() }
        }
    }

    private func pin(_ id: String?) {
        pinned = id
        if let id { UserDefaults.standard.set(id, forKey: StreamResolver.preferredClientKey) } else { UserDefaults.standard.removeObject(forKey: StreamResolver.preferredClientKey) }
        embedded = false; dismiss(); reresolve()
    }

    private func check(_ t: String, _ on: Bool) -> some View {
        HStack { Text(t).foregroundStyle(.primary); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(GT.accent) } }
    }
    private func open(_ s: String) { if let u = URL(string: s) { openURL(u) } }
}
