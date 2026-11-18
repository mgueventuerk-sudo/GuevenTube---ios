import SwiftUI

struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        TabView {
            StartView().tabItem { Label("Start", systemImage: "house") }
            SearchView().tabItem { Label("Suche", systemImage: "magnifyingglass") }
            PlaceholderView(title: "Musik").tabItem { Label("Musik", systemImage: "music.note") }
            PlaceholderView(title: "Mediathek").tabItem { Label("Mediathek", systemImage: "books.vertical") }
        }
        .environmentObject(app)
        .fullScreenCover(isPresented: $app.showPlayer) { PlayerScreen(player: app.player).environmentObject(app) }
    }
}

struct PlaceholderView: View {
    let title: String
    var body: some View { NavigationStack { Text(title).navigationTitle(title) } }
}
