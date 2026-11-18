import Foundation

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case av1 = "AV1", vp9 = "VP9", hevc = "HEVC", avc = "AVC"
    public var displayName: String { self == .avc ? "H.264/AVC" : rawValue }
    /// Verbindliche Priorität bei gleicher Auflösung.
    public static let priority: [VideoCodec] = [.av1, .vp9, .hevc, .avc]
}

public enum ResolutionTier: String, Codable, Sendable, CaseIterable {
    case sd480 = "SD_480", hd720 = "HD_720", fhd1080 = "FHD_1080", qhd1440 = "QHD_1440", uhd2160 = "UHD_2160", uhd4320 = "UHD_4320"
    public var label: String {
        switch self {
        case .sd480: return "480p"; case .hd720: return "720p"; case .fhd1080: return "1080p"
        case .qhd1440: return "1440p"; case .uhd2160: return "2160p (4K)"; case .uhd4320: return "4320p (8K)"
        }
    }
    public var height: Int { switch self { case .sd480: 480; case .hd720: 720; case .fhd1080: 1080; case .qhd1440: 1440; case .uhd2160: 2160; case .uhd4320: 4320 } }
}

public enum FrameRateMatching: String, Codable, Sendable, CaseIterable {
    case off = "OFF", seamlessOnly = "SEAMLESS_ONLY", always = "ALWAYS"
}

public enum SubtitleFormat: String, Codable, Sendable, CaseIterable {
    case webvtt = "WEBVTT", ttml = "TTML"
    public var queryValue: String { self == .webvtt ? "vtt" : "ttml" }
}

public enum SubtitleSize: String, Codable, Sendable, CaseIterable {
    case small = "SMALL", normal = "NORMAL", large = "LARGE"
    public var fractionalTextSize: Float { switch self { case .small: 0.045; case .normal: 0.0533; case .large: 0.07 } }
}

/// Alle nicht geheimen Einstellungen. Nur-TV/Android-Optionen (Cronet, Fokusrahmen, Ambient, YouTube-App-Kopplung) entfallen.
public struct AppSettings: Equatable, Sendable {
    public var sponsorBlockEnabled = true
    public var skipModes: [SponsorCategory: SkipMode] = Dictionary(uniqueKeysWithValues: SponsorCategory.allCases.map { ($0, $0.defaultMode) })
    public var deArrowEnabled = false
    /// `nil` = höchste verfügbare Auflösung.
    public var maxResolution: ResolutionTier?
    /// `nil` = automatische Codec-Priorität.
    public var pinnedCodec: VideoCodec?
    public var hdrEnabled = true
    public var frameRateMatching: FrameRateMatching = .seamlessOnly
    public var defaultPlaybackSpeed: Float = 1.0
    /// `nil` = Untertitel aus.
    public var subtitleLanguage: String?
    public var subtitleFormat: SubtitleFormat = .webvtt
    public var subtitleSize: SubtitleSize = .normal
    /// `nil` = Originalspur.
    public var audioLanguage: String?
    public var clientProfilesUrl: String?
    public var remoteConfigUrl: String?
    public var subscriptionSort: SubscriptionSort = .youtube
    public var instantStart = true
    public var loudnessNormalization = true
    public var skipSilence = false
    public var statsOverlay = false
    public var dailySelfTest = true
    public var onboardingDone = false
    public var homeSubscriptionsFirst = true
    public var hideWatched = true
    public var showDislikes = false
    public var backgroundPlayback = true
    public var dataSaver = true
    public var autoplay = true
    public var deviceLock = false
    public var newVideoNotifications = true
    public var kidsMode = false
    public var kidsDailyLimitMinutes = 0
    public var kidsBedtimeHour = 0
    /// SYSTEM / DARK / BLACK (DYNAMIC gibt es nur unter Android).
    public var mobileTheme = "SYSTEM"
    public var haptics = true

    public init() {}
    public func skipMode(_ category: SponsorCategory) -> SkipMode { skipModes[category] ?? category.defaultMode }
}

