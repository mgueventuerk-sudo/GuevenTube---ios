import SwiftUI

struct RootView: View {
    @StateObject private var app: AppModel
    @StateObject private var music: MusicModel
    @StateObject private var kids = KidsModel()

    init() {
        let a = AppModel()
        _app = StateObject(wrappedValue: a)
        _music = StateObject(wrappedValue: MusicModel(app: a))
    }

    var body: some View {
        TabView {
            StartView().tabItem { Label("Start", systemImage: "house") }
            SearchView().tabItem { Label("Suche", systemImage: "magnifyingglass") }
            MusicView().tabItem { Label("Musik", systemImage: "music.note") }
            LibraryView().tabItem { Label("Mediathek", systemImage: "books.vertical") }
            AccountView().tabItem { Label("Konto", systemImage: "person.crop.circle") }
        }
        .environmentObject(app)
        .environmentObject(music)
        .environmentObject(kids)
        .overlay { if let b = kids.block, !app.showPlayer { KidsBlockView(reason: b.reason).environmentObject(kids) } }
        .task { kids.start(player: app.player); await kids.refreshPin() }
        .fullScreenCover(isPresented: $app.showPlayer) { PlayerScreen(player: app.player).environmentObject(app)
                .overlay { if let b = kids.block { KidsBlockView(reason: b.reason).environmentObject(kids) } } }
    }
}

struct PlaceholderView: View {
    let title: String
    var body: some View { NavigationStack { Text(title).navigationTitle(title) } }
}
