import Foundation

public enum MusicRepeat: String, Codable, Sendable { case off = "OFF", all = "ALL", one = "ONE" }

/// Zufallsquelle, die sich in Tests durch eine feste Folge ersetzen lässt.
public struct AnyRandom: RandomNumberGenerator {
    private var source: () -> UInt64
    public init(_ source: @escaping () -> UInt64) { self.source = source }
    public init() { var g = SystemRandomNumberGenerator(); self.source = { g.next() } }
    /// Deterministisch (SplitMix64) für Tests.
    public init(seed: UInt64) {
        var state = seed
        self.source = {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    public mutating func next() -> UInt64 { source() }
}

/// Folgen einer Zustandsänderung, die die Oberfläche/der Player ausführen muss.
public struct MusicQueueEffect: Equatable, Sendable {
    /// Dieser Titel soll jetzt gestartet werden.
    public var play: MusicSong?
    /// Aktuellen Titel von vorn spielen (Wiederholen, „Zurück“ nach 3 s).
    public var restartCurrent = false
    /// Radio-Nachschub für diesen Titel laden.
    public var refillSeed: String?
    /// Der Player wartet auf den Nachschub (Warteschlange war leer).
    public var refillStartsPlayback = false
    /// `false`: nichts zu tun, die Musik endet.
    public var handled = true
    public init() {}
}

/// Reine Warteschlangenlogik der Musikwiedergabe (Port von `MusicPlayback.kt`, ohne Player und Netz).
/// Die Oberfläche führt die zurückgegebenen [MusicQueueEffect] aus.
public struct MusicQueueState: Equatable, Sendable {
    public static let refillBelow = 3
    public static let radioBatch = 25
    public static let maxHistory = 50
    public static let maxQueue = 200
    public static let restartThresholdMs: Int64 = 3_000

    public private(set) var current: MusicSong?
    public private(set) var upcoming: [MusicSong] = []
    public private(set) var history: [MusicSong] = []
    public private(set) var repeatMode: MusicRepeat = .off
    public private(set) var shuffle = false
    public private(set) var radioSeed: String?
    private var listOrder: [MusicSong]?
    private var unshuffled: [MusicSong]?

    public init() {}

    public static func == (l: MusicQueueState, r: MusicQueueState) -> Bool {
        l.current == r.current && l.upcoming == r.upcoming && l.history == r.history && l.repeatMode == r.repeatMode
            && l.shuffle == r.shuffle && l.radioSeed == r.radioSeed && l.listOrder == r.listOrder && l.unshuffled == r.unshuffled
    }

    // MARK: Abspielen

    /// Spielt [songs] ab Position [index]; mit [radio] geht es danach mit passender Musik weiter.
    public mutating func play(_ songs: [MusicSong], index: Int = 0, radio: Bool? = nil, shuffle wantShuffle: Bool = false,
                              using rng: inout AnyRandom) -> MusicQueueEffect {
        guard !songs.isEmpty else { var e = MusicQueueEffect(); e.handled = false; return e }
        let radio = radio ?? (songs.count <= 1)
        history.removeAll()
        let unique = Self.distinct(songs)
        listOrder = Array(unique.prefix(Self.maxQueue + 1))
        if wantShuffle {
            let mixed = Array(unique.shuffled(using: &rng).prefix(Self.maxQueue + 1))
            unshuffled = Array(unique.prefix(Self.maxQueue + 1))
            shuffle = true
            upcoming = Array(mixed.dropFirst())
            radioSeed = radio ? mixed[0].videoId : nil
            return start(mixed[0], record: false)
        }
        let start = min(max(index, 0), songs.count - 1)
        let rest = Array(Self.distinct(Array(songs.dropFirst(start + 1))).prefix(Self.maxQueue))
        if shuffle {
            unshuffled = rest
            upcoming = rest.shuffled(using: &rng)
        } else {
            unshuffled = nil
            upcoming = rest
        }
        radioSeed = radio ? songs[start].videoId : nil
        return self.start(songs[start], record: false)
    }

    public mutating func startRadio(_ song: MusicSong, using rng: inout AnyRandom) -> MusicQueueEffect {
        play([song], index: 0, radio: true, using: &rng)
    }

    /// Titel als Nächstes einreihen, ohne den laufenden zu unterbrechen.
    public mutating func playNext(_ song: MusicSong, using rng: inout AnyRandom) -> MusicQueueEffect {
        guard current != nil else { return play([song], index: 0, radio: false, using: &rng) }
        upcoming = [song] + upcoming.filter { $0.videoId != song.videoId }
        unshuffled = unshuffled.map { [song] + $0.filter { $0.videoId != song.videoId } }
        return MusicQueueEffect()
    }

    /// Nächster Titel. Bei leerer Warteschlange und „Alle wiederholen“ beginnt die Liste von vorn.
    public mutating func next(using rng: inout AnyRandom) -> MusicQueueEffect {
        if let next = upcoming.first {
            upcoming.removeFirst()
            unshuffled = unshuffled.map { $0.filter { $0.videoId != next.videoId } }
            return start(next, record: true)
        }
        if repeatMode == .all { return restartList(using: &rng) }
        // Radio mit leerer Warteschlange (Nachladen bisher gescheitert): jetzt nachladen und weiterspielen.
        if radioSeed != nil, let seed = current?.videoId {
            var e = MusicQueueEffect()
            e.refillSeed = seed
            e.refillStartsPlayback = true
            return e
        }
        var e = MusicQueueEffect()
        e.handled = false
        return e
    }

    /// Titel zu Ende gespielt: „Titel wiederholen“ spielt ihn erneut, sonst wie `next`.
    public mutating func trackEnded(using rng: inout AnyRandom) -> MusicQueueEffect {
        if repeatMode == .one && current != nil {
            var e = MusicQueueEffect()
            e.restartCurrent = true
            return e
        }
        return next(using: &rng)
    }

    /// Vorheriger Titel: nach 3 s Spielzeit an den Anfang, sonst der zuletzt gespielte.
    public mutating func previous(positionMs: Int64) -> MusicQueueEffect {
        let previous = history.popLast()
        if previous == nil || positionMs > Self.restartThresholdMs {
            if let previous { history.append(previous) }
            var e = MusicQueueEffect()
            e.restartCurrent = true
            return e
        }
        if let current {
            upcoming = [current] + upcoming.filter { $0.videoId != current.videoId }
            unshuffled = unshuffled.map { [current] + $0.filter { $0.videoId != current.videoId } }
        }
        return start(previous!, record: false)
    }

    // MARK: Umschalten

    /// Aus → alle → ein Titel → aus.
    public mutating func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    public mutating func setRepeat(_ mode: MusicRepeat) { repeatMode = mode }

    /// Aus stellt die ursprüngliche Reihenfolge der noch kommenden Titel wieder her.
    public mutating func toggleShuffle(using rng: inout AnyRandom) {
        if shuffle {
            if let order = unshuffled {
                var queued: [String: MusicSong] = [:]
                for s in upcoming { queued[s.videoId] = s }
                let restored = order.compactMap { queued[$0.videoId] }
                let known = Set(restored.map(\.videoId))
                upcoming = restored + upcoming.filter { !known.contains($0.videoId) }
            }
            unshuffled = nil
            shuffle = false
        } else {
            unshuffled = upcoming
            upcoming = upcoming.shuffled(using: &rng)
            shuffle = true
        }
    }

    // MARK: Warteschlange bearbeiten

    /// Springt zu Titel [index] der Warteschlange; übersprungene Titel landen im Verlauf.
    public mutating func jumpTo(_ index: Int) -> MusicQueueEffect {
        guard upcoming.indices.contains(index) else { var e = MusicQueueEffect(); e.handled = false; return e }
        let target = upcoming[index]
        let skipped = Array(upcoming.prefix(index))
        if let current { remember(current) }
        skipped.forEach { remember($0) }
        upcoming = Array(upcoming.dropFirst(index + 1))
        let gone = Set((skipped + [target]).map(\.videoId))
        unshuffled = unshuffled.map { $0.filter { !gone.contains($0.videoId) } }
        return start(target, record: false)
    }

    public mutating func remove(at index: Int) {
        guard upcoming.indices.contains(index) else { return }
        let removed = upcoming.remove(at: index)
        unshuffled = unshuffled.map { $0.filter { $0.videoId != removed.videoId } }
    }

    public mutating func move(from: Int, to: Int) {
        guard upcoming.indices.contains(from), upcoming.indices.contains(to), from != to else { return }
        let item = upcoming.remove(at: from)
        upcoming.insert(item, at: to)
    }

    /// Musik beenden: alles zurücksetzen (Wiederholen/Zufall bleiben als Einstellung des Nutzers erhalten).
    public mutating func stop() {
        history.removeAll(); radioSeed = nil; listOrder = nil; unshuffled = nil; upcoming = []; current = nil
    }

    // MARK: Radio

    /// Nachschub fürs Radio: Titel in der Warteschlange oder laufend ([queued]) kommen nie wieder. Bereits
    /// gespielte ([played]) werden übersprungen, **solange** noch etwas anderes übrig ist (das Radio ist endlos,
    /// die Antwort von YouTube aber endlich).
    public static func pickRefill(_ songs: [MusicSong], queued: Set<String>, played: Set<String>, limit: Int = radioBatch) -> [MusicSong] {
        let free = songs.filter { !queued.contains($0.videoId) }
        let unplayed = free.filter { !played.contains($0.videoId) }
        return Array((unplayed.isEmpty ? free : unplayed).prefix(limit))
    }

    /// Verarbeitet die Radio-Antwort. `failed`: Abfrage lieferte nichts Spielbares, obwohl der Player wartet.
    public mutating func applyRadio(_ songs: [MusicSong], startWhenLoaded: Bool, using rng: inout AnyRandom) -> (effect: MusicQueueEffect, failed: Bool) {
        guard let current else { var e = MusicQueueEffect(); e.handled = false; return (e, false) }
        var queued = Set(upcoming.map(\.videoId)); queued.insert(current.videoId)
        let fresh = Self.pickRefill(songs, queued: queued, played: Set(history.map(\.videoId)))
        upcoming = Array((upcoming + (shuffle ? fresh.shuffled(using: &rng) : fresh)).prefix(Self.maxQueue))
        unshuffled = unshuffled.map { Array(($0 + fresh).prefix(Self.maxQueue)) }
        guard startWhenLoaded else { return (MusicQueueEffect(), false) }
        if upcoming.isEmpty { return (MusicQueueEffect(), true) }
        return (next(using: &rng), false)
    }

    // MARK: intern

    private mutating func restartList(using rng: inout AnyRandom) -> MusicQueueEffect {
        let played = Self.distinct(history + (current.map { [$0] } ?? []))
        guard !played.isEmpty else { var e = MusicQueueEffect(); e.handled = false; return e }
        // Ursprüngliche (Album-)Reihenfolge, soweit bekannt; sonst die gespielte.
        let playedIds = Set(played.map(\.videoId))
        var known = (listOrder ?? []).filter { playedIds.contains($0.videoId) }
        if known.isEmpty { known = played }
        let knownIds = Set(known.map(\.videoId))
        let all = known + played.filter { !knownIds.contains($0.videoId) }
        history.removeAll()
        let order = shuffle ? all.shuffled(using: &rng) : all
        upcoming = Array(order.dropFirst())
        unshuffled = shuffle ? all.filter { $0.videoId != order[0].videoId } : nil
        return start(order[0], record: false)
    }

    private mutating func remember(_ song: MusicSong) {
        history.append(song)
        while history.count > Self.maxHistory { history.removeFirst() }
    }

    private mutating func start(_ song: MusicSong, record: Bool) -> MusicQueueEffect {
        if record, let current, current.videoId != song.videoId { remember(current) }
        current = song
        var e = MusicQueueEffect()
        e.play = song
        if radioSeed != nil && upcoming.count < Self.refillBelow { e.refillSeed = song.videoId }
        return e
    }

    private static func distinct(_ songs: [MusicSong]) -> [MusicSong] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.videoId).inserted }
    }
}
