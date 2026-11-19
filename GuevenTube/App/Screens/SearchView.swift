import SwiftUI
import GuevenCore

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var videos: [VideoItem] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText).listRowBackground(GT.background) }
                ForEach(videos, id: \.videoId) { v in
                    VideoRow(item: v, style: .card)
                        .onAppear { if v.videoId == videos.last?.videoId { Task { await more() } } }
                }
            }
            .gtList()
            .overlay { if loading && videos.isEmpty { ProgressView() } }
            .navigationTitle("Suche")
            .searchable(text: $query, prompt: "Videos suchen")
            .onSubmit(of: .search) { Task { await run() } }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseSearch(try await app.env.innerTube.search(query: q))
            videos = page.videos; continuation = page.continuation; error = nil
        } catch { self.error = GTError.text(error) }
    }

    private func more() async {
        guard let c = continuation, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = InnerTubeParser.parseSearch(try await app.env.innerTube.search(query: nil, continuation: c))
            let known = Set(videos.map(\.videoId))
            videos += page.videos.filter { !known.contains($0.videoId) }
            continuation = page.continuation
        } catch { self.error = GTError.text(error) }
    }
}
