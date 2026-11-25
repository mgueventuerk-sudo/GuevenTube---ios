import SwiftUI
import GuevenCore

@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    private let store: DownloadStore
    private let repo: DownloadRepository
    private var observer: Task<Void, Never>?

    init() {
        let env = AppEnvironment.shared
        store = env.downloadStore; repo = env.downloads
    }

    func start() {
        observer?.cancel()
        observer = Task { [weak self] in
            guard let self else { return }
            self.records = await store.all()
            for await _ in await store.updates() { self.records = await store.all() }
        }
    }
    func stop() { observer?.cancel() }

    /// Kurze Rückmeldung nach dem Einreihen (wird von `.downloadNotice` als Hinweis gezeigt).
    @Published var notice: String?

    func enqueue(_ v: VideoItem, quality: DownloadQuality) { enqueue([v], quality: quality) }

    /// Mehrere Videos (z. B. eine ganze Playlist). Was schon geladen wird oder fertig ist, wird nicht doppelt eingereiht.
    func enqueue(_ videos: [VideoItem], quality: DownloadQuality) {
        enqueue(videos.map { DownloadRequestItem(videoId: $0.videoId, title: $0.title, channelName: $0.channelName, thumbnailUrl: $0.thumbnailUrl) }, quality: quality)
    }

    /// Musik: immer nur Ton.
    func enqueue(songs: [MusicSong]) {
        enqueue(songs.map { DownloadRequestItem(videoId: $0.videoId, title: $0.title, channelName: $0.artists, thumbnailUrl: $0.thumbnailUrl) }, quality: .audioOnly)
    }

    /// Ganzes Album/Playlist aus dem Kontextmenü: erst die Titel laden, dann einreihen (immer nur Ton).
    func enqueue(collection c: MusicCollection, using music: MusicModel) {
        Task {
            do {
                let d = try await music.detail(c.browseId)
                if d.tracks.isEmpty { notice = "Keine Titel gefunden." } else { enqueue(songs: d.tracks) }
            } catch { notice = GTError.text(error) }
        }
    }

    /// Video-Playlist aus der Suche: Einträge laden, dann einreihen.
    func enqueue(playlist p: PlaylistItem, quality: DownloadQuality, using innerTube: InnerTubeService) {
        Task {
            guard let browseId = p.browseId else { notice = "Diese Playlist lässt sich nicht herunterladen."; return }
            do {
                let page = InnerTubeParser.parseFeed(try await innerTube.browse(browseId: browseId), defaultShelfTitle: p.title)
                let items = page.shelves.flatMap(\.items)
                if items.isEmpty { notice = "Die Playlist ist leer oder nicht abrufbar." } else { enqueue(items, quality: quality) }
            } catch { notice = GTError.text(error) }
        }
    }

    /// Kanal aus der Suche: nur die erste Seite seiner Videos (nicht der ganze Kanal), ohne Livestreams.
    func enqueue(channelId: String, quality: DownloadQuality, using innerTube: InnerTubeService) {
        Task {
            do {
                let page = InnerTubeParser.parseFeed(try await innerTube.browse(browseId: channelId), defaultShelfTitle: "Videos")
                let items = page.shelves.flatMap(\.items).filter { !$0.isLive }
                if items.isEmpty { notice = "Keine Videos gefunden." } else { enqueue(items, quality: quality) }
            } catch { notice = GTError.text(error) }
        }
    }

    /// Mix: ein Mix ist endlos und nicht abrufbar. Geladen werden das Start-Video und die Empfehlungen dazu (höchstens 24).
    func enqueue(mix p: PlaylistItem, quality: DownloadQuality, using innerTube: InnerTubeService) {
        Task {
            guard let first = p.firstVideoId else { notice = "Dieser Mix lässt sich nicht herunterladen."; return }
            do {
                let related = InnerTubeParser.parseWatchNext(try await innerTube.next(videoId: first), videoId: first).related
                let start = VideoItem(videoId: first, title: p.title, channelName: p.ownerName, thumbnailUrl: p.thumbnailUrl ?? InnerTubeParser.fallbackThumbnail(first))
                enqueue([start] + related.filter { !$0.isLive }.prefix(24), quality: quality)
            } catch { notice = GTError.text(error) }
        }
    }

    private func enqueue(_ items: [DownloadRequestItem], quality: DownloadQuality) {
        Task {
            let kind: DownloadKind = quality == .audioOnly ? .audio : .video
            let existing = await store.all()
            var seen = Set(existing.filter { $0.kind == kind && $0.status != .failed }.map(\.videoId))
            let fresh = items.filter { seen.insert($0.videoId).inserted }
            if !fresh.isEmpty { await repo.enqueue(fresh, quality: quality) }
            let skipped = items.count - fresh.count
            notice = fresh.isEmpty ? "Schon in den Downloads." :
                "\(fresh.count) \(fresh.count == 1 ? "Download" : "Downloads") gestartet" + (skipped > 0 ? " (\(skipped) schon vorhanden)" : "") + ". Fortschritt unter Konto → Downloads."
        }
    }
    func retry(_ r: DownloadRecord) { Task { await repo.retry(r) } }
    func delete(_ r: DownloadRecord) { Task { await repo.delete(r) } }
}

extension View {
    /// Zeigt die Rückmeldung von `DownloadsModel.notice` als Hinweis.
    func downloadNotice(_ downloads: DownloadsModel) -> some View {
        alert("Downloads", isPresented: Binding(get: { downloads.notice != nil }, set: { if !$0 { downloads.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(downloads.notice ?? "") }
    }
}

/// Eintrag „Herunterladen“ mit Qualitätswahl für Kontextmenüs (langes Drücken).
struct DownloadQualityMenu: View {
    var title = "Herunterladen"
    let action: (DownloadQuality) -> Void
    var body: some View {
        Menu {
            ForEach([DownloadQuality.audioOnly, .sd, .hd, .fullHd], id: \.self) { q in
                Button(q.label) { action(q) }
            }
        } label: { Label(title, systemImage: "arrow.down.circle") }
    }
}

/// Menü mit Qualitätsstufen für mehrere Videos (Playlist).
struct DownloadAllMenu: View {
    let videos: [VideoItem]
    @ObservedObject var downloads: DownloadsModel
    var body: some View {
        Menu {
            ForEach([DownloadQuality.audioOnly, .sd, .hd, .fullHd], id: \.self) { q in
                Button(q.label) { downloads.enqueue(videos, quality: q) }
            }
        } label: { Label("Alle herunterladen", systemImage: "arrow.down.circle") }
    }
}
