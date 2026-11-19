import XCTest
@testable import GuevenTube

final class FreshInstallTests: XCTestCase {
    @MainActor
    func testWipeRunsOnceAndSetsMarker() {
        let suite = "fresh-install-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.string(forKey: "install.marker.v1"))
        FreshInstall.wipeKeychainIfNeeded(defaults: defaults)
        let marker = defaults.string(forKey: "install.marker.v1")
        XCTAssertNotNil(marker, "erster Start setzt den Marker")
        FreshInstall.wipeKeychainIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "install.marker.v1"), marker, "zweiter Start löscht nichts und ändert den Marker nicht")
    }
}
