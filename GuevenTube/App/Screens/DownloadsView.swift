import SwiftUI
import GuevenCore

struct DownloadsView: View {
    @StateObject private var model = DownloadsModel()
    /// `nil`: alle (Konto); sonst nur Video oder nur Ton (Mediathek).
    let kind: DownloadKind?
    init(kind: DownloadKind? = nil) { self.kind = kind }
    private var records: [DownloadRecord] { model.records.filter { kind == nil || $0.kind == kind } }

    var body: some View {
        List {
            if records.isEmpty { Text("Noch keine Downloads.").foregroundStyle(.secondary) }
            ForEach(records) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.title).lineLimit(2)
                    Text(statusLine(r)).font(.caption).foregroundStyle(r.status == .failed ? .red : .secondary)
                    if r.status == .running { ProgressView(value: Double(max(r.progressPercent, 0)), total: 100) }
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) { model.delete(r) }
                    if r.status == .failed { Button("Wiederholen") { model.retry(r) }.tint(.blue) }
                }
            }
        }
        .navigationTitle("Downloads")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func statusLine(_ r: DownloadRecord) -> String {
        switch r.status {
        case .queued: return "Wartet · \(r.qualityLabel)"
        case .running: return "\(r.stage ?? "Läuft") · \(r.progressPercent) %"
        case .done: return "Fertig · \(r.qualityLabel) · in „Dateien“ unter GuevenTube/Downloads"
        case .failed: return "Fehlgeschlagen: \(r.errorMessage ?? "unbekannt")"
        }
    }
}
