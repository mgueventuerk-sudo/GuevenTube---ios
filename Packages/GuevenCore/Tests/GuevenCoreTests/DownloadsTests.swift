import XCTest
@testable import GuevenCore

final class FakeScheduler: DownloadScheduling, @unchecked Sendable {
    private let lock = NSLock(); private var ids: [Int64] = []
    var scheduled: [Int64] { lock.withLock { ids } }
    func schedule(downloadId: Int64) async { lock.withLock { ids.append(downloadId) } }
}

final class DownloadsTests: XCTestCase {
    private func fmt(_ itag: Int, _ mime: String, h: Int? = nil, br: Int64 = 100) -> StreamFormat {
        StreamFormat(itag: itag, url: "https://x/\(itag)", signatureCipher: nil, mimeType: mime, bitrate: br, averageBitrate: nil, width: nil, height: h, fps: nil,
                     qualityLabel: h.map { "\($0)p" }, initRange: nil, indexRange: nil, contentLength: nil, approxDurationMs: nil, audioSampleRate: nil,
                     audioChannels: nil, audioTrackId: nil, audioTrackName: nil, audioIsDefault: false, isDrc: false, colorPrimaries: nil,
                     colorTransfer: nil, colorMatrix: nil, isOtf: false, lastModified: nil, xtags: nil)
    }
    private func v(_ itag: Int, _ h: Int) -> StreamFormat { fmt(itag, "video/mp4; codecs=\"avc1.640028\"", h: h) }
    private func a(_ itag: Int, _ br: Int64) -> StreamFormat { fmt(itag, "audio/mp4; codecs=\"mp4a.40.2\"", br: br) }
    private func playback(_ f: [StreamFormat]) -> ResolvedPlayback {
        let d = PlayerData(playability: Playability(status: "OK", reason: nil), details: nil, adaptiveFormats: f, muxedFormats: [], hlsManifestUrl: nil, expiresInSeconds: nil,
                           captions: [], loudnessDb: nil, storyboardSpec: nil, serverAbrStreamingUrl: nil, ustreamerConfig: nil)
        return ResolvedPlayback(videoId: "v", playerData: d, adaptiveFormats: f, muxedFormats: [], resolvedAtMs: 0, expiresAtMs: 1, clientLabel: "t", userAgent: "ua", attempts: [])
    }
    private func record(kind: DownloadKind = .video, quality: String? = nil, vi: Int? = nil, ai: Int? = nil) -> DownloadRecord {
        DownloadRecord(id: 1, videoId: "v", title: "T", kind: kind, qualityLabel: "Q", status: .queued, requestedQuality: quality, videoItag: vi, audioItag: ai, createdAt: 0, updatedAt: 0)
    }

    // MARK: Format-Wahl

