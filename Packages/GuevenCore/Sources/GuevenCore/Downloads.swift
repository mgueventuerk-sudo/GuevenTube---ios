import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DownloadKind: String, Codable, Sendable { case video = "VIDEO", audio = "AUDIO", subtitle = "SUBTITLE" }
public enum DownloadStatus: String, Codable, Sendable { case queued = "QUEUED", running = "RUNNING", done = "DONE", failed = "FAILED" }

/// Minimaler Satz an Feldern, den ein Video oder Musiktitel für den Download braucht.
public struct DownloadRequestItem: Equatable, Sendable {
    public var videoId: String, title: String
    public var channelName: String?, thumbnailUrl: String?
    public init(videoId: String, title: String, channelName: String? = nil, thumbnailUrl: String? = nil) {
        self.videoId = videoId; self.title = title; self.channelName = channelName; self.thumbnailUrl = thumbnailUrl
    }
}

/// Download-Auftrag: ein Video kann mehrfach vorkommen (z. B. als Video UND als Ton).
public struct DownloadRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var videoId: String
    public var title: String
    public var channelName: String?
    public var thumbnailUrl: String?
    public var kind: DownloadKind
    /// Anzeige, z. B. „1080p“ oder „Nur Ton“.
    public var qualityLabel: String
    public var status: DownloadStatus
    /// `-1`, solange die Gesamtgröße unbekannt ist.
    public var progressPercent = 0
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64?
    public var bytesPerSecond: Int64 = 0
    /// Anzeige, z. B. „Ton wird geladen“, „Wird zusammengefügt“.
    public var stage: String?
    /// iOS: Dateiname relativ zum Download-Ordner (statt MediaStore-URI); erst nach Abschluss gesetzt.
    public var fileLocation: String?
    public var fileSizeBytes: Int64?
    public var errorMessage: String?
    /// Gesetzt bei der Massenauswahl; bei genauer Formatwahl `nil`.
    public var requestedQuality: String?
    public var videoItag: Int?
    public var audioItag: Int?
    public var subtitleLanguageCode: String?
    public var threadCount = 4
    /// Vom Nutzer gewählter Dateiname ohne Endung; `nil` = aus dem Titel ableiten.
    public var fileName: String?
    public var createdAt: Int64
    public var updatedAt: Int64
}

/// Download-Tabelle als JSON-Datei (ersetzt `DownloadDao`).
public actor DownloadStore {
    private struct Snapshot: Codable { var rows: [DownloadRecord] = []; var nextId: Int64 = 1 }
    private let file: URL?
    private var data: Snapshot
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(file: URL? = nil) {
        self.file = file
        if let file, let raw = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(Snapshot.self, from: raw) { data = d } else { data = Snapshot() }
    }

    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { c in listeners[id] = c; c.onTermination = { [weak self] _ in Task { await self?.drop(id) } } }
    }
    private func drop(_ id: UUID) { listeners[id] = nil }
    private func commit() {
        if let file {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(data).write(to: file, options: .atomic)
            } catch { /* bleibt im Speicher */ }
        }
        listeners.values.forEach { $0.yield() }
    }

    /// Neueste zuerst.
    public func all() -> [DownloadRecord] {
        data.rows.enumerated().sorted { $0.element.createdAt != $1.element.createdAt ? $0.element.createdAt > $1.element.createdAt : $0.offset > $1.offset }.map(\.element)
    }
    public func get(_ id: Int64) -> DownloadRecord? { data.rows.first { $0.id == id } }
    /// Noch nicht fertige Aufträge (wartend/laufend), älteste zuerst – für den Neustart nach App-Ende.
    public func pending() -> [DownloadRecord] {
        data.rows.enumerated().filter { $0.element.status == .queued || $0.element.status == .running }
            .sorted { $0.element.createdAt != $1.element.createdAt ? $0.element.createdAt < $1.element.createdAt : $0.offset < $1.offset }.map(\.element)
    }

    /// Vergibt die ID (der übergebene Wert wird ignoriert) und gibt sie zurück.
    @discardableResult
    public func insert(_ record: DownloadRecord) -> Int64 {
        var r = record; r.id = data.nextId; data.nextId += 1
        data.rows.append(r); commit(); return r.id
    }
    private func mutate(_ id: Int64, _ change: (inout DownloadRecord) -> Void) {
        guard let i = data.rows.firstIndex(where: { $0.id == id }) else { return }
        change(&data.rows[i]); commit()
    }
    public func setStatus(_ id: Int64, _ status: DownloadStatus, now: Int64) { mutate(id) { $0.status = status; $0.updatedAt = now } }
    public func setProgress(_ id: Int64, percent: Int, downloadedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Int64, stage: String, now: Int64) {
        mutate(id) { $0.progressPercent = percent; $0.downloadedBytes = downloadedBytes; $0.totalBytes = totalBytes; $0.bytesPerSecond = bytesPerSecond; $0.stage = stage; $0.updatedAt = now }
    }
    public func setDone(_ id: Int64, location: String, bytes: Int64, now: Int64) {
        mutate(id) { $0.status = .done; $0.progressPercent = 100; $0.fileLocation = location; $0.fileSizeBytes = bytes; $0.updatedAt = now }
    }
    public func setFailed(_ id: Int64, message: String, now: Int64) { mutate(id) { $0.status = .failed; $0.errorMessage = message; $0.updatedAt = now } }
    public func delete(_ id: Int64) { data.rows.removeAll { $0.id == id }; commit() }
}

