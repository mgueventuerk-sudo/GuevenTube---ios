import Foundation

// MARK: Abhängigkeiten (Protokolle, damit die Auflösung ohne Netz und ohne JavaScript testbar ist)

/// `/player`-Zugriff und Konto-/Besucherzustand des InnerTube-Dienstes.
public protocol PlayerEndpoint: Sendable {
    func player(videoId: String, signatureTimestamp: Int?, poToken: String?, profile: PlayerClientProfile, useAccount: Bool) async throws -> JSON
    func hasAccount() async -> Bool
    func currentVisitorData() async -> String?
    func resetVisitorData() async throws
}

extension InnerTubeService: PlayerEndpoint {}

public protocol ClientProfileProviding: Sendable {
    func profiles() async -> [PlayerClientProfile]
}

/// Ergebnis des Entschlüsslers: `n`-Parameter und Signaturen, jeweils Original → gelöst.
public struct SolvedChallenges: Equatable, Sendable {
    public var n: [String: String]
    public var sig: [String: String]
    public init(n: [String: String] = [:], sig: [String: String] = [:]) { self.n = n; self.sig = sig }
}

/// Löst `n`- und Signatur-Herausforderungen des Player-Skripts (iOS: JavaScriptCore).
public protocol ChallengeSolving: Sendable {
    func isAvailable() async -> Bool
    func status() async -> String
    func solve(playerId: String, nChallenges: Set<String>, sigChallenges: Set<String>) async throws -> SolvedChallenges
    /// Analysiert das Player-Skript vorab (Standard: nichts tun).
    func warmUp(playerId: String) async
}

public extension ChallengeSolving {
    func warmUp(playerId: String) async {}
}

public struct SolverError: Error { public let message: String; public init(_ m: String) { message = m } }

/// Player-Skript: aktuelle ID und `signatureTimestamp`.
public protocol PlayerScriptProviding: Sendable {
    func currentPlayerId() async throws -> String
    func signatureTimestamp(playerId: String) async throws -> Int?
    func clear() async
}

/// poTokens einer Wiedergabe: [player] gehört zur Video-ID (`/player`), [streaming] zur visitorData (`pot` an
/// Stream-URLs). Bei einem eingetragenen Token sind beide gleich.
public struct PoTokens: Sendable, CustomStringConvertible {
    public var player: String
    public var streaming: String
    public var generated: Bool
    public init(player: String, streaming: String, generated: Bool) { self.player = player; self.streaming = streaming; self.generated = generated }
    public var description: String { "PoTokens(generated=\(generated))" } // nie den Inhalt ausgeben
    /// `false` bei „nur Streaming-Token“: `/player` läuft dann ohne Token, Wege mit Token-Pflicht bleiben aus.
    public var hasPlayerToken: Bool { !player.trimmingCharacters(in: .whitespaces).isEmpty }
}

public protocol PoTokenProviding: Sendable {
    func tokens(videoId: String, visitorData: String?, generate: Bool) async -> PoTokens?
    /// Nur der an die visitorData gebundene Token für Stream-URLs (`pot`). Er ist pro Besucher-Kennung zwischenspeicherbar,
    /// der Video-Token nicht: So wartet nicht jede Wiedergabe auf ein BotGuard-Prägen.
    func streamingTokens(visitorData: String?) async -> PoTokens?
}

public extension PoTokenProviding {
    func streamingTokens(visitorData: String?) async -> PoTokens? {
        await tokens(videoId: "", visitorData: visitorData, generate: true).map { PoTokens(player: "", streaming: $0.streaming, generated: $0.generated) }
    }
}

public struct NoPoTokens: PoTokenProviding {
    public init() {}
    public func tokens(videoId: String, visitorData: String?, generate: Bool) async -> PoTokens? { nil }
}