/// Schlüssel wie in Android (DataStore), damit Sicherungen lesbar bleiben.
enum SettingsKey {
    static let sponsorBlock = "sponsorblock.enabled", deArrow = "dearrow.enabled", maxResolution = "video.max_resolution"
    static let pinnedCodec = "video.pinned_codec", hdr = "video.hdr", frameRate = "video.frame_rate_matching", speed = "playback.speed"
    static let subtitleLanguage = "subtitles.language", subtitleFormat = "subtitles.format", subtitleSize = "subtitles.size"
    static let audioLanguage = "audio.language", clientProfilesUrl = "playback.client_profiles_url", remoteConfigUrl = "playback.remote_config_url"
    static let subscriptionSort = "browse.subscription_sort", instantStart = "playback.instant_start", loudness = "playback.loudness_normalization"
    static let skipSilence = "playback.skip_silence", statsOverlay = "playback.stats_overlay", selfTest = "diagnostics.daily_self_test"
    static let onboardingDone = "ui.onboarding_done", homeSubsFirst = "home.subscriptions_first", hideWatched = "home.hide_watched"
    static let showDislikes = "community.show_dislikes", backgroundPlayback = "mobile.background_playback", dataSaver = "mobile.data_saver"
    static let autoplay = "playback.autoplay", deviceLock = "mobile.device_lock", newVideoNotifications = "mobile.new_video_notifications"
    static let kidsMode = "profile.kids_mode", kidsLimit = "profile.kids_daily_limit_min", kidsBedtime = "profile.kids_bedtime_hour"
    static let mobileTheme = "mobile.theme", haptics = "mobile.haptics"
    static func skipMode(_ c: SponsorCategory) -> String { "sponsorblock.mode.\(c.apiKey)" }
}

