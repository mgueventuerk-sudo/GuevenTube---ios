import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            PlaceholderView(title: "Start").tabItem { Label("Start", systemImage: "house") }
            PlaceholderView(title: "Suche").tabItem { Label("Suche", systemImage: "magnifyingglass") }
            PlaceholderView(title: "Musik").tabItem { Label("Musik", systemImage: "music.note") }
            PlaceholderView(title: "Mediathek").tabItem { Label("Mediathek", systemImage: "books.vertical") }
        }
    }
}

struct PlaceholderView: View {
    let title: String
    var body: some View { NavigationStack { Text(title).navigationTitle(title) } }
}