/// Zeitbudgets der Auflösung.
public struct ResolverTimings: Sendable {
    /// Je Abspielweg.
    public var routeTimeoutMs: Int64 = 12_000
    /// Kalt: Wege mit Player-Skript teilen sich Sperren; ein kalter Start auf schwachen Geräten braucht die Zeit.
    public var totalTimeoutMs: Int64 = 30_000
    /// Warm (Skript/Solver geladen): Fehlermeldung spätestens nach 15 s.
    public var warmTotalTimeoutMs: Int64 = 15_000
    /// Antwortet ein Weg so lange nicht, startet der nächste parallel.
    public var hedgeDelayMs: Int64 = 3_000
    /// Mindestzeit für den zweiten Durchlauf mit erzeugtem poToken.
    public var minRetryMs: Int64 = 4_000
    public var minSecondPassMs: Int64 = 2_000
    public init() {}
}

/// Abspielbereite Daten: alle Stream-URLs sind entschlüsselt und enthalten ggf. den poToken.
public struct ResolvedPlayback: Equatable, Sendable {
    public var videoId: String
    public var playerData: PlayerData
    public var adaptiveFormats: [StreamFormat]
    public var muxedFormats: [StreamFormat]
    public var resolvedAtMs: Int64
    public var expiresAtMs: Int64
    /// Anzeigename des Abspielwegs, der funktioniert hat.
    public var clientLabel: String
    /// User-Agent dieses Abspielwegs; googlevideo erwartet für die Streams denselben.
    public var userAgent: String
    public var attempts: [ClientAttempt]
    /// Kurzbeschreibung für Protokoll und Wiedergabe-Test, z. B. „39 Formate, ohne Player-Skript".
    public var summary: String = ""
    /// `n`-Parameter nicht entschlüsselt: googlevideo drosselt oder sperrt. Nur als letzter Ausweg.
    public var throttlingUnsolved = false

    static let expirySafetyMs: Int64 = 5 * 60 * 1000
    public func isExpired(nowMs: Int64) -> Bool { nowMs >= expiresAtMs - Self.expirySafetyMs }
}

struct DecipherError: Error { let message: String }

/// Kleiner LRU-Speicher (Zugriff nur aus dem Resolver-Actor).
struct LRUCache<V> {
    private let capacity: Int
    private var order: [String] = []
    private var values: [String: V] = [:]
    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: String) -> V? {
        guard let v = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return v
    }
    mutating func put(_ key: String, _ value: V) {
        order.removeAll { $0 == key }; order.append(key)
        values[key] = value
        while order.count > capacity { values[order.removeFirst()] = nil }
    }
    mutating func remove(_ key: String) { order.removeAll { $0 == key }; values[key] = nil }
    mutating func removeAll() { order.removeAll(); values.removeAll() }
}

