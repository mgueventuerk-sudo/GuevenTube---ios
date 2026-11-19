#if canImport(AVFoundation)
import Foundation
import AVFoundation
import UIKit
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
        // Wie die Wiedergabe und die Android-App: ohne Cookies (sonst kann der Videoserver Anfragen anders bewerten).
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
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
            await fail(downloadId, (error as? PlaybackUnavailableError)?.message ?? error.localizedDescription)
        }
    }

    /// Fehler eintragen und den zweiten Teil (Bild/Ton) stoppen: Er würde sonst unnütz Daten laden.
    private func fail(_ id: Int64, _ message: String) async {
        await store.setFailed(id, message: message, now: Self.now())
        for task in await session.allTasks where info(task)?.id == id { task.cancel() }
    }

    private func start(_ format: StreamFormat, role: String, id: Int64, ua: String) throws {
        guard let s = format.url, let url = URL(string: s) else { throw DownloadStartError.noURL }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        // Origin/Referer wie bei der Wiedergabe: Der Videoserver nahm Anfragen ohne sie teils nicht an.
        req.setValue(HTTPConstants.youtubeOrigin, forHTTPHeaderField: "Origin")
        req.setValue(HTTPConstants.youtubeOrigin + "/", forHTTPHeaderField: "Referer")
        let ext = format.mimeType.contains("audio") ? "m4a" : "mp4"
        // Große Dateien in Stücken laden: Vollabrufe werden vom Videoserver gedrosselt.
        let total = DownloadChunking.shouldChunk(total: format.contentLength) ? (format.contentLength ?? 0) : 0
        enqueue(req, id: id, role: role, ext: ext, offset: 0, total: total)
    }

    /// Startet einen Abruf; bei [total] > 0 nur das Stück ab [offset]. Der Zustand steckt in `taskDescription`
    /// (id|Rolle|Endung|Start|Gesamtgröße), damit er auch nach einem Neustart der App im Hintergrund erhalten bleibt.
    private func enqueue(_ base: URLRequest, id: Int64, role: String, ext: String, offset: Int64, total: Int64) {
        var req = base
        if total > 0, let r = DownloadChunking.range(offset: offset, total: total) {
            req.setValue("bytes=\(r.start)-\(r.end)", forHTTPHeaderField: "Range")
        }
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(id)|\(role)|\(ext)|\(offset)|\(total)"
        task.resume()
    }
    enum DownloadStartError: Error { case noURL }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func info(_ task: URLSessionTask) -> (id: Int64, role: String, ext: String, offset: Int64, total: Int64)? {
        let p = (task.taskDescription ?? "").split(separator: "|").map(String.init)
        guard p.count == 3 || p.count == 5, let id = Int64(p[0]) else { return nil }
        if p.count == 3 { return (id, p[1], p[2], 0, 0) }   // Abruf aus einer älteren Version: ganze Datei
        return (id, p[1], p[2], Int64(p[3]) ?? 0, Int64(p[4]) ?? 0)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = info(downloadTask) else { return }
        let (written, total, speed): (Int64, Int64, Int64) = lock.withLock {
            parts[t.id, default: [:]][t.role] = (t.offset + totalBytesWritten, t.total > 0 ? t.total : totalBytesExpectedToWrite)
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
            Task { await fail(t.id, "Der Videoserver hat den Download abgelehnt (HTTP \(http.statusCode)). Versuche es später erneut.") }
            return
        }
        // Die temporäre Datei verschwindet nach diesem Aufruf: sofort in den Zwischenordner verschieben.
        let dest = staging(t.id).appendingPathComponent("\(t.role).\(t.ext)")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // Ganze Datei: kein Stückabruf geplant, oder der Server hat den Bereich ignoriert (200 statt 206) und alles geliefert.
        if t.total == 0 || status == 200 {
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: location, to: dest) } catch {
                Task { await fail(t.id, "Datei nicht speicherbar: \(error.localizedDescription)") }
            }
            return
        }
        // Ein Stück: an die Teildatei anhängen, beim letzten Stück zur fertigen Datei machen, sonst das nächste Stück starten.
        let part = dest.appendingPathExtension("part")
        do {
            if t.offset == 0 { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let size = Int64(end)
            if size > t.offset { try handle.truncate(atOffset: UInt64(t.offset)); try handle.seek(toOffset: UInt64(t.offset)) }
            else if size < t.offset { throw ChunkError.gap }
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            guard !data.isEmpty else { throw ChunkError.empty }
            try handle.write(contentsOf: data)
            let next = t.offset + Int64(data.count)
            if next >= t.total {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
            } else if let original = downloadTask.originalRequest {
                var copy = original
                copy.setValue(nil, forHTTPHeaderField: "Range")
                let nextRequest = copy
                let (id, role, ext, total) = (t.id, t.role, t.ext, t.total)
                Task { [weak self] in
                    guard let self, let record = await self.store.get(id), record.status == .running else { return }
                    self.enqueue(nextRequest, id: id, role: role, ext: ext, offset: next, total: total)
                }
            }
        } catch {
            Task { await fail(t.id, "Datei nicht speicherbar: \(error.localizedDescription)") }
        }
    }
    private enum ChunkError: Error, LocalizedError {
        case gap, empty
        var errorDescription: String? { self == .gap ? "Teilstück fehlt" : "Leeres Teilstück" }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = info(task) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            Task { await fail(t.id, error.localizedDescription) }
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
            if needsVideo { await saveToPhotos(out) }
        } catch {
            try? fm.removeItem(at: out) // halb geschriebene Ausgabedatei nicht liegen lassen
            await store.setFailed(id, message: "Zusammenfügen fehlgeschlagen: \(error.localizedDescription)", now: Self.now())
        }
    }

    /// Legt fertige Videos zusätzlich in die Fotos-App (Add-only-Berechtigung). Die Datei in „Dateien“ bleibt bestehen; Ton (m4a)
    /// kennt die Galerie nicht. Eine verweigerte Berechtigung lässt den Download selbst unberührt.
    @MainActor private func saveToPhotos(_ url: URL) {
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else { return }
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, self, #selector(photosSaveFinished(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    @objc private func photosSaveFinished(_ path: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {}

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
