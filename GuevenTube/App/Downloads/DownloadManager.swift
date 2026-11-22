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
    /// Je Auftrag: geschriebene Bytes je Übertragung (Schlüssel „Rolle|Start“) und Gesamtgröße je Rolle (Bild/Ton).
    private var written: [Int64: [String: Int64]] = [:]
    private var roleTotals: [Int64: [String: Int64]] = [:]
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
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = dir; try? excluded.setResourceValues(values) // Teil-Downloads gehören nicht ins Backup
        return dir
    }

    // MARK: DownloadScheduling

    func schedule(downloadId: Int64) async {
        guard let record = await store.get(downloadId) else { return }
        // Nach App-Neustart laufen Hintergrund-Übertragungen weiter: nicht doppelt starten (`resumePending`).
        if await session.allTasks.contains(where: { info($0)?.id == downloadId }) { return }
        // Alle Teile waren schon fertig, als die App beendet wurde: nur noch zusammenfügen statt von vorn zu laden.
        if record.status == .running, await finalizeIfComplete(downloadId) { return }
        let now = Self.now()
        await store.setStatus(downloadId, .running, now: now)
        do {
            let playback = try await resolver.resolve(record.videoId, forceRefresh: true, trackAsLastRequested: false)
            guard let formats = DownloadPlanner.resolveFormats(playback, record) else {
                await store.setFailed(downloadId, message: "Kein passendes Format gefunden", now: Self.now()); return
            }
            lock.withLock { written[downloadId] = [:]; roleTotals[downloadId] = [:]; lastTick[downloadId] = nil }
            try? fm.removeItem(at: staging(downloadId)) // Reste eines früheren Versuchs nicht mit neuen Teilen mischen
            if let v = formats.videoFormat { try start(v, role: "video", id: downloadId, ua: playback.userAgent) }
            try start(formats.audioFormat, role: "audio", id: downloadId, ua: playback.userAgent)
            await store.setProgress(downloadId, percent: 0, downloadedBytes: 0, totalBytes: nil, bytesPerSecond: 0,
                                    stage: formats.videoFormat == nil ? "Ton wird geladen" : "Bild und Ton werden geladen", now: Self.now())
        } catch {
            await fail(downloadId, (error as? PlaybackUnavailableError)?.message ?? error.localizedDescription)
        }
    }

    /// Auftrag wurde gelöscht: Übertragungen stoppen, Zwischendateien und Zähler entfernen (sonst lädt iOS im Hintergrund weiter).
    func cancel(downloadId id: Int64) async {
        for task in await session.allTasks where info(task)?.id == id { task.cancel() }
        lock.withLock { written[id] = nil; roleTotals[id] = nil; lastTick[id] = nil }
        try? fm.removeItem(at: staging(id))
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
        let size = format.contentLength ?? 0
        // Erwartete Größe merken: Beim Zusammensetzen wird geprüft, dass wirklich alles da ist (sonst „halbe“ Dateien).
        try? "\(size)".write(to: staging(id).appendingPathComponent("\(role).size"), atomically: true, encoding: .utf8)
        lock.withLock { roleTotals[id, default: [:]][role] = size }
        guard DownloadChunking.shouldChunk(total: size) else {
            enqueue(req, id: id, role: role, ext: ext, offset: 0, total: 0)
            return
        }
        // Alle Stücke sofort einreihen (nicht eins nach dem anderen aus der App heraus): iOS lädt sie auch bei gesperrtem
        // Bildschirm oder beendeter App weiter; eine abgebrochene Kette ließ früher halbe Downloads zurück.
        var offset: Int64 = 0
        while let r = DownloadChunking.range(offset: offset, total: size) {
            enqueue(req, id: id, role: role, ext: ext, offset: offset, total: size)
            offset = r.end + 1
        }
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
        let (done, total, speed): (Int64, Int64, Int64) = lock.withLock {
            written[t.id, default: [:]]["\(t.role)|\(t.offset)"] = totalBytesWritten
            if t.total == 0, roleTotals[t.id]?[t.role] ?? 0 == 0 { roleTotals[t.id, default: [:]][t.role] = max(totalBytesExpectedToWrite, 0) }
            let w = (written[t.id] ?? [:]).values.reduce(0, +)
            let totals = roleTotals[t.id] ?? [:]
            let tot = !totals.isEmpty && totals.values.allSatisfy { $0 > 0 } ? totals.values.reduce(0, +) : 0
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
        let percent = total > 0 ? Int(min(done * 100 / total, 100)) : 0
        Task { await store.setProgress(t.id, percent: min(percent, DownloadPlanner.remuxStart - 1), downloadedBytes: done,
                                       totalBytes: total > 0 ? total : nil, bytesPerSecond: speed, stage: "Wird geladen", now: Self.now()) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let t = info(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { await fail(t.id, "Der Videoserver hat den Download abgelehnt (HTTP \(http.statusCode)). Versuche es später erneut.") }
            return
        }
        // Die temporäre Datei verschwindet nach diesem Aufruf: sofort in den Zwischenordner verschieben.
        let dir = staging(t.id)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let full = dir.appendingPathComponent("\(t.role).\(t.ext)")
        do {
            if t.total == 0 || status == 200 {
                // Ganze Datei: kein Stückabruf geplant, oder der Server hat den Bereich ignoriert (200 statt 206) und alles geliefert.
                try? fm.removeItem(at: full)
                try fm.moveItem(at: location, to: full)
            } else {
                // Ein Stück: eigene Datei je Startposition; zusammengesetzt wird erst, wenn alle da sind.
                let expected = DownloadChunking.range(offset: t.offset, total: t.total).map { $0.end - $0.start + 1 } ?? 0
                let got = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
                guard got == expected else { throw ChunkError.incomplete(got: got, expected: expected) }
                let chunk = dir.appendingPathComponent("\(t.role).\(t.offset).chunk")
                try? fm.removeItem(at: chunk)
                try fm.moveItem(at: location, to: chunk)
            }
        } catch {
            Task { await fail(t.id, "Datei nicht speicherbar: \(error.localizedDescription)") }
        }
    }
    private enum ChunkError: Error, LocalizedError {
        case incomplete(got: Int64, expected: Int64), missing(role: String)
        var errorDescription: String? {
            switch self {
            case .incomplete(let g, let e): return "Teilstück unvollständig (\(g) von \(e) Bytes)"
            case .missing(let r): return "\(r == "video" ? "Bild" : "Ton") unvollständig geladen"
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = info(task) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            Task { await fail(t.id, error.localizedDescription) }
            return
        }
        Task { _ = await finalizeIfComplete(t.id) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }

    // MARK: Abschluss

    /// Fügt Teile zusammen, sobald Bild und Ton vollständig da sind. `true`: Auftrag ist abgeschlossen (oder fehlgeschlagen).
    @discardableResult
    private func finalizeIfComplete(_ id: Int64) async -> Bool {
        guard let record = await store.get(id), record.status == .running else { return false }
        guard lock.withLock({ finalizing.insert(id).inserted }) else { return false } // mehrere Teile melden sich fast gleichzeitig
        defer { lock.withLock { _ = finalizing.remove(id) } }
        let dir = staging(id)
        let needsVideo = record.kind == .video
        let video = dir.appendingPathComponent("video.mp4"), audio = dir.appendingPathComponent("audio.m4a")
        // Stücke prüfen und zusammensetzen; fehlt eins, läuft der Rest noch.
        guard assemble(role: "audio", ext: "m4a", in: dir) else { return false }
        if needsVideo, !assemble(role: "video", ext: "mp4", in: dir) { return false }
        guard fm.fileExists(atPath: audio.path), !needsVideo || fm.fileExists(atPath: video.path) else { return false }
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
            return true
        } catch {
            try? fm.removeItem(at: out) // halb geschriebene Ausgabedatei nicht liegen lassen
            try? fm.removeItem(at: dir)
            await store.setFailed(id, message: "Zusammenfügen fehlgeschlagen: \(error.localizedDescription)", now: Self.now())
            return true
        }
    }

    /// Prüft, ob [role] vollständig vorliegt (ganze Datei oder alle Stücke in voller Größe), und setzt die Stücke zu einer Datei zusammen.
    private func assemble(role: String, ext: String, in dir: URL) -> Bool {
        let target = dir.appendingPathComponent("\(role).\(ext)")
        let expected = (try? String(contentsOf: dir.appendingPathComponent("\(role).size"), encoding: .utf8)).flatMap { Int64($0) } ?? 0
        func size(_ u: URL) -> Int64 { (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }
        if fm.fileExists(atPath: target.path) { return expected == 0 || size(target) >= expected }
        guard expected > 0 else { return false }
        var chunks: [URL] = []
        var offset: Int64 = 0
        while let r = DownloadChunking.range(offset: offset, total: expected) {
            let c = dir.appendingPathComponent("\(role).\(offset).chunk")
            guard fm.fileExists(atPath: c.path), size(c) == r.end - r.start + 1 else { return false }
            chunks.append(c)
            offset = r.end + 1
        }
        let part = target.appendingPathExtension("part")
        do {
            try? fm.removeItem(at: part)
            fm.createFile(atPath: part.path, contents: nil)
            let out = try FileHandle(forWritingTo: part)
            defer { try? out.close() }
            for c in chunks {
                let input = try FileHandle(forReadingFrom: c)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1 << 20), !data.isEmpty { try out.write(contentsOf: data) }
            }
            guard size(part) == expected else { try? fm.removeItem(at: part); return false }
            try fm.moveItem(at: part, to: target)
            chunks.forEach { try? fm.removeItem(at: $0) }
            return true
        } catch { try? fm.removeItem(at: part); return false }
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
        // Das Bild bestimmt die Länge; eine etwas kürzere Tonspur (z. B. bei Synchronfassungen) schneidet das Video nicht ab.
        let videoDuration = try await v.load(.duration)
        let audioDuration = CMTimeMinimum(try await a.load(.duration), videoDuration)
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MergeError.missingTrack }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: vt, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: at, at: .zero)
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
