import Foundation

/// Neue Funktionen hinter Schaltern (Port von FeatureFlags.kt, nur iPhone). [defaultOn] gilt, solange der Nutzer
/// nichts gewählt hat; Labor-Funktionen stehen unter Einstellungen → Labor, die übrigen sind nur aus der Ferne
/// abschaltbar. Android-eigene Schalter (Cronet, DNS-über-HTTPS, Android Auto, TV-Vorschau/PiP, SABR) entfallen:
/// URLSession spricht HTTP/3 selbst, und SABR ist nicht portiert.
public enum Feature: String, CaseIterable, Sendable {
    case webpThumbnails = "webp_thumbnails"
    case feedModelCache = "feed_model_cache"
    case videoPreload = "video_preload"
    case adaptiveQuality = "adaptive_quality"
    case transcriptSummary = "transcript_summary"
    case voiceCommands = "voice_commands"
    case localRecommendations = "local_recommendations"
    case watchTogether = "watch_together"
    case highlightMode = "highlight_mode"
    case music = "music"
    case autoPoToken = "auto_potoken"

    public var key: String { rawValue }

    public var title: String {
        switch self {
        case .webpThumbnails: return "Vorschaubilder als WebP"
        case .feedModelCache: return "Schneller Zwischenstand"
        case .videoPreload: return "Videos vorab laden"
        case .adaptiveQuality: return "Qualität bei Hängern anpassen"
        case .transcriptSummary: return "Kurzfassung & Kapitel"
        case .voiceCommands: return "Sprachbefehle"
        case .localRecommendations: return "Empfehlungen ohne Konto"
        case .watchTogether: return "Gemeinsam schauen"
        case .highlightMode: return "Kurzfassung abspielen"
        case .music: return "Musik-Bereich"
        case .autoPoToken: return "Automatischer Prüfschlüssel"
        }
    }

    public var featureDescription: String {
        switch self {
        case .webpThumbnails: return "Kleinere Bilder, Rückfall auf JPEG"
        case .feedModelCache: return "Startseite fertig aufbereitet speichern"
        case .videoPreload: return "Erste Sekunden des gewählten Videos im WLAN vorladen"
        case .adaptiveQuality: return "Nach wiederholtem Puffern eine Stufe niedriger, je Gerät gelernt"
        case .transcriptSummary: return "Zusammenfassung und Kapitel aus dem Transkript, auf dem Gerät berechnet"
        case .voiceCommands: return "„Spiel …“ startet das erste Ergebnis, „Suche …“ sucht"
        case .localRecommendations: return "Zusätzliche Reihe aus deinem Verlauf, nur auf dem Gerät"
        case .watchTogether: return "Handy und Fernseher spielen dasselbe Video synchron"
        case .highlightMode: return "Spielt nur Kapitelanfänge und den Höhepunkt (je 20 s)"
        case .music: return "YouTube Music als eigener Bereich: Startseite, Suche, Alben, Radio, Liedtexte, im Hintergrund"
        case .autoPoToken: return "Löst bei Bedarf Googles Bot-Prüfung im unsichtbaren Browser (poToken). Nur Rückfall"
        }
    }

    public var defaultOn: Bool {
        switch self {
        case .webpThumbnails, .feedModelCache, .videoPreload, .adaptiveQuality, .music: return true
        case .transcriptSummary, .voiceCommands, .localRecommendations, .watchTogether, .highlightMode, .autoPoToken: return false
        }
    }

    /// Im Labor sichtbar (vom Nutzer schaltbar).
    public var lab: Bool {
        switch self {
        case .webpThumbnails, .feedModelCache: return false
        default: return true
        }
    }

    public static func fromKey(_ key: String) -> Feature? { Feature(rawValue: key) }
}

/// Ablage der Nutzerwahl (auf dem iPhone `UserDefaults`).
public protocol FeatureChoiceStore: Sendable {
    func choice(for key: String) -> Bool?
    func setChoice(_ value: Bool, for key: String)
    func removeAll(keys: [String])
}

public final class InMemoryFeatureChoiceStore: FeatureChoiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    public init() {}
    public func choice(for key: String) -> Bool? { lock.withLock { values[key] } }
    public func setChoice(_ value: Bool, for key: String) { lock.withLock { values[key] = value } }
    public func removeAll(keys: [String]) { lock.withLock { keys.forEach { values[$0] = nil } } }
}

public final class UserDefaultsFeatureChoiceStore: FeatureChoiceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "feature_flags."
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func choice(for key: String) -> Bool? { defaults.object(forKey: prefix + key) == nil ? nil : defaults.bool(forKey: prefix + key) }
    public func setChoice(_ value: Bool, for key: String) { defaults.set(value, forKey: prefix + key) }
    public func removeAll(keys: [String]) { keys.forEach { defaults.removeObject(forKey: prefix + $0) } }
}

/// Schalter-Zentrale: Standardwert → Nutzerwahl (Labor) → Notschalter aus der Fern-Konfiguration. Die Fern-Konfiguration
/// kann nur **ab**schalten (`flags["disable.<key>"] = true`), nie einschalten – ein fehlerhaftes Paket kann so höchstens
/// Funktionen deaktivieren. Ohne Concurrency lesbar (für Netz-Code).
public final class FeatureFlags: @unchecked Sendable {
    private static let disablePrefix = "disable."
    private let store: FeatureChoiceStore
    private let lock = NSLock()
    private var remoteDisabled: Set<String> = []
    private var overrides: [Feature: Bool] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]
    /// Zählt bei jeder Änderung hoch (Oberflächen zeichnen dann neu).
    public private(set) var changes = 0

    public init(store: FeatureChoiceStore = UserDefaultsFeatureChoiceStore()) { self.store = store }

    public func isEnabled(_ feature: Feature) -> Bool {
        let (override, disabled) = lock.withLock { (overrides[feature], remoteDisabled.contains(feature.key)) }
        if let override { return override }
        if disabled { return false }
        return store.choice(for: feature.key) ?? feature.defaultOn
    }

    /// Durch die Fern-Konfiguration abgeschaltet (Anzeige im Labor).
    public func isRemotelyDisabled(_ feature: Feature) -> Bool { lock.withLock { remoteDisabled.contains(feature.key) } }

    public func setUserChoice(_ feature: Feature, enabled: Bool) { store.setChoice(enabled, for: feature.key); notify() }

    public func resetUserChoices() { store.removeAll(keys: Feature.allCases.map(\.key)); notify() }

    /// Aus der Fern-Konfiguration: nur `disable.<key>` = true wirkt, unbekannte Schlüssel werden ignoriert.
    public func applyRemote(_ flags: [String: Bool]) {
        let disabled = Set(flags.compactMap { name, value -> String? in
            guard value, name.hasPrefix(Self.disablePrefix) else { return nil }
            let key = String(name.dropFirst(Self.disablePrefix.count))
            return Feature.fromKey(key) == nil ? nil : key
        })
        lock.withLock { remoteDisabled = disabled }
        notify()
    }

    /// Nur für Tests: fester Wert, schlägt alles andere.
    public func setOverrideForTests(_ feature: Feature, _ value: Bool?) { lock.withLock { overrides[feature] = value } }

    @discardableResult
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(); lock.withLock { observers[id] = callback }; return id
    }
    public func removeObserver(_ id: UUID) { lock.withLock { observers[id] = nil } }

    private func notify() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in changes += 1; return Array(observers.values) }
        callbacks.forEach { $0() }
    }
}
