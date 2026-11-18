import XCTest
@testable import GuevenCore

/// Notschalter-System: Standard → Nutzerwahl → Fernabschaltung (nur aus, nie an).
final class FeatureFlagsTests: XCTestCase {
    private func make() -> FeatureFlags { FeatureFlags(store: InMemoryFeatureChoiceStore()) }

    func testDefaultsApplyWithoutChoice() {
        let f = make()
        for feature in Feature.allCases { XCTAssertEqual(f.isEnabled(feature), feature.defaultOn, feature.key) }
    }

    func testExperimentalFeaturesStartOff() {
        let f = make()
        XCTAssertFalse(f.isEnabled(.autoPoToken))
        XCTAssertFalse(f.isEnabled(.voiceCommands))
        XCTAssertTrue(f.isEnabled(.music))
    }

    func testUserChoiceOverridesDefaultAndResets() {
        let f = make()
        f.setUserChoice(.autoPoToken, enabled: true)
        XCTAssertTrue(f.isEnabled(.autoPoToken))
        f.setUserChoice(.music, enabled: false)
        XCTAssertFalse(f.isEnabled(.music))
        f.resetUserChoices()
        XCTAssertFalse(f.isEnabled(.autoPoToken))
        XCTAssertTrue(f.isEnabled(.music))
    }

    func testRemoteCanOnlyDisable() {
        let f = make()
        f.setUserChoice(.autoPoToken, enabled: true)
        f.applyRemote(["disable.auto_potoken": true, "disable.webp_thumbnails": true])
        XCTAssertFalse(f.isEnabled(.autoPoToken), "Fern-Abschaltung schlägt Nutzerwahl")
        XCTAssertFalse(f.isEnabled(.webpThumbnails))
        XCTAssertTrue(f.isRemotelyDisabled(.autoPoToken))
        f.applyRemote(["disable.voice_commands": false, "enable.voice_commands": true, "voice_commands": true])
        XCTAssertFalse(f.isEnabled(.voiceCommands), "Einschalten aus der Ferne ist wirkungslos")
        XCTAssertTrue(f.isEnabled(.autoPoToken), "Nach Aufhebung wieder Nutzerwahl")
    }

    func testUnknownRemoteKeysAreIgnored() {
        let f = make()
        f.applyRemote(["disable.gibt_es_nicht": true])
        for feature in Feature.allCases { XCTAssertFalse(f.isRemotelyDisabled(feature)) }
    }

    func testObserversAreNotifiedAndChangesCount() {
        let f = make()
        let box = CounterBox()
        let id = f.observe { box.increment() }
        f.setUserChoice(.music, enabled: false); f.applyRemote([:]); f.resetUserChoices()
        XCTAssertEqual(box.value, 3)
        XCTAssertEqual(f.changes, 3)
        f.removeObserver(id)
        f.setUserChoice(.music, enabled: true)
        XCTAssertEqual(box.value, 3)
    }

    func testKeysAreUniqueAndStableForRemoteConfig() {
        XCTAssertEqual(Set(Feature.allCases.map(\.key)).count, Feature.allCases.count)
        XCTAssertEqual(Feature.fromKey("music"), .music)
        XCTAssertNil(Feature.fromKey("cronet_api"))
    }

    func testUserDefaultsStoreRoundTrip() {
        let suite = "ff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsFeatureChoiceStore(defaults: defaults)
        XCTAssertNil(store.choice(for: "music"))
        store.setChoice(false, for: "music")
        XCTAssertEqual(store.choice(for: "music"), false)
        store.removeAll(keys: ["music"])
        XCTAssertNil(store.choice(for: "music"))
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
