import SwiftUI
import GuevenCore

/// Transkript aus den Untertiteln mit Suche; Tippen auf eine Zeile springt im Video dorthin.
struct TranscriptView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [TranscriptLine] = []
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?

    private var shown: [TranscriptLine] { query.trimmingCharacters(in: .whitespaces).count >= 2 ? Transcript.search(lines, query) : lines }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(shown, id: \.startMs) { l in
                    Button { app.player.seek(toMs: l.startMs); dismiss() } label: {
                        HStack(alignment: .top) {
                            Text(VideoRow.format(l.startMs / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(l.text)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Im Video suchen")
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Transkript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Schließen") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let track = Transcript.pickTrack(app.captions, preferredLanguage: Locale.current.language.languageCode?.identifier),
              let url = Transcript.json3URL(track) else { error = "Für dieses Video gibt es keine Untertitel."; return }
        loading = true; defer { loading = false }
        do {
            let response = try await app.env.transport.send(HTTPRequest(url: url))
            guard response.isSuccessful else { error = "Untertitel nicht abrufbar (HTTP \(response.code))."; return }
            lines = Transcript.parseJson3(response.text)
            if lines.isEmpty { error = "Das Transkript ist leer." }
        } catch { self.error = "Untertitel nicht abrufbar." }
    }
}
