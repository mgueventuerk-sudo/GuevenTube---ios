#if canImport(AVFoundation)
import Foundation
import AVFoundation
import GuevenCore

/// Führt Downloads mit einer Hintergrund-`URLSession` aus (`DownloadScheduling`). Bild und Ton werden getrennt geladen und
/// per `AVAssetExportSession` (Passthrough, ohne Neukodierung) zusammengefügt. Apple-only, bis zum ersten Mac-Lauf ungetestet.
///
/// Bekannte Risiken [wahrscheinlich]: googlevideo drosselt oder sperrt einzelne Vollabrufe großer Dateien; Android lädt in
/// Bereichen (`Range`) mit mehreren Verbindungen. Hier läuft je Teil eine Anfrage – bei Fehlern Wiederholen im Menü.
final class DownloadManager: NSObject, DownloadScheduling, URLSessionDownloadDelegate, URLSessionDelegate, @unchecked Sendable {
    static let sessionId = "de.gueventube.app.downloads"
    /// Wird von `AppDelegate` gesetzt, wenn iOS die App für fertige Hintergrund-Übertragungen weckt.
    var backgroundCompletion: (() -> Void)?

    private let store: DownloadStore
    private let resolver: StreamResolver
    private let fm = FileManager.default
    private let lock = NSLock()
    private var parts: [Int64: [String: (written: Int64, total: Int64)]] = [:]
    private var finalizing: Set<Int64> = []
    private var lastTick: [Int64: (at: Date, bytes: Int64)] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    init(store: DownloadStore, resolver: StreamResolver) {
        self.store = store; self.resolver = resolver
        super.init()
        _ = session // Sitzung früh anlegen, damit iOS ausstehende Ereignisse zustellt.
    }