/// Startet die eigentliche Arbeit (iOS: Hintergrund-`URLSession`).
public protocol DownloadScheduling: Sendable { func schedule(downloadId: Int64) async }

/// Legt Download-Aufträge an (ein Eintrag pro markiertem Video) und stößt je Eintrag die Ausführung an. Jeder Download
/// läuft unabhängig – ein gescheiterter darf nie andere mit sich reißen.
public actor DownloadRepository {
    private let store: DownloadStore
    private let scheduler: DownloadScheduling
    private let removeFile: @Sendable (String) async -> Void
    private let nowMs: @Sendable () -> Int64

    public init(store: DownloadStore, scheduler: DownloadScheduling, removeFile: @escaping @Sendable (String) async -> Void = { _ in },
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store; self.scheduler = scheduler; self.removeFile = removeFile; self.nowMs = nowMs
    }

    /// Je markiertem Item + gewählter Qualität ein Auftrag.
    public func enqueue(_ items: [DownloadRequestItem], quality: DownloadQuality, threadCount: Int = 4) async {
        let kind: DownloadKind = quality == .audioOnly ? .audio : .video
        for item in items {
            let now = nowMs()
            let id = await store.insert(DownloadRecord(id: 0, videoId: item.videoId, title: item.title, channelName: item.channelName, thumbnailUrl: item.thumbnailUrl,
                kind: kind, qualityLabel: quality.label, status: .queued, requestedQuality: quality.rawValue, threadCount: threadCount, createdAt: now, updatedAt: now))
            await scheduler.schedule(downloadId: id)
        }
    }

    /// Mit genau gewähltem Format: Video+Ton, nur Ton oder Untertitel.
    public func enqueueExplicit(_ item: DownloadRequestItem, kind: DownloadKind, qualityLabel: String, videoItag: Int?, audioItag: Int?,
                                subtitleLanguageCode: String?, threadCount: Int, fileName: String) async {
        let now = nowMs()
        let id = await store.insert(DownloadRecord(id: 0, videoId: item.videoId, title: item.title, channelName: item.channelName, thumbnailUrl: item.thumbnailUrl,
            kind: kind, qualityLabel: qualityLabel, status: .queued, requestedQuality: nil, videoItag: videoItag, audioItag: audioItag,
            subtitleLanguageCode: subtitleLanguageCode, threadCount: threadCount, fileName: fileName, createdAt: now, updatedAt: now))
        await scheduler.schedule(downloadId: id)
    }

    public func retry(_ record: DownloadRecord) async {
        await store.setStatus(record.id, .queued, now: nowMs())
        await scheduler.schedule(downloadId: record.id)
    }

    /// Entfernt Auftrag und – falls vorhanden – die fertige Datei.
    public func delete(_ record: DownloadRecord) async {
        if let loc = record.fileLocation { await removeFile(loc) }
        await store.delete(record.id)
    }

    /// Nach einem App-Neustart: alles, was noch wartet oder lief, erneut anstoßen.
    public func resumePending() async {
        for r in await store.pending() { await scheduler.schedule(downloadId: r.id) }
    }
}

/// Fortschritt einer Teilstufe.
public struct DownloadProgress: Equatable, Sendable {
    public var downloadedBytes: Int64, bytesPerSecond: Int64
    public var totalBytes: Int64?
    public init(downloadedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Int64) { self.downloadedBytes = downloadedBytes; self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond }
}

public struct DownloadHttpError: Error, Equatable, Sendable { public var code: Int; public init(code: Int) { self.code = code } }

/// Reine Entscheidungen des Download-Ablaufs (Port der Hilfsfunktionen aus `DownloadWorker`).
public enum DownloadPlanner {
    public static let audioShare = 45, remuxStart = 90

