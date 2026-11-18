import Foundation

/// Musik-Sitzung (laufender Titel, Warteschlange, Wiederholen, Radio), damit sie Absturz und Beendigung wegen
/// Speichermangels übersteht (Port von MusicSessionStore.kt). Kleine JSON-Datei in den privaten App-Daten.
/// Das Entprellen (2 s) übernimmt die App-Schicht; hier steht das Format samt Altersgrenze.
public struct MusicSessionStore: Sendable {
    public struct Saved: Codable, Equatable, Sendable {
        public var current: Song
        public var queue: [Song]
        public var repeatMode: String
        public var radio: Bool
        public var savedAtMs: Int64

        enum CodingKeys: String, CodingKey { case current, queue, repeatMode = "repeat", radio, savedAtMs }

        public init(current: Song, queue: [Song], repeatMode: String = "OFF", radio: Bool = false, savedAtMs: Int64 = 0) {
            self.current = current; self.queue = queue; self.repeatMode = repeatMode; self.radio = radio; self.savedAtMs = savedAtMs
        }

        // Fehlende Felder älterer Dateien bekommen Standardwerte; unbekannte Felder werden ignoriert.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            current = try c.decode(Song.self, forKey: .current)
            queue = try c.decode([Song].self, forKey: .queue)
            repeatMode = try c.decodeIfPresent(String.self, forKey: .repeatMode) ?? "OFF"
            radio = try c.decodeIfPresent(Bool.self, forKey: .radio) ?? false
            savedAtMs = try c.decodeIfPresent(Int64.self, forKey: .savedAtMs) ?? 0
        }
    }

    public struct Song: Codable, Equatable, Sendable {
        public var videoId: String
        public var title: String
        public var artists: String?
        public var album: String?
        public var thumbnailUrl: String?
        public var durationSeconds: Int64?
        public var playlistId: String?

        public init(_ s: MusicSong) {
            videoId = s.videoId; title = s.title; artists = s.artists; album = s.album
            thumbnailUrl = s.thumbnailUrl; durationSeconds = s.durationSeconds; playlistId = s.playlistId
        }

        public func toSong() -> MusicSong {
            MusicSong(videoId: videoId, title: title, artists: artists, album: album, thumbnailUrl: thumbnailUrl,
                      durationSeconds: durationSeconds, playlistId: playlistId)
        }
    }

    public static let maxSaved = 100
    public static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    public let fileURL: URL
    private let nowMs: @Sendable () -> Int64

    public init(fileURL: URL, nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.fileURL = fileURL; self.nowMs = nowMs
    }

    /// Atomar schreiben (Temp-Datei + Ersetzen), damit ein Abbruch nie eine halbe Datei hinterlässt.
    public func save(current: MusicSong, queue: [MusicSong], repeatMode: MusicRepeat, radio: Bool) throws {
        let saved = Saved(current: Song(current), queue: queue.prefix(Self.maxSaved).map(Song.init),
                          repeatMode: repeatMode.rawValue, radio: radio, savedAtMs: nowMs())
        let data = try JSONEncoder().encode(saved)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Gespeicherte Sitzung, wenn höchstens 7 Tage alt und lesbar; sonst `nil`.
    public func load() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return nowMs() - saved.savedAtMs < Self.maxAgeMs ? saved : nil
    }

    public func clear() { try? FileManager.default.removeItem(at: fileURL) }
}
