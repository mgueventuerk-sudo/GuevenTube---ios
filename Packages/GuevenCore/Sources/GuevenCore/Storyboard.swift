import Foundation

/// Eine Auflösungsstufe der Storyboard-Sprites: Bögen mit `columns` × `rows` Vorschaubildern.
public struct StoryboardLevel: Equatable, Sendable {
    public var urlTemplate: String
    public var frameWidth: Int, frameHeight: Int, frameCount: Int, columns: Int, rows: Int
    /// Abstand der Bilder; 0 = gleichmäßig über die Videolänge verteilt.
    public var intervalMs: Int64
    public var name: String
    public var signature: String?
}

/// Ausschnitt eines Sprite-Bogens für eine Position im Video.
public struct StoryboardFrame: Equatable, Sendable {
    public var sheetUrl: String
    public var column: Int, row: Int, frameWidth: Int, frameHeight: Int
}

/// Vorschaubilder beim Spulen aus der Storyboard-Spezifikation der Player-Antwort:
/// `https://i.ytimg.com/sb/<id>/storyboard3_L$L/$N.jpg?sqp=…|48#27#100#10#10#0#default#rs$…|80#45#…#M$M#rs$…`
public struct Storyboard: Equatable, Sendable {
    public var levels: [StoryboardLevel]

    /// Beste Stufe mit mindestens `minWidth` px Breite, sonst die größte.
    public func level(minWidth: Int = 160) -> StoryboardLevel? {
        let usable = levels.filter { $0.frameCount > 1 }
        return usable.first { $0.frameWidth >= minWidth } ?? usable.max { $0.frameWidth < $1.frameWidth }
    }

    public func frameAt(positionMs: Int64, durationMs: Int64, minWidth: Int = 160) -> StoryboardFrame? {
        guard let level = level(minWidth: minWidth) else { return nil }
        let interval: Int64
        if level.intervalMs > 0 { interval = level.intervalMs }
        else if durationMs > 0 { interval = durationMs / Int64(level.frameCount) }
        else { return nil }
        let step = max(interval, 1)
        let index = Int(min(max(max(positionMs, 0) / step, 0), Int64(level.frameCount - 1)))
        let perSheet = max(level.columns * level.rows, 1)
        let sheet = index / perSheet, within = index % perSheet
        let levelIndex = levels.firstIndex(of: level) ?? 0
        var url = level.urlTemplate
            .replacingOccurrences(of: "$L", with: String(levelIndex))
            .replacingOccurrences(of: "$N", with: level.name.replacingOccurrences(of: "$M", with: String(sheet)))
        if let sig = level.signature { url += (url.contains("?") ? "&" : "?") + "sigh=" + sig }
        return StoryboardFrame(sheetUrl: url, column: within % level.columns, row: within / level.columns, frameWidth: level.frameWidth, frameHeight: level.frameHeight)
    }

    public static func parse(_ spec: String?) -> Storyboard? {
        guard let spec, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2, parts[0].hasPrefix("https://") else { return nil }
        let levels: [StoryboardLevel] = parts.dropFirst().compactMap { part in
            let f = part.components(separatedBy: "#")
            guard f.count >= 7, let w = Int(f[0]), let h = Int(f[1]), let n = Int(f[2]), n > 0, let c = Int(f[3]), c > 0, let r = Int(f[4]), r > 0 else { return nil }
            let sig = f.count > 7 && !f[7].trimmingCharacters(in: .whitespaces).isEmpty ? f[7] : nil
            return StoryboardLevel(urlTemplate: parts[0], frameWidth: w, frameHeight: h, frameCount: n, columns: c, rows: r, intervalMs: Int64(f[5]) ?? 0, name: f[6], signature: sig)
        }
        return levels.isEmpty ? nil : Storyboard(levels: levels)
    }
}

/// Liefert das Storyboard eines Videos: aus der bereits aufgelösten Player-Antwort, sonst (manche Abspielwege liefern keins)
/// über eine zusätzliche, leichte Player-Anfrage mit einem TV-Profil. Positive Treffer (8) und Fehlschläge (32) werden gemerkt.
public actor StoryboardRepository {
    private var cache = LRUCache<Storyboard>(capacity: 8)
    private var missing = LRUCache<Bool>(capacity: 32)
    private let cachedSpec: @Sendable (String) async -> String?
    private let fetchSpec: @Sendable (String) async throws -> String??

    /// `fetchSpec` liefert `.none`, wenn kein passender Abspielweg existiert, sonst die Spezifikation (oder `.some(nil)`).
    public init(cachedSpec: @escaping @Sendable (String) async -> String?, fetchSpec: @escaping @Sendable (String) async throws -> String??) {
        self.cachedSpec = cachedSpec; self.fetchSpec = fetchSpec
    }

    /// Anbindung an Resolver, Profile und InnerTube.
    public init(resolver: StreamResolver, service: InnerTubeService, profiles: ClientProfileProviding) {
        self.init(
            cachedSpec: { await resolver.cached($0)?.playerData.storyboardSpec },
            fetchSpec: { id in
                guard let profile = await profiles.profiles().first(where: { $0.requiresJsPlayer && !$0.requiresPoToken }) else { return .none }
                let response = try await service.player(videoId: id, signatureTimestamp: nil, poToken: nil, profile: profile, useAccount: false)
                return .some(InnerTubeParser.parsePlayer(response).storyboardSpec)
            })
    }

    public func storyboard(_ videoId: String) async -> Storyboard? {
        if let hit = cache.get(videoId) { return hit }
        if missing.get(videoId) == true { return nil }
        if let sb = Storyboard.parse(await cachedSpec(videoId)) { cache.put(videoId, sb); return sb }
        do {
            let outer = try await fetchSpec(videoId)
            if let sb = outer.flatMap({ Storyboard.parse($0) }) { cache.put(videoId, sb); return sb }
            missing.put(videoId, true); return nil
        } catch {
            if Task.isCancelled { return nil }   // Abbruch ist kein Fehlschlag des Videos
            missing.put(videoId, true); return nil
        }
    }
}
