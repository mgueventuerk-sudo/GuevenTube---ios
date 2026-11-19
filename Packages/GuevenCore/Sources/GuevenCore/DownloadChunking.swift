import Foundation

/// Downloads in Stücken statt in einem Vollabruf: der Videoserver drosselt große Vollabrufe, Teilabrufe (wie bei yt-dlp,
/// ca. 10 MB) bleiben schnell.
public enum DownloadChunking {
    public static let chunkSize: Int64 = 10 * 1024 * 1024

    /// Byte-Bereich (einschließlich Ende) des nächsten Stücks ab [offset], oder `nil` wenn nichts mehr zu laden ist.
    public static func range(offset: Int64, total: Int64, chunk: Int64 = chunkSize) -> (start: Int64, end: Int64)? {
        guard total > 0, offset >= 0, offset < total, chunk > 0 else { return nil }
        return (offset, min(offset + chunk, total) - 1)
    }

    /// Lohnt sich Aufteilen? Kleine oder unbekannte Größen laufen wie bisher in einem Abruf.
    public static func shouldChunk(total: Int64?, chunk: Int64 = chunkSize) -> Bool { (total ?? 0) > chunk }
}
