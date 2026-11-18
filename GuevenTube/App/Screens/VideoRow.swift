import SwiftUI
import GuevenCore

struct VideoRow: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var link = LinkModel.shared
    let item: VideoItem
    @State private var branding: Branding = .original
    var body: some View {
        row.contextMenu {
            if link.isConnected {
                Button("Auf Fernseher abspielen", systemImage: "tv") { link.play(item) }
                Button("Beim Fernseher einreihen", systemImage: "text.badge.plus") { link.addToQueue(item) }
            }
            if let id = item.channelId, let name = item.channelName {
                Button("Kanal „\(name)“ öffnen") { app.channelRoute = ChannelRef(channelId: id, name: name) }
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: branding.thumbnailUrl ?? item.thumbnailUrl)) { $0.resizable().aspectRatio(16 / 9, contentMode: .fill) }
                placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 140, height: 79).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let d = item.durationSeconds, !item.isLive { Text(Self.format(d)).font(.caption2).padding(3)
                        .background(.black.opacity(0.7)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 4)).padding(4) }
                    else if item.isLive { Text("LIVE").font(.caption2.bold()).padding(3).background(.red).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).padding(4) }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(branding.title ?? item.title).font(.subheadline).lineLimit(2)
                Text([item.channelName, item.viewCountText, item.publishedText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .task(id: item.videoId) {
            // Nur mit eingeschaltetem DeArrow (Video-IDs gehen dann an den DeArrow-Dienst); Fehler → Original.
            guard await AppEnvironment.shared.settings.current().deArrowEnabled, !item.isShort else { branding = .original; return }
            branding = (try? await AppEnvironment.shared.deArrow.branding(item.videoId)) ?? .original
        }
    }

    static func format(_ seconds: Int64) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