    func testResolveByQualityNameWithUnknownFallingBackToHd() {
        let p = playback([v(1, 360), v(2, 720), v(3, 1080), a(9, 128)])
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(quality: "FULL_HD"))?.videoFormat?.itag, 3)
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(quality: "GIBT_ES_NICHT"))?.videoFormat?.itag, 2)
        XCTAssertNil(DownloadPlanner.resolveFormats(p, record(quality: "AUDIO_ONLY"))?.videoFormat)
    }

    func testResolveExplicitItagsAndFallbacks() {
        let p = playback([v(1, 360), v(2, 720), v(3, 1080), a(8, 64), a(9, 128), fmt(5, "video/webm; codecs=\"vp9\"", h: 1440)])
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 2, ai: 8))?.videoFormat?.itag, 2)
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 2, ai: 8))?.audioFormat.itag, 8)
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 2, ai: 77))?.audioFormat.itag, 9, "Ton-Itag weg: beste Tonspur")
        // VP9 gewählt (nicht H.264): nächstniedrigere H.264-Höhe
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 5, ai: 9))?.videoFormat?.itag, 3)
        // Itag unbekannt: ohne Höhe → höchste vorhandene? Kotlin: lastOrNull{height <= MAX} = höchste
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 99, ai: 9))?.videoFormat?.itag, 3)
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(kind: .audio, ai: 8))?.audioFormat.itag, 8)
        XCTAssertNil(DownloadPlanner.resolveFormats(p, record(kind: .audio, ai: 8))?.videoFormat)
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(kind: .audio, ai: 8))?.qualityLabel, "Q")
        XCTAssertNil(DownloadPlanner.resolveFormats(playback([a(9, 128)]), record(vi: 1, ai: 9)), "kein H.264-Bild")
        XCTAssertNil(DownloadPlanner.resolveFormats(playback([v(1, 360)]), record(vi: 1, ai: 9)), "keine Tonspur")
    }

    func testFormatsWithoutUrlAreIgnored() {
        var noUrl = a(8, 999); noUrl.url = "  "
        let p = playback([v(1, 360), noUrl, a(9, 10)])
        XCTAssertEqual(DownloadPlanner.resolveFormats(p, record(vi: 1, ai: 8))?.audioFormat.itag, 9)
    }

    // MARK: Fortschritt, Texte, Namen

    func testPercentMapping() {
        let half = DownloadProgress(downloadedBytes: 50, totalBytes: 100, bytesPerSecond: 0)
        XCTAssertEqual(DownloadPlanner.stagePercent(half), 50)
        XCTAssertEqual(DownloadPlanner.overallPercent(.audioWithVideo, half), 22)
        XCTAssertEqual(DownloadPlanner.overallPercent(.video, half), 45 + 50 * 45 / 100)
        XCTAssertEqual(DownloadPlanner.overallPercent(.audioOnly, half), 47)
        let full = DownloadProgress(downloadedBytes: 100, totalBytes: 100, bytesPerSecond: 0)
        XCTAssertEqual(DownloadPlanner.overallPercent(.video, full), 90); XCTAssertEqual(DownloadPlanner.overallPercent(.audioOnly, full), 95)
        XCTAssertEqual(DownloadPlanner.stagePercent(DownloadProgress(downloadedBytes: 500, totalBytes: 100, bytesPerSecond: 0)), 100)
        XCTAssertEqual(DownloadPlanner.stagePercent(DownloadProgress(downloadedBytes: 5, totalBytes: nil, bytesPerSecond: 0)), 0)
        XCTAssertEqual(DownloadPlanner.stagePercent(DownloadProgress(downloadedBytes: 5, totalBytes: 0, bytesPerSecond: 0)), 0)
    }

    func testHumanBytesAndDescribe() {
        XCTAssertEqual(DownloadPlanner.humanBytes(999), "999 B"); XCTAssertEqual(DownloadPlanner.humanBytes(2048), "2 KB")
        XCTAssertEqual(DownloadPlanner.humanBytes(1024 * 1024 * 3 / 2), "1.5 MB")
        XCTAssertEqual(DownloadPlanner.describe(DownloadProgress(downloadedBytes: 1024, totalBytes: 2048, bytesPerSecond: 512)), "1 KB von 2 KB · 512 B/s")
        XCTAssertEqual(DownloadPlanner.describe(DownloadProgress(downloadedBytes: 10, totalBytes: nil, bytesPerSecond: 0)), "10 B")
    }

    func testFileNames() {
        XCTAssertEqual(DownloadPlanner.fileName("A/B:C*D?", extension: "mp4"), "A_B_C_D_.mp4")
        XCTAssertEqual(DownloadPlanner.fileName("Äpfel – Öl 5-x_y", extension: "m4a"), "Äpfel _ Öl 5-x_y.m4a")
        XCTAssertEqual(DownloadPlanner.fileName("   ", extension: "vtt"), "GuevenTube.vtt")
        XCTAssertEqual(DownloadPlanner.fileName(String(repeating: "a", count: 200), extension: "mp4").count, 84)
        XCTAssertEqual(DownloadPlanner.fileName("  x  ", extension: "mp4"), "x.mp4")
        XCTAssertEqual(DownloadPlanner.fileName("🎵", extension: "mp4"), "__.mp4", "Ersatzzeichen einzeln wie bei Android")
        XCTAssertEqual(DownloadPlanner.fileName("../../etc", extension: "mp4"), "______etc.mp4", "kein Pfad aus dem Titel")
    }

    func testVttUrl() {
        XCTAssertEqual(DownloadPlanner.withVttFormat("https://x/t?a=1&fmt=srv3&b=2"), "https://x/t?a=1&b=2&fmt=vtt")
        XCTAssertEqual(DownloadPlanner.withVttFormat("https://x/t"), "https://x/t?fmt=vtt")
    }

    func testFriendlyErrors() {
        XCTAssertEqual(DownloadPlanner.friendlyError(DownloadHttpError(code: 403)), "Server antwortet nicht (HTTP 403).")
        XCTAssertEqual(DownloadPlanner.friendlyError(URLError(.notConnectedToInternet)), "Keine Internetverbindung.")
        XCTAssertEqual(DownloadPlanner.friendlyError(URLError(.timedOut)), "Zeitüberschreitung, bitte erneut versuchen.")
        XCTAssertEqual(DownloadPlanner.friendlyError(PlaybackUnavailableError(status: "X", message: "Video privat")), "Video privat")
        XCTAssertEqual(DownloadPlanner.friendlyError(PlaybackUnavailableError(status: "X", message: "")), "Video nicht abspielbar.")
        struct Eigen: Error, CustomStringConvertible { var description: String { "Eigene Meldung" } }
        XCTAssertEqual(DownloadPlanner.friendlyError(Eigen()), "Eigene Meldung")
    }

    // MARK: Speicher und Repository

    func testStoreOperations() async {
        let s = DownloadStore()
        let r = { (t: Int64) in DownloadRecord(id: 0, videoId: "v\(t)", title: "T", kind: .video, qualityLabel: "Q", status: .queued, createdAt: t, updatedAt: t) }
        let a = await s.insert(r(10)), b = await s.insert(r(20)), c = await s.insert(r(30))
        XCTAssertEqual([a, b, c], [1, 2, 3])
        let all = await s.all(); XCTAssertEqual(all.map(\.id), [3, 2, 1])
        await s.setStatus(a, .running, now: 99)
        await s.setProgress(b, percent: 40, downloadedBytes: 4, totalBytes: 10, bytesPerSecond: 2, stage: "Ton wird geladen", now: 50)
        await s.setDone(c, location: "x.mp4", bytes: 1234, now: 60)
        let pend = await s.pending(); XCTAssertEqual(pend.map(\.id), [1, 2])
        let gb = await s.get(b); XCTAssertEqual(gb?.progressPercent, 40); XCTAssertEqual(gb?.stage, "Ton wird geladen")
        let gc = await s.get(c); XCTAssertEqual(gc?.status, .done); XCTAssertEqual(gc?.progressPercent, 100); XCTAssertEqual(gc?.fileSizeBytes, 1234)
        await s.setFailed(a, message: "Mist", now: 70)
        let ga = await s.get(a); XCTAssertEqual(ga?.status, .failed); XCTAssertEqual(ga?.errorMessage, "Mist")
        await s.delete(b); let after = await s.all(); XCTAssertEqual(after.count, 2)
        await s.setStatus(999, .done, now: 1)   // unbekannte ID: kein Absturz
        let d = await s.insert(r(5)); XCTAssertEqual(d, 4, "IDs werden nicht wiederverwendet")
    }

    func testStorePersistsAndToleratesCorruption() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("d.json")
        let s = DownloadStore(file: f)
        await s.insert(DownloadRecord(id: 0, videoId: "v", title: "T", kind: .audio, qualityLabel: "Nur Ton", status: .queued, createdAt: 1, updatedAt: 1))
        let again = await DownloadStore(file: f).all(); XCTAssertEqual(again.first?.kind, .audio)
        try Data("{kaputt".utf8).write(to: f)
        let empty = await DownloadStore(file: f).all(); XCTAssertTrue(empty.isEmpty)
    }

    func testRepositoryEnqueueRetryDeleteResume() async {
        let store = DownloadStore(), sched = FakeScheduler()
        final class Removed: @unchecked Sendable { var paths: [String] = [] }
        let removed = Removed()
        let repo = DownloadRepository(store: store, scheduler: sched, removeFile: { removed.paths.append($0) }, nowMs: { 1000 })
        let items = [DownloadRequestItem(videoId: "a", title: "A"), DownloadRequestItem(videoId: "b", title: "B", channelName: "C")]
        await repo.enqueue(items, quality: .audioOnly, threadCount: 2)
        await repo.enqueue([items[0]], quality: .fullHd)
        await repo.enqueueExplicit(items[1], kind: .subtitle, qualityLabel: "de", videoItag: nil, audioItag: nil, subtitleLanguageCode: "de", threadCount: 1, fileName: "B-de")
        XCTAssertEqual(sched.scheduled, [1, 2, 3, 4])
        let all = await store.all().sorted { $0.id < $1.id }
        XCTAssertEqual(all.map(\.kind), [.audio, .audio, .video, .subtitle])
        XCTAssertEqual(all[0].requestedQuality, "AUDIO_ONLY"); XCTAssertEqual(all[0].threadCount, 2); XCTAssertEqual(all[2].requestedQuality, "FULL_HD")
        XCTAssertNil(all[3].requestedQuality); XCTAssertEqual(all[3].subtitleLanguageCode, "de"); XCTAssertEqual(all[3].fileName, "B-de")
        XCTAssertTrue(all.allSatisfy { $0.status == .queued && $0.createdAt == 1000 })

        await store.setFailed(1, message: "x", now: 5)
        await repo.retry(all[0]); XCTAssertEqual(sched.scheduled.last, 1)
        let r1 = await store.get(1); XCTAssertEqual(r1?.status, .queued)

        await store.setDone(2, location: "B.m4a", bytes: 1, now: 6)
        let done = await store.get(2)!
        await repo.delete(done); XCTAssertEqual(removed.paths, ["B.m4a"])
        let gone = await store.get(2); XCTAssertNil(gone)
        let queued = await store.get(1)!; await repo.delete(queued); XCTAssertEqual(removed.paths.count, 1, "ohne Datei keine Löschung")

        let before = sched.scheduled.count
        await repo.resumePending(); XCTAssertEqual(Array(sched.scheduled.dropFirst(before)), [3, 4])
    }

    func testUpdatesStream() async {
        let s = DownloadStore()
        let stream = await s.updates(); var it = stream.makeAsyncIterator()
        await s.insert(DownloadRecord(id: 0, videoId: "v", title: "T", kind: .video, qualityLabel: "Q", status: .queued, createdAt: 1, updatedAt: 1))
        let v: Void? = await it.next(); XCTAssertNotNil(v)
    }
}
