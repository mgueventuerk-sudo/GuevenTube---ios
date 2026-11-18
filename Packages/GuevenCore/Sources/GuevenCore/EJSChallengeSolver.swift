import Foundation

// Entschlüssler: Port von `SandboxChallengeSolver.kt`. Die Logik (Zwischenspeicher, Anfrage/Antwort, Neustart bei
// Fehlern, Platten-Ablage der analysierten Player-Datei) ist plattformunabhängig und läuft hier mit einer
// Fake-Engine unter Linux. Die echte Engine (JavaScriptCore) ist `JavaScriptCoreEngine` (nur Apple).

/// Eine isolierte JavaScript-Umgebung. Jede Umgebung gehört genau einem Solver und wird nacheinander benutzt.
public protocol JSEngine: AnyObject, Sendable {
    /// Setzt eine globale Zeichenketten-Variable (große Player-Skripte gehen so ohne Literal-Maskierung hinein).
    func setGlobal(_ name: String, string: String) async throws
    /// Führt Code aus und liefert das Ergebnis als Zeichenkette. Nach Zeitüberschreitung ist die Engine zu
    /// verwerfen (`JSEngineError.timeout`).
    func evaluate(_ code: String, timeoutMs: Int64) async throws -> String
    func close()
}

public enum JSEngineError: Error, Equatable {
    case timeout
    case failed(String)
}

public typealias JSEngineFactory = @Sendable () throws -> JSEngine

