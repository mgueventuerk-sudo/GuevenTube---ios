import SwiftUI
import GuevenCore

struct RootView: View {
    @StateObject private var app: AppModel
    @StateObject private var music: MusicModel
    @StateObject private var kids = KidsModel()
    @ObservedObject private var link = LinkModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingPair: PairRequest?
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var net = NetworkMonitor.shared
    @StateObject private var router = TabRouter()
    @StateObject private var downloadsModel = DownloadsModel()
    private var activeDownloads: Int { downloadsModel.records.filter { $0.status == .queued || $0.status == .running }.count }

    /// Genau ein AppModel, auch wenn SwiftUI `RootView.init` mehrfach aufruft (sonst hängt LinkModel an einer verworfenen Instanz).
    private static let sharedApp = AppModel()

    init() {
        let a = Self.sharedApp
        _app = StateObject(wrappedValue: a)
        LinkModel.shared.app = a
        _music = StateObject(wrappedValue: MusicModel(app: a))
    }

    var body: some View {
        TabView(selection: $router.tab) {
            HomeView().withMiniPlayer().tabItem { Label("Start", systemImage: "house") }.tag(0)
            SearchView().withMiniPlayer().tabItem { Label("Suche", systemImage: "magnifyingglass") }.tag(1)
            LibraryView().withMiniPlayer().tabItem { Label("Mediathek", systemImage: "books.vertical") }.tag(2)
                .badge(activeDownloads)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if net.isOffline {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text("Offline – Downloads und Mediathek sind verfügbar").font(.footnote)
                    Spacer(minLength: 0)
                    if router.tab != 2 { Button("Mediathek") { router.tab = 2 }.font(.footnote.weight(.semibold)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            NoticeBanner(center: notices).padding(.bottom, 96).animation(.default, value: notices.text)
        }
        .onChange(of: net.firstStatusOffline) { _, off in if off == true { router.tab = 2 } }
        .tint(GT.accent)
        .environmentObject(app)
        .environmentObject(music)
        .environmentObject(kids)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { link.suspendForBackground(); Task { await WidgetBridge.refresh() } } else if phase == .active { link.resumeFromBackground() }
        }
        .onOpenURL { url in
            switch DeepLink.parse(url.absoluteString) {
            case .play(let id, let start)?:
                app.play(VideoItem(videoId: id, title: id, thumbnailUrl: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"), startAtMs: start.map { Int64($0) * 1000 })
            case .pair(let request)?: pendingPair = request  // Jede App/Webseite kann so einen Link auslösen: erst nach Bestätigung koppeln.
            case nil: break
            }
        }
        .alert("Mit Fernseher koppeln?", isPresented: Binding(get: { pendingPair != nil }, set: { if !$0 { pendingPair = nil } })) {
            Button("Koppeln") { if let r = pendingPair { LinkModel.shared.pair(with: r) }; pendingPair = nil }
            Button("Abbrechen", role: .cancel) { pendingPair = nil }
        } message: { Text("„\(pendingPair?.name ?? "")“ (\(pendingPair?.host ?? "")) als Fernbedienung verbinden.") }
        .overlay { if let b = kids.block, !app.showPlayer { KidsBlockView(reason: b.reason).environmentObject(kids) } }
        .sheet(item: Binding(get: { app.showPlayer ? nil : app.channelRoute }, set: { app.channelRoute = $0 })) { c in
            NavigationStack { ChannelView(channel: c).doneToolbar { app.channelRoute = nil } }
                .withMiniPlayer()
                .environmentObject(app).environmentObject(music)
        }
        .onReceive(NotificationCenter.default.publisher(for: NewVideosService.openVideoNotification)) { n in
            if let v = n.object as? VideoItem { NewVideosService.pendingVideo = nil; app.play(v) }
        }
        .task {
            downloadsModel.start()
            kids.start(player: app.player); await kids.refreshPin()
            // Kaltstart per Benachrichtigung: die Meldung kam vor dem Abonnieren oben.
            if let v = NewVideosService.pendingVideo { NewVideosService.pendingVideo = nil; app.play(v) }
        }
        .fullScreenCover(isPresented: $app.showPlayer) { PlayerScreen(player: app.player).environmentObject(app)
                .overlay { if let b = kids.block { KidsBlockView(reason: b.reason).environmentObject(kids) } } }
    }
}

struct PlaceholderView: View {
    let title: String
    var body: some View { NavigationStack { Text(title).navigationTitle(title) } }
}
