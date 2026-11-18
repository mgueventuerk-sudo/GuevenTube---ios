import Foundation
import GuevenCore

/// UserDefaults-Adapter für die Ablage-Protokolle aus GuevenCore. `UserDefaults` ist thread-sicher.
final class DefaultsStringStore: StringValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String
    init(defaults: UserDefaults = .standard, prefix: String = "gt.") { self.defaults = defaults; self.prefix = prefix }
    func string(_ key: String) -> String? { defaults.string(forKey: prefix + key) }
    func setString(_ value: String, for key: String) { defaults.set(value, forKey: prefix + key) }
}

final class DefaultsPreferredRouteStore: PreferredRouteStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "gt.route.preferred"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func preferred() -> String? { defaults.string(forKey: key) }
    func setPreferred(_ label: String?) {
        if let label { defaults.set(label, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Tagesnutzung des Kindermodus; Tag und Sekunden liegen zusammen in UserDefaults.
final class DefaultsKidsUsageStore: KidsUsageStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() async -> (day: Int, seconds: Int64) {
        (defaults.integer(forKey: "gt.kids.day"), Int64(defaults.integer(forKey: "gt.kids.seconds")))
    }
    func save(day: Int, seconds: Int64) async {
        defaults.set(day, forKey: "gt.kids.day")
        defaults.set(Int(seconds), forKey: "gt.kids.seconds")
    }
}
