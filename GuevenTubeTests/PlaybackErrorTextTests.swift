import XCTest
import GuevenCore
@testable import GuevenTube

@MainActor
final class PlaybackErrorTextTests: XCTestCase {
    func testPaidVideoGetsGermanHintAboveTechnicalDetails() {
        let e = PlaybackUnavailableError(status: "UNPLAYABLE", message: "UNPLAYABLE — This video requires payment to watch")
        let text = AppModel.describe(e)
        XCTAssertTrue(text.hasPrefix("Dieser Film ist bei YouTube kostenpflichtig"), text)
        XCTAssertTrue(text.contains("Technische Details:"), text)
        XCTAssertTrue(text.contains("requires payment"), text)
    }

    func testUnknownReasonStaysTechnicalOnly() {
        let e = PlaybackUnavailableError(status: "UNPLAYABLE", message: "UNPLAYABLE — something else")
        XCTAssertEqual(AppModel.describe(e), "UNPLAYABLE — something else")
    }
}
