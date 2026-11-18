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

    func enqueue(_ v: VideoItem, quality: DownloadQuality) {
        Task { await repo.enqueue([DownloadRequestItem(videoId: v.videoId, title: v.title, channelName: v.channelName, thumbnailUrl: v.thumbnailUrl)], quality: quality) }
    }
    func retry(_ r: DownloadRecord) { Task { await repo.retry(r) } }
    func delete(_ r: DownloadRecord) { Task { await repo.delete(r) } }
}
