import XCTest
@testable import GuevenCore

final class DurationTests: XCTestCase {
    func testParsesClock() {
        XCTAssertEqual(parseClock("4:05"), 245)
        XCTAssertEqual(parseClock("1:02:03"), 3723)
        XCTAssertNil(parseClock("x:1"))
        XCTAssertNil(parseClock(""))
    }
}
