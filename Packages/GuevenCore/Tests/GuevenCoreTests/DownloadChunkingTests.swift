import XCTest
@testable import GuevenCore

final class DownloadChunkingTests: XCTestCase {
    func testChunksCoverTheWholeFileWithoutGapsOrOverlap() {
        let total: Int64 = 25_000_000
        var offset: Int64 = 0, covered: Int64 = 0, count = 0
        while let r = DownloadChunking.range(offset: offset, total: total) {
            XCTAssertEqual(r.start, offset)
            XCTAssertLessThan(r.end, total)
            covered += r.end - r.start + 1
            offset = r.end + 1; count += 1
        }
        XCTAssertEqual(covered, total)
        XCTAssertEqual(count, 3)
    }

    func testNoRangeWhenDoneOrSizeUnknown() {
        XCTAssertNil(DownloadChunking.range(offset: 100, total: 100))
        XCTAssertNil(DownloadChunking.range(offset: 0, total: 0))
        XCTAssertNil(DownloadChunking.range(offset: -1, total: 100))
    }

    func testSmallOrUnknownSizesAreNotChunked() {
        XCTAssertFalse(DownloadChunking.shouldChunk(total: nil))
        XCTAssertFalse(DownloadChunking.shouldChunk(total: DownloadChunking.chunkSize))
        XCTAssertTrue(DownloadChunking.shouldChunk(total: DownloadChunking.chunkSize + 1))
    }
}
