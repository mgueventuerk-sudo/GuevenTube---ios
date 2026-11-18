import SwiftUI
import GuevenCore

struct VideoRow: View {
    let item: VideoItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: item.thumbnailUrl)) { $0.resizable().aspectRatio(16 / 9, contentMode: .fill) }
                placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 140, height: 79).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let d = item.durationSeconds, !item.isLive { Text(Self.format(d)).font(.caption2).padding(3)
                        .background(.black.opacity(0.7)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 4)).padding(4) }
                    else if item.isLive { Text("LIVE").font(.caption2.bold()).padding(3).background(.red).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).padding(4) }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline).lineLimit(2)
                Text([item.channelName, item.viewCountText, item.publishedText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    static func format(_ seconds: Int64) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