/// Löst eine Video-ID in abspielbare Streams auf. Nacheinander (zeitversetzt parallel) werden alle Abspielwege
/// probiert, bis einer abspielbare Streams liefert:
/// 1. `signatureTimestamp` des Player-Skripts (nur für Wege, die es brauchen)
/// 2. `/player` im Kontext des Profils
/// 3. pro Format: Signatur-Cipher entschlüsseln, `n`-Parameter transformieren, `pot` anhängen
///
/// Jeder Versuch wird protokolliert ([ClientAttempt]); scheitern alle, enthält der Fehler das Protokoll.
/// Ergebnisse werden bis kurz vor Ablauf der Stream-URLs im Speicher gehalten. (SABR ist ein Labor-Weg der
/// Android-App und noch nicht portiert: „nur SABR"-Antworten gelten hier als Fehlschlag mit Art `sabrOnly`.)
public actor StreamResolver {
    static let cacheSize = 16
    static let noScriptMark = "ohne Player-Skript"
    static let defaultExpirySeconds: Int64 = 6 * 60 * 60

    private let endpoint: PlayerEndpoint
    private let registry: ClientProfileProviding
    private let solver: ChallengeSolving
    private let scripts: PlayerScriptProviding
    private let poTokens: PoTokenProviding
    private let health: RouteHealth
    private let timings: ResolverTimings
    private let nowMs: @Sendable () -> Int64
    private let sleepMs: @Sendable (Int64) async throws -> Void
    private let autoPoToken: Bool
    private let alwaysPoToken: Bool

    private var cache = LRUCache<ResolvedPlayback>(capacity: StreamResolver.cacheSize)
    private var rejectedRoutes = LRUCache<Set<String>>(capacity: StreamResolver.cacheSize)
    private var inFlight: [String: Task<ResolvedPlayback, Error>] = [:]
    private var inFlightToken: [String: Int] = [:]
    private var nextToken = 0
    private var poTokenDemand = false
    private var warm = false

    /// Zuletzt angefragtes Video – der Wiedergabe-Test prüft bevorzugt genau dieses.
    public private(set) var lastRequestedVideoId: String?

    public init(endpoint: PlayerEndpoint, registry: ClientProfileProviding, solver: ChallengeSolving, scripts: PlayerScriptProviding,
                poTokens: PoTokenProviding = NoPoTokens(), health: RouteHealth, timings: ResolverTimings = ResolverTimings(),
                autoPoToken: Bool = false, alwaysPoToken: Bool = false,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleepMs: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }) {
        self.endpoint = endpoint; self.registry = registry; self.solver = solver; self.scripts = scripts
        self.poTokens = poTokens; self.health = health; self.timings = timings; self.autoPoToken = autoPoToken; self.alwaysPoToken = alwaysPoToken
        self.nowMs = nowMs; self.sleepMs = sleepMs
    }

    // MARK: Öffentliche API

    public func resolve(_ videoId: String, forceRefresh: Bool = false, trackAsLastRequested: Bool = true) async throws -> ResolvedPlayback {
        if trackAsLastRequested { lastRequestedVideoId = videoId }
        return try await resolveShared(videoId, forceRefresh: forceRefresh)
    }

    /// Beim App-Start: Player-Skript laden und analysieren. Die Analyse ist auf dem iPhone langsam (JavaScriptCore ohne JIT)
    /// und fiel bisher in die erste Wiedergabe. Fehler werden verschluckt, die Wiedergabe löst dann wie bisher auf.
    public func warmUp() async {
        guard let id = try? await scripts.currentPlayerId() else { return }
        _ = try? await scripts.signatureTimestamp(playerId: id)
        await solver.warmUp(playerId: id)
    }

    /// Noch gültiges Ergebnis aus dem Speicher, ohne Netzwerk.
    public func cached(_ videoId: String) -> ResolvedPlayback? {
        guard let hit = cache.get(videoId), !hit.isExpired(nowMs: nowMs()) else { return nil }
        return hit
    }

    /// Sofortstart: löst ein Video im Hintergrund auf. Fehler werden verschluckt – beim echten Start wird normal aufgelöst.
    public func prefetch(_ videoId: String) async -> Bool {
        if cached(videoId) != nil { return true }
        do { _ = try await resolveShared(videoId, forceRefresh: false); return true } catch { return false }
    }

    /// Der Videoserver hat die Streams dieses Wegs für [videoId] abgelehnt (HTTP 403 vor Ablauf der URLs).
    /// Die nächste Auflösung überspringt ihn.
    public func rejectRoute(videoId: String, routeLabel: String) {
        rejectedRoutes.put(videoId, (rejectedRoutes.get(videoId) ?? []).union([routeLabel]))
        cache.remove(videoId)
        health.recordTechnicalFailure(routeLabel)
    }

    /// Verwirft gecachte URLs (403-Recovery). Mit [resetPlayerScript] auch die Player-Skript-Zwischenspeicher.
    public func invalidate(_ videoId: String, resetPlayerScript: Bool = false) async {
        cache.remove(videoId)
        if resetPlayerScript { await scripts.clear(); warm = false }
    }

    /// „Erneut versuchen": alle Zwischenspeicher leeren und den Besucherzustand verwerfen.
    public func resetAll() async throws {
        warm = false
        cache.removeAll(); rejectedRoutes.removeAll()
        health.reset()
        await scripts.clear()
        try await endpoint.resetVisitorData()
    }

    /// Wiedergabe-Test: probiert ALLE Abspielwege (ohne beim ersten Erfolg aufzuhören), ohne Cache.
    public func diagnose(_ videoId: String) async throws -> [ClientAttempt] {
        var results: [ClientAttempt] = []
        let sts = try? await scripts.signatureTimestamp(playerId: await scripts.currentPlayerId())
        results.append(sts.flatMap { $0 }.map { ClientAttempt(label: "Player-Skript", outcome: .ok, detail: "signatureTimestamp \($0)") }
            ?? ClientAttempt(label: "Player-Skript", outcome: .failed, detail: "signatureTimestamp nicht ermittelbar"))
        let available = await solver.isAvailable()
        results.append(ClientAttempt(label: "Entschlüssler", outcome: available ? .ok : .skipped, detail: await solver.status()))
        let lazy = LazySignatureTimestamp(scripts: scripts)
        let tokens = await poTokens.tokens(videoId: videoId, visitorData: await endpoint.currentVisitorData(), generate: false)
        let profiles = await registry.profiles()
        let hasAccount = await endpoint.hasAccount()
        for p in profiles where p.requiresPoToken && tokens?.hasPlayerToken != true {
            results.append(ClientAttempt(label: p.label, outcome: .skipped, detail: "nur mit PO-Token"))
        }
        for route in PlaybackRoute.build(profiles: profiles, hasAccount: hasAccount, hasPoToken: tokens?.hasPlayerToken ?? false) {
            try Task.checkCancellation()
            do {
                let r = try await resolveWith(route: route, videoId: videoId, signatureTimestamp: lazy, tokens: tokens, attempts: AttemptLog())
                results.append(ClientAttempt(label: route.label, outcome: r.throttlingUnsolved ? .failed : .ok, detail: r.summary))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as PlaybackUnavailableError {
                results.append(ClientAttempt(label: route.label, outcome: .failed, detail: e.message))
            } catch let e as InnerTubeError {
                results.append(ClientAttempt(label: route.label, outcome: .failed, detail: "HTTP \(e.statusCode)"))
            } catch let e as URLError {
                results.append(ClientAttempt(label: route.label, outcome: .failed, detail: "Netzwerkfehler (\(type(of: e)))"))
            } catch {
                results.append(ClientAttempt(label: route.label, outcome: .failed, detail: "Fehler (\(type(of: error)))"))
            }
        }
        return results
    }

    // MARK: Auflösung

    private func totalTimeoutMs() -> Int64 { warm ? timings.warmTotalTimeoutMs : timings.totalTimeoutMs }

    private func resolveShared(_ videoId: String, forceRefresh: Bool) async throws -> ResolvedPlayback {
        if !forceRefresh, let hit = cached(videoId) { return hit }
        let task: Task<ResolvedPlayback, Error>
        if !forceRefresh, let running = inFlight[videoId] {
            task = running
        } else {
            nextToken += 1
            let token = nextToken
            // Eigene, nicht verbundene Aufgabe: Bricht der Aufrufer ab, läuft die Auflösung für andere Wartende weiter.
            task = Task { try await self.resolveFresh(videoId) }
            inFlight[videoId] = task
            inFlightToken[videoId] = token
            Task { _ = try? await task.value; await self.finish(videoId, token) }
        }
        return try await task.value
    }

    private func finish(_ videoId: String, _ token: Int) {
        if inFlightToken[videoId] == token { inFlight[videoId] = nil; inFlightToken[videoId] = nil }
    }

    private func resolveFresh(_ videoId: String) async throws -> ResolvedPlayback {
        let deadline = nowMs() + totalTimeoutMs()
        let kinds = KindSet()
        let visitor = await endpoint.currentVisitorData()
        var tokens: PoTokens?
        if autoPoToken && poTokenDemand {
            // YouTube hat schon einmal eine Bot-Prüfung verlangt: gleich mit Video-Token.
            tokens = await poTokens.tokens(videoId: videoId, visitorData: visitor, generate: true)
        } else if autoPoToken && alwaysPoToken {
            // Wie Android: Video-Token nur bei Bedarf. Der Streaming-Token ist zwischengespeichert, kostet also meist nichts.
            tokens = await poTokens.streamingTokens(visitorData: visitor)
        } else {
            tokens = await poTokens.tokens(videoId: videoId, visitorData: visitor, generate: false)
        }
        let resolved: ResolvedPlayback
        do {
            resolved = try await resolveRoutes(videoId, tokens: tokens, timeoutMs: max(deadline - nowMs(), timings.minRetryMs), kinds: kinds)
        } catch let first as PlaybackUnavailableError {
            // Bot-Prüfung trotz gespeicherter visitorData: Der Eintrag kann von YouTube als verdächtig markiert sein (am iPhone bleibt er
            // im Schlüsselbund auch nach dem Löschen der App erhalten, Android startet nach Neuinstallation frisch). Einmal ohne ihn
            // und mit frischer Besucher-Kennung wiederholen.
            if kinds.contains(.botCheck), await endpoint.currentVisitorData() != nil {
                try? await endpoint.resetVisitorData()
                let left = deadline - nowMs()
                if left >= timings.minRetryMs, let again = try? await resolveRoutes(videoId, tokens: tokens, timeoutMs: left, kinds: kinds) {
                    cache.put(videoId, again)
                    if !again.summary.contains(Self.noScriptMark) { warm = true }
                    return again
                }
            }
            let remaining = deadline - nowMs()
            let tokenMayHelp = kinds.contains(.botCheck) || kinds.contains(.sabrOnly)
            // Nur bei Bedarf einen Token erzeugen und noch einmal versuchen.
            var generated: PoTokens?
            let needsPlayerToken = tokens?.generated != true || tokens?.hasPlayerToken != true
            if autoPoToken, needsPlayerToken, tokenMayHelp, remaining >= timings.minRetryMs {
                poTokenDemand = true
                generated = await poTokens.tokens(videoId: videoId, visitorData: await endpoint.currentVisitorData(), generate: true)
                if generated?.generated != true { generated = nil }
            }
            let left = deadline - nowMs()
            if let generated, left >= timings.minSecondPassMs {
                tokens = generated
                do { resolved = try await resolveRoutes(videoId, tokens: generated, timeoutMs: left, kinds: kinds) } catch is PlaybackUnavailableError {
                    throw PlaybackUnavailableError(status: first.status, message: first.message, attempts: first.attempts, kinds: kinds.all)
                }
            } else {
                throw PlaybackUnavailableError(status: first.status, message: first.message, attempts: first.attempts, kinds: kinds.all)
            }
        }
        cache.put(videoId, resolved)
        // „Warm" erst, wenn ein Weg mit Player-Skript erfolgreich war (Skript und Solver geladen).
        if !resolved.summary.contains(Self.noScriptMark) { warm = true }
        return resolved
    }

    /// Ein Durchlauf über alle Wege (zeitversetzt parallel) mit festen [tokens].
    private func resolveRoutes(_ videoId: String, tokens: PoTokens?, timeoutMs: Int64, kinds: KindSet) async throws -> ResolvedPlayback {
        let all = PlaybackRoute.build(profiles: await registry.profiles(), hasAccount: await endpoint.hasAccount(), hasPoToken: tokens?.hasPlayerToken ?? false)
        let rejected = rejectedRoutes.get(videoId) ?? []
        // Hat der Videoserver alle Wege schon einmal abgelehnt, wieder von vorn beginnen.
        let allowed = all.filter { !rejected.contains($0.label) }
        let routes = health.order(allowed.isEmpty ? all : allowed)
        let lazy = LazySignatureTimestamp(scripts: scripts)
        let attempts = AttemptLog()
        let degraded = Box<ResolvedPlayback>()
        let health = self.health
        let timings = self.timings
        let sleepMs = self.sleepMs
        let selfRef = self
        do {
            let result: ResolvedPlayback? = try await withTimeoutOrNil(ms: timeoutMs, sleepMs: sleepMs, {
                try await firstSuccessfulRoute(
                    routes: routes, attempts: attempts, routeTimeoutMs: timings.routeTimeoutMs, hedgeDelayMs: timings.hedgeDelayMs,
                    sleepMs: sleepMs, onTechnicalFailure: { health.recordTechnicalFailure($0.label) },
                    onFailureKind: { kinds.insert($0) }
                ) { route in
                    let r = try await selfRef.resolveWith(route: route, videoId: videoId, signatureTimestamp: lazy, tokens: tokens, attempts: attempts)
                    if r.throttlingUnsolved {
                        try Task.checkCancellation()
                        degraded.setIfEmpty(r)
                        throw PlaybackUnavailableError(status: "N_PARAMETER", message: r.summary)
                    }
                    return r
                }
            })
            guard let result else {
                // Die Art „technisch" muss in die gemeinsame Menge, sonst geht sie im catch unten verloren.
                kinds.insert(.technical)
                throw PlaybackUnavailableError(
                    status: "TIMEOUT",
                    message: "Zeitüberschreitung: Kein Abspielweg hat in \(timeoutMs / 1000) s geantwortet. Prüfe die Internetverbindung.",
                    attempts: attempts.all, kinds: kinds.all.union([.technical]))
            }
            health.recordSuccess(result.clientLabel)
            return result
        } catch let error as PlaybackUnavailableError {
            if var fallback = degraded.value {
                // Kein Weg mit entschlüsseltem n-Parameter: lieber gedrosselt als gar nicht.
                fallback.attempts = error.attempts
                return fallback
            }
            if await lazy.failed {
                throw PlaybackUnavailableError(status: error.status, message: error.message,
                    attempts: error.attempts + [ClientAttempt(label: "Player-Skript", outcome: .failed, detail: "signatureTimestamp nicht ermittelbar")],
                    kinds: kinds.all)
            }
            throw PlaybackUnavailableError(status: error.status, message: error.message, attempts: error.attempts, kinds: kinds.all)
        }
    }

    // MARK: Ein Weg

    private final class Stats: @unchecked Sendable {
        let usesJs: Bool
        var solved: SolvedChallenges?
        var solverNote: String?
        var ciphered = 0, throttlingSolved = 0, throttlingFailed = 0
        var throttlingError: String?
        var lastDecipherError: String?
        init(usesJs: Bool) { self.usesJs = usesJs }
    }

    func resolveWith(route: PlaybackRoute, videoId: String, signatureTimestamp: LazySignatureTimestamp, tokens: PoTokens?,
                     attempts: AttemptLog) async throws -> ResolvedPlayback {
        let usesJs = route.profile.requiresJsPlayer
        let sts = usesJs ? await signatureTimestamp.get() : nil
        let response = try await endpoint.player(videoId: videoId, signatureTimestamp: sts, poToken: tokens?.player, profile: route.profile, useAccount: route.useAccount)
        let playerData = InnerTubeParser.parsePlayer(response)
        guard playerData.playability.isPlayable else {
            let reason = playerData.playability.reason ?? "Video nicht verfügbar"
            throw PlaybackUnavailableError(status: playerData.playability.status, message: "\(playerData.playability.status) – \(reason)")
        }
        let stats = Stats(usesJs: usesJs)
        if usesJs { stats.solved = await solveChallenges(playerData.adaptiveFormats + playerData.muxedFormats, stats) }
        let adaptive = try resolveFormats(playerData.adaptiveFormats, tokens?.streaming, stats)
        let muxed = try resolveFormats(playerData.muxedFormats, tokens?.streaming, stats)
        if adaptive.isEmpty && muxed.isEmpty && playerData.hlsManifestUrl == nil {
            if playerData.isSabrOnly { throw PlaybackUnavailableError(status: FailureKind.sabrStatus, message: "keine Stream-URLs (nur SABR)") }
            let detail = stats.lastDecipherError
                ?? (playerData.adaptiveFormats.isEmpty && playerData.muxedFormats.isEmpty ? "keine Formate in der Antwort" : "keine Stream-URLs (nur SABR)")
            throw PlaybackUnavailableError(status: "NO_STREAMS", message: detail)
        }
        let now = nowMs()
        let expiresAt = now + (playerData.expiresInSeconds ?? Self.defaultExpirySeconds) * 1000
        var summary = "\(adaptive.count + muxed.count) Formate"
        if playerData.hlsManifestUrl != nil { summary += ", HLS" }
        if !usesJs { summary += ", \(Self.noScriptMark)" }
        if stats.solved != nil { summary += ", Entschlüssler EJS" }
        if stats.ciphered > 0 { summary += ", Signatur entschlüsselt" }
        if stats.throttlingSolved > 0 { summary += ", n-Parameter entschlüsselt" }
        if stats.throttlingFailed > 0 {
            summary += ", n-Parameter NICHT entschlüsselt"
            if let note = stats.solverNote ?? stats.throttlingError { summary += " (\(note))" }
        }
        let unsolved = stats.throttlingFailed > 0
        // Ein Weg mit ungelöstem n-Parameter wird vom Aufrufer als Fehlschlag protokolliert.
        if !unsolved { attempts.append(ClientAttempt(label: route.label, outcome: .ok, detail: summary)) }
        return ResolvedPlayback(
            videoId: videoId, playerData: playerData, adaptiveFormats: adaptive, muxedFormats: muxed, resolvedAtMs: now,
            expiresAtMs: expiresAt, clientLabel: route.label, userAgent: route.profile.userAgent, attempts: attempts.all,
            summary: summary, throttlingUnsolved: unsolved)
    }

    private func resolveFormats(_ formats: [StreamFormat], _ poToken: String?, _ stats: Stats) throws -> [StreamFormat] {
        var resolved: [StreamFormat] = []
        for format in formats {
            try Task.checkCancellation()
            do {
                guard let url = try resolveUrl(format, poToken, stats) else { continue }
                var f = format
                f.url = url; f.signatureCipher = nil
                resolved.append(f)
            } catch let e as DecipherError {
                try Task.checkCancellation()
                stats.lastDecipherError = e.message
            }
        }
        return resolved
    }

    private struct Cipher { let baseUrl: String; let signature: String; let parameter: String }

    /// Teile eines `signatureCipher` (`s=…&sp=sig&url=…`).
    private func parseCipher(_ cipher: String) -> Cipher? {
        let items = URLQuery.items(cipher)
        guard let base = items.first(where: { $0.name == "url" })?.value, let s = items.first(where: { $0.name == "s" })?.value else { return nil }
        return Cipher(baseUrl: base, signature: s, parameter: items.first(where: { $0.name == "sp" })?.value ?? "signature")
    }

    /// Alle n- und Signatur-Herausforderungen einer Antwort in EINEM Lauf des Entschlüsslers lösen.
    private func solveChallenges(_ formats: [StreamFormat], _ stats: Stats) async -> SolvedChallenges? {
        let ciphers = formats.compactMap { $0.signatureCipher.flatMap(parseCipher) }
        let urls = formats.compactMap(\.url) + ciphers.map(\.baseUrl)
        let n = Set(urls.compactMap { URLQuery.parameter("n", in: $0) })
        let signatures = Set(ciphers.map(\.signature))
        if n.isEmpty && signatures.isEmpty { return nil }
        guard await solver.isAvailable() else {
            stats.solverNote = "Entschlüssler-Sandbox auf diesem Gerät nicht verfügbar"
            return nil
        }
        do {
            return try await solver.solve(playerId: try await scripts.currentPlayerId(), nChallenges: n, sigChallenges: signatures)
        } catch let e as SolverError {
            stats.solverNote = e.message
        } catch is CancellationError {
            return nil
        } catch {
            stats.solverNote = "Player-Skript nicht ladbar (\(type(of: error)))"
        }
        return nil
    }

    private func resolveUrl(_ format: StreamFormat, _ poToken: String?, _ stats: Stats) throws -> String? {
        if !stats.usesJs {
            // Wege ohne Player-Skript: nur direkte URLs, nichts entschlüsseln.
            return format.url.map { appendPoToken($0, poToken) }
        }
        var url: String
        if let direct = format.url {
            url = direct
        } else if let cipher = format.signatureCipher {
            guard let parts = parseCipher(cipher) else { throw DecipherError(message: "signatureCipher ohne url oder s") }
            guard let solved = stats.solved?.sig[parts.signature] else {
                throw DecipherError(message: "Signatur nicht entschlüsselt" + (stats.solverNote.map { " (\($0))" } ?? ""))
            }
            url = URLQuery.appending(parts.parameter, solved, to: parts.baseUrl)
            stats.ciphered += 1
        } else {
            return nil
        }
        if let nValue = URLQuery.parameter("n", in: url) {
            // Wirft die n-Funktion einen Fehler, liefert YouTubes Skript „enhanced_except_…“ statt eines Ergebnisses: kein gültiger
            // Wert, der Videoserver lehnt solche Adressen ab (403). Als ungelöst zählen, damit der nächste Weg drankommt.
            if let solvedN = stats.solved?.n[nValue], !solvedN.hasPrefix("enhanced_except"), solvedN != nValue {
                url = URLQuery.replacing("n", with: solvedN, in: url)
                stats.throttlingSolved += 1
            } else {
                stats.throttlingFailed += 1
                if stats.throttlingError == nil { stats.throttlingError = stats.solverNote ?? "n-Parameter nicht lösbar" }
            }
        }
        return appendPoToken(url, poToken)
    }

    private func appendPoToken(_ url: String, _ poToken: String?) -> String {
        guard let poToken, !poToken.trimmingCharacters(in: .whitespaces).isEmpty, URLQuery.parameter("pot", in: url) == nil else { return url }
        return URLQuery.appending("pot", poToken, to: url)
    }
}

/// `signatureTimestamp` erst ermitteln, wenn ein Weg das Player-Skript braucht: Wege ohne JavaScript starten so,
/// ohne dass ~3 MB Skript geladen und analysiert werden.
actor LazySignatureTimestamp {
    private let scripts: PlayerScriptProviding
    private var loaded = false
    private var value: Int?
    init(scripts: PlayerScriptProviding) { self.scripts = scripts }
    var failed: Bool { loaded && value == nil }

    func get() async -> Int? {
        if !loaded {
            do { value = try await scripts.signatureTimestamp(playerId: try await scripts.currentPlayerId()) } catch { value = nil }
            if Task.isCancelled { return nil } // nicht als „fehlgeschlagen" merken
            loaded = true
        }
        return value
    }
}

final class KindSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<FailureKind>()
    func insert(_ k: FailureKind) { lock.withLock { _ = set.insert(k) } }
    func contains(_ k: FailureKind) -> Bool { lock.withLock { set.contains(k) } }
    var all: Set<FailureKind> { lock.withLock { set } }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    var value: T? { lock.withLock { v } }
    func setIfEmpty(_ x: T) { lock.withLock { if v == nil { v = x } } }
}
