import Foundation
import GuevenCore

/// Letzte Startseite auf dem Gerät: erscheint beim Öffnen sofort, während die neue aus dem Netz nachgeladen wird.
enum FeedDiskCache {
    private static var url: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("start-feed.json")
    }

    static func load() -> [Shelf]? {
        guard let data = try? Data(contentsOf: url), let page = try? JSONDecoder().decode(FeedPage.self, from: data),
              !page.shelves.isEmpty else { return nil }
        return page.shelves
    }

    static func save(_ page: FeedPage) {
        guard !page.shelves.isEmpty, let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