    /// Wählt Bild-/Tonformat: über die Qualitätsstufe (Massenauswahl) oder genau über das gewählte Format.
    public static func resolveFormats(_ playback: ResolvedPlayback, _ record: DownloadRecord) -> ResolvedDownloadFormats? {
        if let name = record.requestedQuality {
            return DownloadQualityResolver.resolve(playback, quality: DownloadQuality(rawValue: name) ?? .hd)
        }
        let adaptive = playback.adaptiveFormats.filter { !($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let audio = adaptive.first(where: { $0.itag == record.audioItag }) ?? DownloadQualityResolver.bestAudio(adaptive) else { return nil }
        if record.kind == .audio { return ResolvedDownloadFormats(videoFormat: nil, audioFormat: audio, qualityLabel: record.qualityLabel) }
        let common = DownloadQualityResolver.commonVideo(adaptive).enumerated().sorted { ($0.element.height ?? 0, $0.offset) < ($1.element.height ?? 0, $1.offset) }.map(\.element)
        let wanted = adaptive.first { $0.itag == record.videoItag } ?? playback.adaptiveFormats.first { $0.itag == record.videoItag }
        // Itag nicht mehr da (Dialog und Ausführung lösen getrennt auf): nächstniedrigere H.264-Höhe.
        let video = wanted.flatMap { w in common.contains(w) ? w : nil }
            ?? common.last { ($0.height ?? 0) <= (wanted?.height ?? Int.max) }
            ?? common.first
        guard let video else { return nil }
        return ResolvedDownloadFormats(videoFormat: video, audioFormat: audio, qualityLabel: record.qualityLabel)
    }

    /// Fortschritt dieser Stufe allein (0…100), `0` solange die Größe unbekannt ist.
    public static func stagePercent(_ p: DownloadProgress) -> Int {
        guard let total = p.totalBytes, total > 0 else { return 0 }
        return Int(min(max(p.downloadedBytes * 100 / total, 0), 100))
    }

    public enum Stage { case audioWithVideo, audioOnly, video, subtitle }
    /// Gesamtfortschritt (0…99): Ton 45 %, Bild bis 90 %, danach Zusammenfügen; ohne Bild und bei Untertiteln bis 95 %.
    public static func overallPercent(_ stage: Stage, _ p: DownloadProgress) -> Int {
        let s = stagePercent(p)
        let v: Int
        switch stage {
        case .audioWithVideo: v = s * audioShare / 100
        case .audioOnly, .subtitle: v = s * 95 / 100
        case .video: v = audioShare + s * (remuxStart - audioShare) / 100
        }
        return min(max(v, 0), 99)
    }

    /// „1,5 MB“, „12 KB“, „300 B“ (Android rechnet mit Punkt als Dezimaltrenner und 1024er-Schritten).
    public static func humanBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0)) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }

    public static func describe(_ p: DownloadProgress) -> String {
        let total = p.totalBytes.map { " von \(humanBytes($0))" } ?? ""
        let speed = p.bytesPerSecond > 0 ? " · \(humanBytes(p.bytesPerSecond))/s" : ""
        return "\(humanBytes(p.downloadedBytes))\(total)\(speed)"
    }

    /// Dateiname: nur Buchstaben, Ziffern, Leerzeichen, `-`, `_` bleiben; höchstens 80 Zeichen; leer → „GuevenTube“.
    public static func fileName(_ title: String, extension ext: String) -> String {
        let mapped = String(decoding: title.utf16.map { unit -> UInt16 in
            if let s = Unicode.Scalar(unit), keep(s) { return unit }
            return 0x5F
        }, as: UTF16.self)
        let safe = String(mapped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return "\(safe.isEmpty ? "GuevenTube" : safe).\(ext)"
    }
    private static func keep(_ s: Unicode.Scalar) -> Bool {
        if s == " " || s == "-" || s == "_" { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    /// Untertitel-URL im VTT-Format: `fmt` ersetzen und ans Ende stellen, übrige Parameter bleiben in Reihenfolge.
    public static func withVttFormat(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var items = (c.queryItems ?? []).filter { $0.name != "fmt" }
        items.append(URLQueryItem(name: "fmt", value: "vtt"))
        c.queryItems = items
        return c.string ?? url
    }

    /// Verständlicher Text statt der rohen Systemmeldung.
    public static func friendlyError(_ error: Error) -> String {
        if let e = error as? PlaybackUnavailableError { return e.description.isEmpty ? "Video nicht abspielbar." : e.description }
        if let e = error as? DownloadHttpError { return "Server antwortet nicht (HTTP \(e.code))." }
        if let e = error as? URLError {
            switch e.code {
            case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .networkConnectionLost: return "Keine Internetverbindung."
            case .timedOut: return "Zeitüberschreitung, bitte erneut versuchen."
            default: break
            }
        }
        let text = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        return text.isEmpty ? String(describing: type(of: error)) : text
    }
}
