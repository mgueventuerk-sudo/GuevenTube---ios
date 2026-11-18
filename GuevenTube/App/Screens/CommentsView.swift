import SwiftUI
import GuevenCore

/// Kommentare des laufenden Videos (Web-`next` → Fortsetzung, Seite für Seite). Apple-only, ungetestet.
struct CommentsView: View {
    let videoId: String
    @State private var comments: [Comment] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                else if loaded && comments.isEmpty && !loading { Text("Keine Kommentare (oder deaktiviert).").foregroundStyle(.secondary) }
                ForEach(comments) { c in row(c) }
                if continuation != nil {
                    Button("Mehr laden") { Task { await loadMore() } }.disabled(loading)
                }
            }
            .listStyle(.plain)
            .overlay { if loading && comments.isEmpty { ProgressView() } }
            .navigationTitle("Kommentare").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
            .task(id: videoId) { await first() }
        }
    }

    private func row(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(c.author).font(.subheadline.bold())
                if let p = c.publishedText { Text(p).font(.caption).foregroundStyle(.secondary) }
            }
            Text(c.text).font(.body)
            if let l = c.likeText { Label(l, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    private func first() async {
        loading = true; defer { loading = false; loaded = true }
        comments = []; continuation = nil; error = nil
        do {
            let service = AppEnvironment.shared.innerTube
            let next = try await service.webNext(videoId: videoId)
            guard let token = CommunityParser.findCommentsToken(next) else { return }
            apply(CommunityParser.parseComments(try await service.webNextContinuation(token)))
        } catch is CancellationError {
        } catch { self.error = "Kommentare konnten nicht geladen werden." }
    }

    private func loadMore() async {
        guard let token = continuation, !loading else { return }
        loading = true; defer { loading = false }
        do { apply(CommunityParser.parseComments(try await AppEnvironment.shared.innerTube.webNextContinuation(token))) }
        catch is CancellationError {} catch { self.error = "Weitere Kommentare konnten nicht geladen werden." }
    }

    private func apply(_ page: CommentsPage) {
        let known = Set(comments.map(\.id))
        comments += page.comments.filter { !known.contains($0.id) }
        continuation = page.continuation
    }
}