/// Der Entschlüssler von yt-dlp (EJS) hinter [JSEngine]. Die beiden Quelltexte (`yt.solver.lib.min.js`,
/// `yt.solver.core.min.js`) liegen im App-Bündel und sind bitgleich mit Android.
public actor EJSChallengeSolver: ChallengeSolving {
    public static let ejsVersion = "0.8.0"
    static let cacheSize = 512
    static let loadTimeoutMs: Int64 = 60_000
    static let solveTimeoutMs: Int64 = 15_000
    static let keepPreprocessedFiles = 2

    private let makeEngine: JSEngineFactory
    private let libSource: @Sendable () throws -> String
    private let coreSource: @Sendable () throws -> String
    private let playerScript: @Sendable (String) async throws -> String
    private let directory: URL?
    private let clock: @Sendable () -> Int64

    private var engine: JSEngine?
    private var loadedPlayerId: String?
    private var lastError: String?
    private var lastLoadMs: Int64?
    private var cache = SolutionCache(capacity: EJSChallengeSolver.cacheSize)
    private var cacheRestored = false
    private var running = false

    /// - Parameters:
    ///   - directory: Ablage für Lösungen und die analysierte Player-Datei; `nil` = nur Speicher.
    ///   - playerScript: liefert `base.js` zu einer Player-ID (iOS: `PlayerScriptRepository.script`).
    public init(
        directory: URL?,
        makeEngine: @escaping JSEngineFactory,
        libSource: @escaping @Sendable () throws -> String,
        coreSource: @escaping @Sendable () throws -> String,
        playerScript: @escaping @Sendable (String) async throws -> String,
        clock: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    ) {
        self.directory = directory
        self.makeEngine = makeEngine
        self.libSource = libSource
        self.coreSource = coreSource
        self.playerScript = playerScript
        self.clock = clock
    }

    public func isAvailable() async -> Bool { true }

    public func status() async -> String {
        if let lastError { return "Fehler: \(lastError)" }
        if let loadedPlayerId { return "bereit (Player \(loadedPlayerId), Analyse \(lastLoadMs ?? 0) ms)" }
        return "verfügbar (EJS \(Self.ejsVersion))"
    }

    public func solve(playerId: String, nChallenges: Set<String>, sigChallenges: Set<String>) async throws -> SolvedChallenges {
        try await exclusive { [self] in
            try await solveLocked(playerId: playerId, nChallenges: nChallenges, sigChallenges: sigChallenges)
        }
    }

    /// Analysiert das Player-Skript vorab, damit der erste Abspielweg nicht wartet. Fehler werden verschluckt.
    public func warmUp(playerId: String) async {
        _ = try? await exclusive { [self] in
            restoreCache(playerId)
            do { _ = try await ensurePlayerLoaded(playerId) } catch { resetEngine("Vorwärmen: \(error)") }
        }
    }

    public func release() async { resetEngine(nil) }

    // MARK: Ablauf

    /// Eine Lösung zur Zeit (wie der Mutex in Android). Aufrufer reihen sich ein.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        if running { await withCheckedContinuation { waiters.append($0) } }
        running = true
        defer {
            if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    private func solveLocked(playerId: String, nChallenges: Set<String>, sigChallenges: Set<String>) async throws -> SolvedChallenges {
        restoreCache(playerId)
        var nResult: [String: String] = [:]
        var sigResult: [String: String] = [:]
        let openN = nChallenges.sorted().filter { c in
            if let v = cache.get("\(playerId):n:\(c)") { nResult[c] = v; return false }
            return true
        }
        let openSig = sigChallenges.sorted().filter { c in
            if let v = cache.get("\(playerId):s:\(c)") { sigResult[c] = v; return false }
            return true
        }
        if openN.isEmpty && openSig.isEmpty { return SolvedChallenges(n: nResult, sig: sigResult) }

        do {
            let target = try await ensurePlayerLoaded(playerId)
            let code = SolverWire.solveCode(openN: openN, openSig: openSig)
            let raw = try await target.evaluate(code, timeoutMs: Self.solveTimeoutMs)
            let parsed = try SolverWire.parse(raw, openN: openN, openSig: openSig)
            for (c, v) in parsed.n { nResult[c] = v; cache.set("\(playerId):n:\(c)", v) }
            for (c, v) in parsed.sig { sigResult[c] = v; cache.set("\(playerId):s:\(c)", v) }
            persistCache()
            lastError = nil
            return SolvedChallenges(n: nResult, sig: sigResult)
        } catch is CancellationError {
            throw CancellationError()
        } catch JSEngineError.timeout {
            resetEngine("Zeitlimit überschritten")
            throw SolverError("Zeitlimit des Entschlüsslers überschritten")
        } catch let error as SolverError {
            lastError = error.message
            throw error
        } catch {
            resetEngine("\(type(of: error))")
            throw SolverError("Entschlüssler-Fehler (\(type(of: error)))")
        }
    }

    /// Engine anlegen, Bibliotheken laden, Player einmal analysieren (oder die gespeicherte Analyse laden).
    private func ensurePlayerLoaded(_ playerId: String) async throws -> JSEngine {
        if let engine, loadedPlayerId == playerId { return engine }
        if engine != nil { resetEngine(nil) }
        let created = try makeEngine()
        engine = created
        let started = clock()
        do {
            _ = try await created.evaluate(try libSource() + "\nObject.assign(globalThis, lib);'ok'", timeoutMs: Self.loadTimeoutMs)
            _ = try await created.evaluate(try coreSource() + "\n'ok'", timeoutMs: Self.loadTimeoutMs)
            _ = try await created.evaluate(SolverWire.loaderJS, timeoutMs: Self.loadTimeoutMs)

            if let stored = readPreprocessed(playerId) {
                try await created.setGlobal("__gtPlayer", string: stored)
            } else {
                let source = try await playerScript(playerId)
                try await created.setGlobal("__gtPlayerSource", string: source)
                let result = try await created.evaluate("__gtLoad(__gtPlayerSource)", timeoutMs: Self.loadTimeoutMs)
                if result != "ok" { throw SolverError("Player-Analyse: \(result.prefix(120))") }
                _ = try await created.evaluate("globalThis.__gtPlayerSource=undefined;'ok'", timeoutMs: Self.loadTimeoutMs)
                if let analysed = try? await created.evaluate("globalThis.__gtPlayer", timeoutMs: Self.loadTimeoutMs), !analysed.isEmpty {
                    writePreprocessed(playerId, analysed)
                }
            }
        } catch {
            resetEngine(nil)
            throw error
        }
        lastLoadMs = clock() - started
        loadedPlayerId = playerId
        return created
    }

    private func resetEngine(_ reason: String?) {
        if let reason { lastError = reason }
        engine?.close()
        engine = nil
        loadedPlayerId = nil
    }

    // MARK: Ablage

    private var cacheFile: URL? { directory?.appendingPathComponent("solutions.tsv") }

    private func restoreCache(_ playerId: String) {
        if cacheRestored { return }
        cacheRestored = true
        guard let cacheFile, let text = try? String(contentsOf: cacheFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(Self.cacheSize) {
            guard let tab = line.firstIndex(of: "\t"), tab != line.startIndex else { continue }
            let key = String(line[..<tab])
            if key.hasPrefix("\(playerId):") { cache.set(key, String(line[line.index(after: tab)...])) }
        }
        cache.clearDirty()
    }

    private func persistCache() {
        guard cache.dirty, let directory, let cacheFile else { return }
        cache.clearDirty()
        let text = cache.entries.compactMap { key, value -> String? in
            // Tab/Zeilenumbruch würden das Format zerstören – solche Einträge nicht ablegen.
            if key.contains(where: { $0 == "\t" || $0 == "\n" }) || value.contains(where: { $0 == "\t" || $0 == "\n" }) { return nil }
            return "\(key)\t\(value)\n"
        }.joined()
        Self.writeAtomically(Data(text.utf8), to: cacheFile, in: directory)
    }

    static func safeId(_ playerId: String) -> Bool {
        !playerId.isEmpty && playerId.count <= 32 && playerId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func preprocessedFile(_ playerId: String) -> URL? {
        guard let directory, Self.safeId(playerId) else { return nil }
        return directory.appendingPathComponent("preprocessed-\(playerId).js")
    }

    private func readPreprocessed(_ playerId: String) -> String? {
        guard let file = preprocessedFile(playerId), let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private func writePreprocessed(_ playerId: String, _ text: String) {
        guard let directory, let file = preprocessedFile(playerId) else { return }
        Self.writeAtomically(Data(text.utf8), to: file, in: directory)
        pruneOldPreprocessed(keeping: file)
    }

    /// Nur die neuesten Dateien behalten (je Datei mehrere MB).
    private func pruneOldPreprocessed(keeping current: URL) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = names.filter { $0.lastPathComponent.hasPrefix("preprocessed-") && $0.pathExtension == "js" }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let sorted = dated.sorted { $0.1 > $1.1 }
        for (file, _) in sorted.dropFirst(Self.keepPreprocessedFiles) where file != current {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func writeAtomically(_ data: Data, to file: URL, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(file.lastPathComponent + ".tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: temp, to: file)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}

// MARK: Anfrage und Antwort (identisch zu Android)

enum SolverWire {
    /// Hilfsfunktionen in der Engine: Laden/Analysieren des Player-Skripts.
    static let loaderJS = """
    globalThis.__gtLoad = function (player) {
      var result = jsc({type: 'player', player: player, output_preprocessed: true, requests: []});
      if (result.type === 'error') return 'ERR:' + result.error;
      globalThis.__gtPlayer = result.preprocessed_player;
      return 'ok';
    };
    'ok'
    """

    static func solveCode(openN: [String], openSig: [String]) -> String {
        var requests: [String] = []
        if !openN.isEmpty { requests.append(request("n", openN)) }
        if !openSig.isEmpty { requests.append(request("sig", openSig)) }
        return "JSON.stringify(jsc({type:'preprocessed',preprocessed_player:globalThis.__gtPlayer,requests:[\(requests.joined(separator: ","))]}))"
    }

    private static func request(_ type: String, _ challenges: [String]) -> String {
        "{\"type\":\"\(type)\",\"challenges\":\(jsonArray(challenges))}"
    }

    /// JSON-Zeichenkettenliste. `JSONSerialization` maskiert `/` als `\/` (gültig); U+2028/2029 sind in
    /// JSON erlaubt, in älteren JS-Parsern nicht – deshalb zusätzlich maskieren.
    static func jsonArray(_ items: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    struct Parsed { var n: [String: String] = [:]; var sig: [String: String] = [:] }

    static func parse(_ raw: String, openN: [String], openSig: [String]) throws -> Parsed {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw SolverError("Antwort nicht lesbar")
        }
        if object["type"] as? String == "error" {
            throw SolverError("Entschlüssler: \(String((object["error"] as? String ?? "").prefix(120)))")
        }
        guard let responses = object["responses"] as? [[String: Any]] else { throw SolverError("Antwort ohne responses") }
        var parsed = Parsed()
        var index = 0
        if !openN.isEmpty {
            guard index < responses.count else { throw SolverError("Antwort unvollständig (n)") }
            parsed.n = try collect(responses[index], kind: "n"); index += 1
        }
        if !openSig.isEmpty {
            guard index < responses.count else { throw SolverError("Antwort unvollständig (sig)") }
            parsed.sig = try collect(responses[index], kind: "s")
        }
        return parsed
    }

    private static func collect(_ response: [String: Any], kind: String) throws -> [String: String] {
        guard response["type"] as? String == "result" else {
            throw SolverError("Herausforderung (\(kind)) nicht lösbar: \(String((response["error"] as? String ?? "").prefix(120)))")
        }
        var out: [String: String] = [:]
        for (challenge, value) in (response["data"] as? [String: Any]) ?? [:] {
            if let solved = value as? String { out[challenge] = solved }
        }
        return out
    }
}

/// LRU-Zwischenspeicher (Zugriff ordnet um), Einfügereihenfolge = Alter.
struct SolutionCache {
    private(set) var entries: [(String, String)] = []
    private(set) var dirty = false
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: String) -> String? {
        guard let i = entries.firstIndex(where: { $0.0 == key }) else { return nil }
        let entry = entries.remove(at: i)
        entries.append(entry)
        return entry.1
    }

    mutating func set(_ key: String, _ value: String) {
        if let i = entries.firstIndex(where: { $0.0 == key }) { entries.remove(at: i) }
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        dirty = true
    }

    mutating func clearDirty() { dirty = false }
}
