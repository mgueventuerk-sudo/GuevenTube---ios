import SwiftUI
import WidgetKit
import GuevenCore

struct ContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ContinueProvider: TimelineProvider {
    private func load() -> WidgetSnapshot {
        WidgetSnapshot.decode(UserDefaults(suiteName: WidgetSnapshot.appGroup)?.data(forKey: WidgetSnapshot.defaultsKey))
    }
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: .now, snapshot: WidgetSnapshot(entries: [.init(videoId: "dQw4w9WgXcQ", title: "Beispielvideo", channelName: "Kanal")]))
    }
    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) { completion(ContinueEntry(date: .now, snapshot: load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        // Die App stößt das Update beim Verlassen an; der Zeitplan ist nur ein Netz dafür.
        completion(Timeline(entries: [ContinueEntry(date: .now, snapshot: load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ContinueWidgetView: View {
    let entry: ContinueEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weiterschauen").font(.headline)
            if entry.snapshot.entries.isEmpty {
                Text("Noch nichts angefangen.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.entries, id: \.videoId) { e in
                if let url = entry.snapshot.url(for: e) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.caption).lineLimit(2)
                            if let c = e.channelName { Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: ContinueProvider()) { ContinueWidgetView(entry: $0) }
            .configurationDisplayName("Weiterschauen")
            .description("Die zuletzt angefangenen Videos.")
            .supportedFamilies([.systemMedium])
    }
}

@main
struct GuevenTubeWidgetBundle: WidgetBundle {
    var body: some Widget { ContinueWatchingWidget() }
}