    static var downloadsDirectory: URL {
        let base = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func staging(_ id: Int64) -> URL {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("download-staging/\(id)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: DownloadScheduling

    func schedule(downloadId: Int64) async {
        guard let record = await store.get(downloadId) else { return }
        // Nach App-Neustart laufen Hintergrund-Übertragungen weiter: nicht doppelt starten (`resumePending`).
        if await session.allTasks.contains(where: { info($0)?.id == downloadId }) { return }
        let now = Self.now()
        await store.setStatus(downloadId, .running, now: now)
        do {
            let playback = try await resolver.resolve(record.videoId, forceRefresh: true, trackAsLastRequested: false)
            guard let formats = DownloadPlanner.resolveFormats(playback, record) else {
                await store.setFailed(downloadId, message: "Kein passendes Format gefunden", now: Self.now()); return
            }
            lock.withLock { parts[downloadId] = [:]; lastTick[downloadId] = nil }
            if let v = formats.videoFormat { try start(v, role: "video", id: downloadId, ua: playback.userAgent) }
            try start(formats.audioFormat, role: "audio", id: downloadId, ua: playback.userAgent)
            await store.setProgress(downloadId, percent: 0, downloadedBytes: 0, totalBytes: nil, bytesPerSecond: 0,
                                    stage: formats.videoFormat == nil ? "Ton wird geladen" : "Bild und Ton werden geladen", now: Self.now())
        } catch {
            await store.setFailed(downloadId, message: String(describing: error), now: Self.now())
        }
    }

    private func start(_ format: StreamFormat, role: String, id: Int64, ua: String) throws {
        guard let s = format.url, let url = URL(string: s) else { throw DownloadStartError.noURL }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(id)|\(role)|\(format.mimeType.contains("audio") ? "m4a" : "mp4")"
        task.resume()
    }
    enum DownloadStartError: Error { case noURL }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func info(_ task: URLSessionTask) -> (id: Int64, role: String, ext: String)? {
        let p = (task.taskDescription ?? "").split(separator: "|").map(String.init)
        guard p.count == 3, let id = Int64(p[0]) else { return nil }
        return (id, p[1], p[2])
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = info(downloadTask) else { return }
        let (written, total, speed): (Int64, Int64, Int64) = lock.withLock {
            parts[t.id, default: [:]][t.role] = (totalBytesWritten, totalBytesExpectedToWrite)
            let all = parts[t.id] ?? [:]
            let w = all.values.reduce(0) { $0 + $1.written }
            let tot = all.values.allSatisfy { $0.total > 0 } ? all.values.reduce(0) { $0 + $1.total } : 0
            let now = Date()
            var bps: Int64 = 0
            if let last = lastTick[t.id] {
                let dt = now.timeIntervalSince(last.at)
                if dt < 1 { return (w, tot, -1) }
                bps = Int64(Double(w - last.bytes) / dt)
            }
            lastTick[t.id] = (now, w)
            return (w, tot, bps)
        }
        guard speed >= 0 else { return }
        let percent = total > 0 ? Int(min(written * 100 / total, 100)) : 0
        Task { await store.setProgress(t.id, percent: min(percent, DownloadPlanner.remuxStart - 1), downloadedBytes: written,
                                       totalBytes: total > 0 ? total : nil, bytesPerSecond: speed, stage: "Wird geladen", now: Self.now()) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let t = info(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { await store.setFailed(t.id, message: "HTTP \(http.statusCode)", now: Self.now()) }
            return
        }
        // Die temporäre Datei verschwindet nach diesem Aufruf: sofort in den Zwischenordner verschieben.
        let dest = staging(t.id).appendingPathComponent("\(t.role).\(t.ext)")
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: location, to: dest) } catch {
            Task { await store.setFailed(t.id, message: "Datei nicht speicherbar: \(error.localizedDescription)", now: Self.now()) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = info(task) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            Task { await store.setFailed(t.id, message: error.localizedDescription, now: Self.now()) }
            return
        }
        Task { await finalizeIfComplete(t.id) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }

    // MARK: Abschluss

    private func finalizeIfComplete(_ id: Int64) async {
        guard let record = await store.get(id), record.status == .running else { return }
        guard lock.withLock({ finalizing.insert(id).inserted }) else { return } // beide Teile melden sich fast gleichzeitig
        defer { lock.withLock { _ = finalizing.remove(id) } }
        let dir = staging(id)
        let video = dir.appendingPathComponent("video.mp4"), audio = dir.appendingPathComponent("audio.m4a")
        let hasVideo = fm.fileExists(atPath: video.path), hasAudio = fm.fileExists(atPath: audio.path)
        let needsVideo = record.kind == .video
        guard hasAudio, hasVideo || !needsVideo else { return } // der andere Teil läuft noch
        await store.setProgress(id, percent: DownloadPlanner.remuxStart, downloadedBytes: record.downloadedBytes, totalBytes: record.totalBytes,
                                bytesPerSecond: 0, stage: needsVideo ? "Wird zusammengefügt" : "Wird gespeichert", now: Self.now())
        let ext = needsVideo ? "mp4" : "m4a"
        let name = DownloadPlanner.fileName(record.fileName ?? record.title, extension: ext)
        let out = uniqueURL(Self.downloadsDirectory.appendingPathComponent(name))
        do {
            if needsVideo { try await merge(video: video, audio: audio, to: out) }
            else { try fm.moveItem(at: audio, to: out) }
            let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
            await store.setDone(id, location: out.lastPathComponent, bytes: size, now: Self.now())
            try? fm.removeItem(at: dir)
        } catch {
            await store.setFailed(id, message: "Zusammenfügen fehlgeschlagen: \(error.localizedDescription)", now: Self.now())
        }
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url, n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n)).\(url.pathExtension)")
        }
        return candidate
    }

    private func merge(video: URL, audio: URL, to out: URL) async throws {
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = try await v.loadTracks(withMediaType: .video).first, let at = try await a.loadTracks(withMediaType: .audio).first else {
            throw MergeError.missingTrack
        }
        let duration = CMTimeMinimum(try await v.load(.duration), try await a.load(.duration))
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MergeError.missingTrack }
        let range = CMTimeRange(start: .zero, duration: duration)
        try cv.insertTimeRange(range, of: vt, at: .zero)
        try ca.insertTimeRange(range, of: at, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw MergeError.exportUnavailable }
        export.outputURL = out
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        if export.status != .completed { throw export.error ?? MergeError.exportUnavailable }
    }
    enum MergeError: Error { case missingTrack, exportUnavailable }
}
#endif