/// Einstellungen in einer kleinen JSON-Datei (Schlüssel → Text). Unbekannte oder kaputte Werte fallen auf den Standard zurück,
/// eine beschädigte Datei beginnt leer.
public actor SettingsStore {
    public static let minSpeed: Float = 0.25
    public static let maxSpeed: Float = 3.0
    /// 0,25x bis 3,0x in 0,25er-Schritten.
    public static let playbackSpeeds: [Float] = (1...12).map { Float($0) * 0.25 }

    private let file: URL?
    private var raw: [String: String]
    private var listeners: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(file: URL? = nil) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode([String: String].self, from: data) { raw = d } else { raw = [:] }
    }

    public func current() -> AppSettings { Self.parse(raw) }
    public static func defaults() -> AppSettings { AppSettings() }

    /// Liefert sofort den aktuellen Stand und danach jede Änderung (ohne Wiederholungen).
    public func updates() -> AsyncStream<AppSettings> {
        let id = UUID()
        return AsyncStream { c in
            c.yield(current()); listeners[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        }
    }
    private func drop(_ id: UUID) { listeners[id] = nil }

    /// Ändert beliebige Felder in einem Schritt.
    public func update(_ change: (inout AppSettings) -> Void) {
        let before = current(); var s = before; change(&s)
        s.defaultPlaybackSpeed = min(max(s.defaultPlaybackSpeed, Self.minSpeed), Self.maxSpeed)
        s.kidsDailyLimitMinutes = min(max(s.kidsDailyLimitMinutes, 0), 24 * 60)
        s.kidsBedtimeHour = min(max(s.kidsBedtimeHour, 0), 23)
        for u in [\AppSettings.clientProfilesUrl, \AppSettings.remoteConfigUrl] {
            if let v = s[keyPath: u]?.trimmingCharacters(in: .whitespacesAndNewlines) { s[keyPath: u] = v.isEmpty ? nil : v }
        }
        raw = Self.serialize(s)
        persist()
        let after = current()
        if after != before { listeners.values.forEach { $0.yield(after) } }
    }

    public func resetAll() {
        let before = current(); raw = [:]; persist()
        let after = current()
        if after != before { listeners.values.forEach { $0.yield(after) } }
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(raw).write(to: file, options: .atomic)
        } catch { /* bleibt im Speicher */ }
    }

    // MARK: Umwandlung

    static func parse(_ r: [String: String]) -> AppSettings {
        var s = AppSettings()
        func b(_ k: String, _ d: Bool) -> Bool { r[k].flatMap { $0 == "true" ? true : $0 == "false" ? false : nil } ?? d }
        func i(_ k: String, _ d: Int) -> Int { r[k].flatMap { Int($0) } ?? d }
        func e<T: RawRepresentable>(_ k: String, _ t: T.Type) -> T? where T.RawValue == String { r[k].flatMap { T(rawValue: $0) } }
        s.sponsorBlockEnabled = b(SettingsKey.sponsorBlock, true)
        for c in SponsorCategory.allCases { s.skipModes[c] = e(SettingsKey.skipMode(c), SkipMode.self) ?? c.defaultMode }
        s.deArrowEnabled = b(SettingsKey.deArrow, false)
        s.maxResolution = e(SettingsKey.maxResolution, ResolutionTier.self)
        s.pinnedCodec = e(SettingsKey.pinnedCodec, VideoCodec.self)
        s.hdrEnabled = b(SettingsKey.hdr, true)
        s.frameRateMatching = e(SettingsKey.frameRate, FrameRateMatching.self) ?? .seamlessOnly
        if let v = r[SettingsKey.speed].flatMap({ Float($0) }), v.isFinite { s.defaultPlaybackSpeed = min(max(v, SettingsStore.minSpeed), SettingsStore.maxSpeed) }
        s.subtitleLanguage = r[SettingsKey.subtitleLanguage]
        s.subtitleFormat = e(SettingsKey.subtitleFormat, SubtitleFormat.self) ?? .webvtt
        s.subtitleSize = e(SettingsKey.subtitleSize, SubtitleSize.self) ?? .normal
        s.audioLanguage = r[SettingsKey.audioLanguage]
        s.clientProfilesUrl = r[SettingsKey.clientProfilesUrl]
        s.remoteConfigUrl = r[SettingsKey.remoteConfigUrl]
        s.subscriptionSort = e(SettingsKey.subscriptionSort, SubscriptionSort.self) ?? .youtube
        s.instantStart = b(SettingsKey.instantStart, true)
        s.loudnessNormalization = b(SettingsKey.loudness, true)
        s.skipSilence = b(SettingsKey.skipSilence, false)
        s.statsOverlay = b(SettingsKey.statsOverlay, false)
        s.dailySelfTest = b(SettingsKey.selfTest, true)
        s.onboardingDone = b(SettingsKey.onboardingDone, false)
        s.homeSubscriptionsFirst = b(SettingsKey.homeSubsFirst, true)
        s.hideWatched = b(SettingsKey.hideWatched, true)
        s.showDislikes = b(SettingsKey.showDislikes, false)
        s.backgroundPlayback = b(SettingsKey.backgroundPlayback, true)
        s.dataSaver = b(SettingsKey.dataSaver, true)
        s.autoplay = b(SettingsKey.autoplay, true)
        s.deviceLock = b(SettingsKey.deviceLock, false)
        s.newVideoNotifications = b(SettingsKey.newVideoNotifications, true)
        s.kidsMode = b(SettingsKey.kidsMode, false)
        s.kidsDailyLimitMinutes = i(SettingsKey.kidsLimit, 0)
        s.kidsBedtimeHour = i(SettingsKey.kidsBedtime, 0)
        let theme = r[SettingsKey.mobileTheme] ?? "SYSTEM"
        s.mobileTheme = ["SYSTEM", "DARK", "BLACK"].contains(theme) ? theme : "SYSTEM"
        s.haptics = b(SettingsKey.haptics, true)
        return s
    }

    /// Schreibt nur Abweichungen vom Standard – wie ein leerer DataStore nach „Zurücksetzen“.
    static func serialize(_ s: AppSettings) -> [String: String] {
        let d = AppSettings(); var r: [String: String] = [:]
        func put<T: Equatable>(_ k: String, _ v: T, _ dv: T, _ str: (T) -> String) { if v != dv { r[k] = str(v) } }
        func bool(_ k: String, _ v: Bool, _ dv: Bool) { put(k, v, dv) { $0 ? "true" : "false" } }
        bool(SettingsKey.sponsorBlock, s.sponsorBlockEnabled, d.sponsorBlockEnabled)
        for c in SponsorCategory.allCases where s.skipMode(c) != c.defaultMode { r[SettingsKey.skipMode(c)] = s.skipMode(c).rawValue }
        bool(SettingsKey.deArrow, s.deArrowEnabled, d.deArrowEnabled)
        if let v = s.maxResolution { r[SettingsKey.maxResolution] = v.rawValue }
        if let v = s.pinnedCodec { r[SettingsKey.pinnedCodec] = v.rawValue }
        bool(SettingsKey.hdr, s.hdrEnabled, d.hdrEnabled)
        put(SettingsKey.frameRate, s.frameRateMatching, d.frameRateMatching) { $0.rawValue }
        put(SettingsKey.speed, s.defaultPlaybackSpeed, d.defaultPlaybackSpeed) { String($0) }
        if let v = s.subtitleLanguage { r[SettingsKey.subtitleLanguage] = v }
        put(SettingsKey.subtitleFormat, s.subtitleFormat, d.subtitleFormat) { $0.rawValue }
        put(SettingsKey.subtitleSize, s.subtitleSize, d.subtitleSize) { $0.rawValue }
        if let v = s.audioLanguage { r[SettingsKey.audioLanguage] = v }
        if let v = s.clientProfilesUrl { r[SettingsKey.clientProfilesUrl] = v }
        if let v = s.remoteConfigUrl { r[SettingsKey.remoteConfigUrl] = v }
        put(SettingsKey.subscriptionSort, s.subscriptionSort, d.subscriptionSort) { $0.rawValue }
        bool(SettingsKey.instantStart, s.instantStart, d.instantStart)
        bool(SettingsKey.loudness, s.loudnessNormalization, d.loudnessNormalization)
        bool(SettingsKey.skipSilence, s.skipSilence, d.skipSilence)
        bool(SettingsKey.statsOverlay, s.statsOverlay, d.statsOverlay)
        bool(SettingsKey.selfTest, s.dailySelfTest, d.dailySelfTest)
        bool(SettingsKey.onboardingDone, s.onboardingDone, d.onboardingDone)
        bool(SettingsKey.homeSubsFirst, s.homeSubscriptionsFirst, d.homeSubscriptionsFirst)
        bool(SettingsKey.hideWatched, s.hideWatched, d.hideWatched)
        bool(SettingsKey.showDislikes, s.showDislikes, d.showDislikes)
        bool(SettingsKey.backgroundPlayback, s.backgroundPlayback, d.backgroundPlayback)
        bool(SettingsKey.dataSaver, s.dataSaver, d.dataSaver)
        bool(SettingsKey.autoplay, s.autoplay, d.autoplay)
        bool(SettingsKey.deviceLock, s.deviceLock, d.deviceLock)
        bool(SettingsKey.newVideoNotifications, s.newVideoNotifications, d.newVideoNotifications)
        bool(SettingsKey.kidsMode, s.kidsMode, d.kidsMode)
        put(SettingsKey.kidsLimit, s.kidsDailyLimitMinutes, d.kidsDailyLimitMinutes) { String($0) }
        put(SettingsKey.kidsBedtime, s.kidsBedtimeHour, d.kidsBedtimeHour) { String($0) }
        put(SettingsKey.mobileTheme, s.mobileTheme, d.mobileTheme) { $0 }
        bool(SettingsKey.haptics, s.haptics, d.haptics)
        return r
    }
}
