import SwiftUI
import GuevenCore

struct StartView: View {
    @EnvironmentObject var app: AppModel
    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText).listRowBackground(GT.background) }
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, shelf in
                    Section(shelf.title) {
                        ForEach(shelf.items, id: \.videoId) { v in
                            VideoRow(item: v, style: .card)
                        }
                    }
                }
            }
            .gtList()
            .overlay { if loading && shelves.isEmpty { ProgressView() } }
            .navigationTitle("Start")
            .refreshable { await load() }
            .task { if shelves.isEmpty { await load() } }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let json = try await app.env.innerTube.browse(browseId: "default")
            let page = InnerTubeParser.parseFeed(json, defaultShelfTitle: "Empfohlen")
            shelves = page.shelves
            error = page.shelves.isEmpty ? "Keine Videos erhalten." : nil
        } catch {
            self.error = GTError.text(error)
        }
    }
}
