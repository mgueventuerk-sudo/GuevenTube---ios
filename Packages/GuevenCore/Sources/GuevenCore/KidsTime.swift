import Foundation

/// Einstellungen des Kindermodus, soweit die Zeitsperre sie braucht.
public struct KidsSettings: Equatable, Sendable {
    public var kidsMode: Bool
    /// Stunde (1–23), ab der Pause ist; `0` = keine Schlafenszeit.
    public var kidsBedtimeHour: Int
    /// Tageslimit in Minuten; `0` = kein Limit.
    public var kidsDailyLimitMinutes: Int
    public init(kidsMode: Bool = false, kidsBedtimeHour: Int = 0, kidsDailyLimitMinutes: Int = 0) {
        self.kidsMode = kidsMode; self.kidsBedtimeHour = kidsBedtimeHour; self.kidsDailyLimitMinutes = kidsDailyLimitMinutes
    }
}

public struct KidsBlock: Equatable, Sendable { public var reason: String }

public protocol KidsUsageStore: Sendable {
    func load() async -> (day: Int, seconds: Int64)
    func save(day: Int, seconds: Int64) async
}

public actor InMemoryKidsUsageStore: KidsUsageStore {
    private var day = 0, seconds: Int64 = 0
    public init() {}
    public func load() -> (day: Int, seconds: Int64) { (day, seconds) }
    public func save(day: Int, seconds: Int64) { self.day = day; self.seconds = seconds }
}

/// Kindermodus-Zeiten: Tageslimit und Schlafenszeit. Ist eine Grenze erreicht, soll die Wiedergabe anhalten und eine Sperre
/// erscheinen; mit der Profil-PIN lässt sie sich für `unlockMs` aufheben. Ohne Kindermodus oder ohne Grenzen ist nichts aktiv.
public actor KidsTimeGuard {
    public static let tickMs: Int64 = 15_000
    public static let unlockMs: Int64 = 30 * 60 * 1000
    public static let bedtimeEndHour = 7

    private let usage: KidsUsageStore
    private let lock: ProfileLock
    private let calendar: Calendar
    private let nowMs: @Sendable () -> Int64
    private var unlockedUntil: Int64 = 0
    public private(set) var block: KidsBlock?

    public init(usage: KidsUsageStore, profileLock: ProfileLock, calendar: Calendar = .current,
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.usage = usage; self.lock = profileLock; self.calendar = calendar; self.nowMs = nowMs
    }

    /// Ein Takt: Nutzung zählen (nur während der Wiedergabe) und Sperre neu bewerten.
    @discardableResult
    public func tick(settings: KidsSettings, playing: Bool, at now: Int64? = nil) async -> KidsBlock? {
        let now = now ?? nowMs()
        let today = Self.dayKey(now, calendar: calendar)
        var state = await usage.load()
        if state.day != today { state = (today, 0) }
        if settings.kidsMode && playing { state.seconds += Self.tickMs / 1000 }
        await usage.save(day: state.day, seconds: state.seconds)
        block = Self.evaluate(settings, nowMs: now, usedSeconds: state.seconds, unlockedUntil: unlockedUntil, calendar: calendar)
        return block
    }

    public func usedMinutesToday() async -> Int64 {
        let state = await usage.load()
        return state.day == Self.dayKey(nowMs(), calendar: calendar) ? state.seconds / 60 : 0
    }

    /// PIN prüfen; bei Erfolg für `unlockMs` frei. Rückgabe: Fehlermeldung oder `nil`.
    public func unlock(pin: String) async -> String? {
        switch await lock.verify(pin) {
        case .ok:
            unlockedUntil = nowMs() + Self.unlockMs
            block = nil
            return nil
        case .wrong: return "Falsche PIN."
        case .locked(let seconds): return "Zu viele Versuche – bitte \(seconds) s warten."
        }
    }

    public static func dayKey(_ nowMs: Int64, calendar: Calendar = .current) -> Int {
        let date = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        return calendar.component(.year, from: date) * 1000 + (calendar.ordinality(of: .day, in: .year, for: date) ?? 0)
    }

    /// Rein und testbar: Ist gerade gesperrt, und warum?
    public static func evaluate(_ settings: KidsSettings, nowMs: Int64, usedSeconds: Int64, unlockedUntil: Int64, calendar: Calendar = .current) -> KidsBlock? {
        if !settings.kidsMode || nowMs < unlockedUntil { return nil }
        let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: Double(nowMs) / 1000))
        let bedtime = settings.kidsBedtimeHour
        if bedtime > 0 && (hour >= bedtime || hour < bedtimeEndHour) { return KidsBlock(reason: "Schlafenszeit – bis \(bedtimeEndHour) Uhr ist Pause.") }
        let limit = settings.kidsDailyLimitMinutes
        if limit > 0 && usedSeconds >= Int64(limit) * 60 { return KidsBlock(reason: "Die Zeit für heute (\(limit) Minuten) ist aufgebraucht.") }
        return nil
    }
}
