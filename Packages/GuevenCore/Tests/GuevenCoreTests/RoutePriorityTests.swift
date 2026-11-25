import XCTest
@testable import GuevenCore

final class RoutePriorityTests: XCTestCase {
    private func profile(_ id: String) -> PlayerClientProfile {
        PlayerClientProfile(id: id, label: id, clientName: id, clientNameId: 1, clientVersion: "1", userAgent: "ua")
    }
    private var routes: [PlaybackRoute] { ["a", "b", "c"].map { PlaybackRoute(profile: profile($0), useAccount: false) } }

    func testPinnedGoesFirstOthersKeepOrder() {
        XCTAssertEqual(PlaybackRoute.prioritize(routes, pinnedProfileId: "c").map(\.profile.id), ["c", "a", "b"])
    }
    func testNoPinKeepsOrder() {
        XCTAssertEqual(PlaybackRoute.prioritize(routes, pinnedProfileId: nil).map(\.profile.id), ["a", "b", "c"])
    }
    func testUnknownPinKeepsOrder() {
        XCTAssertEqual(PlaybackRoute.prioritize(routes, pinnedProfileId: "zzz").map(\.profile.id), ["a", "b", "c"])
    }
    func testPinKeepsBothAccountVariantsTogether() {
        let r = [PlaybackRoute(profile: profile("a"), useAccount: false), PlaybackRoute(profile: profile("b"), useAccount: true), PlaybackRoute(profile: profile("b"), useAccount: false)]
        XCTAssertEqual(PlaybackRoute.prioritize(r, pinnedProfileId: "b").map(\.profile.id), ["b", "b", "a"])
    }
}
