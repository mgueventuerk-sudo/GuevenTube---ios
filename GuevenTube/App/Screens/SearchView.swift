import SwiftUI
import GuevenCore

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var continuation: String?
    @State private var correction: SearchCorrection?
    @State private var activeQuery = ""
    @State private var loading = false
    @State private var searched = false
    @State private var error: String?
    /// Zählt jede neue Suche hoch: eine späte Antwort einer älteren Suche wird verworfen.
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.subheadline).foregroundStyle(GT.secondaryText).listRowBackground(GT.background) }
                if let c = correction { correctionRow(c) }
                ForEach(results, id: \.key) { r in
                    resultRow(r)
                        .onAppear { if r.key == results.last?.key { Task { await more() } } }
                }
                if loading && !results.isEmpty { ProgressView().frame(maxWidth: .infinity).listRowBackground(GT.background) }
            }
            .gtList()
            .overlay {
                if loading && results.isEmpty { ProgressView() }
                else if searched && results.isEmpty && error == nil { Text("Keine Ergebnisse.").foregroundStyle(GT.secondaryText) }
            }
            .navigationTitle("Suche")
            .searchable(text: $query, prompt: "Videos suchen")
            .onSubmit(of: .search) { Task { await run(query) } }
            .onChange(of: query) { _, new in
                if new.isEmpty { generation += 1; results = []; continuation = nil; correction = nil; error = nil; searched = false; loading = false }
            }
        }
    }

    @ViewBuilder private func resultRow(_ r: SearchResult) -> some View {
        switch r {
        case .video(let v):
            VideoRow(item: v, style: .card)
        case .channel(let c):
            Button { app.channelRoute = ChannelRef(channelId: c.channelId, name: c.name, avatarUrl: c.avatarUrl) } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: c.avatarUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 56, height: 56).clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(c.name).font(.subheadline.weight(.semibold))
                        if let s = c.subscriberText { Text(s).font(.caption).foregroundStyle(GT.secondaryText) }
                    }
                    Spacer()
                }
            }.buttonStyle(.plain).listRowBackground(GT.background)
        case .playlist(let p):
            Button { Task { await open(p) } } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: p.thumbnailUrl ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 120, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text([p.isMix ? "Mix" : "Playlist", p.ownerName, p.videoCountText].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(GT.secondaryText).lineLimit(1)
                    }
                    Spacer()
                }
            }.buttonStyle(.plain).listRowBackground(GT.background)
        case .row(let title, let items, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).padding(.horizontal, GT.Metric.page).padding(.top, 8)
                ForEach(items, id: \.videoId) { VideoRow(item: $0, style: .compact) }
            }
            .listRowInsets(EdgeInsets()).listRowBackground(GT.background)
        }
    }

    private func correctionRow(_ c: SearchCorrection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if c.autoCorrected {
                Text("Ergebnisse für „\(c.correctedQuery)“").font(.subheadline.weight(.semibold))
                if let o = c.originalQuery {
                    Button("Stattdessen suchen nach „\(o)“") { Task { await run(o, params: c.originalQueryParams) } }.font(.subheadline)
                }
            } else {
                Button("Meintest du: „\(c.correctedQuery)“") { query = c.correctedQuery; Task { await run(c.correctedQuery) } }.font(.subheadline)
            }
        }.listRowBackground(GT.background)
    }

    private func run(_ text: String, params: String? = nil) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        generation += 1; let gen = generation
        activeQuery = q; loading = true; error = nil; results = []; continuation = nil; correction = nil
        defer { if gen == generation { loading = false } }
        do {
            let page = InnerTubeParser.parseSearch(try await app.env.innerTube.search(query: q, params: params))
            guard gen == generation else { return }
            results = page.results; continuation = page.continuation; correction = page.correction; searched = true
        } catch { guard gen == generation else { return }; self.error = GTError.text(error); searched = true }
    }

    /// Lädt weiter, solange Seiten ohne neue Treffer kommen (Werbung/Shorts-Reihen), damit die Liste nicht abbricht.
    private func more() async {
        guard continuation != nil, !loading else { return }
        let gen = generation
        loading = true; defer { if gen == generation { loading = false } }
        var added = 0, tries = 0
        while added == 0, tries < 4, let c = continuation, gen == generation {
            tries += 1
            do {
                let page = InnerTubeParser.parseSearch(try await app.env.innerTube.search(query: nil, continuation: c))
                guard gen == generation else { return }
                let known = Set(results.map(\.key))
                let fresh = page.results.filter { !known.contains($0.key) }
                results += fresh; added = fresh.count; continuation = page.continuation
            } catch { guard gen == generation else { return }; self.error = GTError.text(error); return }
        }
    }

    private func open(_ p: PlaylistItem) async {
        if p.isMix, let id = p.firstVideoId { app.play(VideoItem(videoId: id, title: p.title, channelName: p.ownerName, thumbnailUrl: p.thumbnailUrl ?? InnerTubeParser.fallbackThumbnail(id))); return }
        guard let browseId = p.browseId else { return }
        do {
            let page = InnerTubeParser.parseFeed(try await app.env.innerTube.browse(browseId: browseId), defaultShelfTitle: p.title)
            let items = page.shelves.flatMap(\.items)
            if items.isEmpty { error = "Die Playlist ist leer oder nicht abrufbar." } else { app.playQueue(items) }
        } catch { self.error = GTError.text(error) }
    }
}
