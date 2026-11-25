import SwiftUI
import GuevenCore

/// Eine Video-Zeile. `.card` (Start, Suche, Kanal): großes Vorschaubild über dem Text wie in der Android-App.
/// `.compact` (Mediathek, Playlists, Verlauf): kleines Bild links. Antippen spielt ab; „⋯“ (und langes Drücken) öffnen
/// überall dieselben Aktionen in derselben Reihenfolge: Fernseher, Später ansehen, Herunterladen, Kanal.
struct VideoRow: View {
    enum Style { case card, compact }

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var link = LinkModel.shared
    let item: VideoItem
    var style: Style = .compact
    /// Standard: sofort abspielen. Der Kanal ersetzt das (Sheet erst schließen).
    var onPlay: (() -> Void)?
    @State private var branding: Branding = .original
    @StateObject private var downloads = DownloadsModel()

    var body: some View {
        Group {
            switch style {
            case .card: card
            case .compact: compact
            }
        }
        .contextMenu { actions }
        .downloadNotice(downloads)
        .task(id: item.videoId) {
            // Nur mit eingeschaltetem DeArrow (Video-IDs gehen dann an den DeArrow-Dienst); Fehler → Original.
            guard await AppEnvironment.shared.settings.current().deArrowEnabled, !item.isShort else { branding = .original; return }
            branding = (try? await AppEnvironment.shared.deArrow.branding(item.videoId)) ?? .original
        }
    }

    private func play() { if let onPlay { onPlay() } else { app.play(item) } }
    private var thumbnailUrl: String { branding.thumbnailUrl ?? item.thumbnailUrl }
    private var title: String { branding.title ?? item.title }
    private var meta: String { [item.channelName, item.viewCountText, item.publishedText].compactMap { $0 }.joined(separator: " · ") }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) { VideoThumbnail(url: thumbnailUrl, item: item, corner: GT.Metric.cornerCard) }
                .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 4) {
                Button(action: play) { texts(titleFont: .subheadline.weight(.semibold)) }.buttonStyle(.plain)
                moreMenu
            }
        }
        .padding(.horizontal, GT.Metric.page).padding(.vertical, 10)
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(GT.background)
    }

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) { VideoThumbnail(url: thumbnailUrl, item: item).frame(width: 140) }.buttonStyle(.plain)
            Button(action: play) { texts(titleFont: .subheadline) }.buttonStyle(.plain)
            moreMenu
        }
        .listRowBackground(GT.background)
    }

    private func texts(titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(titleFont).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(2)
            if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(GT.secondaryText).multilineTextAlignment(.leading).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var moreMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(GT.secondaryText)
                .frame(width: GT.Metric.touch, height: GT.Metric.touch).contentShape(Rectangle())
        }
        .accessibilityLabel("Weitere Aktionen")
    }

    @ViewBuilder private var actions: some View {
        if link.isConnected {
            Button("Auf Fernseher abspielen", systemImage: "tv") { link.play(item) }
            Button("Beim Fernseher einreihen", systemImage: "text.badge.plus") { link.addToQueue(item) }
        }
        Button("Später ansehen", systemImage: "clock") { Task { await AppEnvironment.shared.library.addToWatchLater(item) } }
        DownloadQualityMenu { downloads.enqueue(item, quality: $0) }
        if let id = item.channelId, let name = item.channelName {
            Button("Kanal „\(name)“ öffnen", systemImage: "person.crop.circle") { app.channelRoute = ChannelRef(channelId: id, name: name) }
        }
    }

    static func format(_ seconds: Int64) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
