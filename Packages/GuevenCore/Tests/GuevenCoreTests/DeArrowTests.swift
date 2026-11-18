import XCTest
@testable import GuevenCore

final class DeArrowTests: XCTestCase {
    private func ok(_ json: String) -> FakeTransport.Step { .response(HTTPResponse(code: 200, body: Data(json.utf8))) }
    private func make(_ steps: [FakeTransport.Step], disk: BrandingDiskCache = InMemoryBrandingCache(), now: @escaping @Sendable () -> Int64 = { 1_000 })
        -> (DeArrowClient, FakeTransport) {
        let t = FakeTransport(steps)
        return (DeArrowClient(transport: t, disk: disk, nowMs: now), t)
    }

    func testPicksFirstUsableCommunityTitleAndThumbnail() async throws {
        let body = #"""
        {"titles":[{"title":"Original","original":true,"votes":9},{"title":">  Hübscher Titel ","votes":0},{"title":"Zweiter","votes":3}],
         "thumbnails":[{"timestamp":null,"original":true,"votes":1},{"timestamp":12.5,"votes":2}]}
        """#
        let (client, t) = make([ok(body)])
        let b = try await client.branding("abc")
        XCTAssertEqual(b.title, "Hübscher Titel")
        XCTAssertEqual(b.thumbnailUrl, "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=abc&time=12.5")
        XCTAssertEqual(t.requests[0].url.absoluteString, "https://sponsor.ajay.app/api/branding?videoID=abc")
    }

    func testDownvotedAreSkippedUnlessLocked() async throws {
        let body = #"{"titles":[{"title":"Schlecht","votes":-3},{"title":"Gesperrt","votes":-9,"locked":true}],"thumbnails":[{"timestamp":3,"votes":-1}]}"#
        let (client, _) = make([ok(body)])
        let b = try await client.branding("abc")
        XCTAssertEqual(b.title, "Gesperrt")
        XCTAssertNil(b.thumbnailUrl)
    }

    func testEmptyTitleAfterTrimIsIgnored() async throws {
        let (client, _) = make([ok(#"{"titles":[{"title":">   ","votes":1}]}"#)])
        let b = try await client.branding("abc")
        XCTAssertNil(b.title)
    }

    func testNotFoundAndGarbageFallBackToOriginal() async throws {
        let (a, _) = make([.response(HTTPResponse(code: 404))])
        let ra = try await a.branding("x")
        XCTAssertEqual(ra, .original)
        let (b, _) = make([ok("kein json")])
        let rb = try await b.branding("x")
        XCTAssertEqual(rb, .original)
    }

    func testNotFoundIsCachedButNetworkFailureIsNot() async throws {
        let (a, ta) = make([.response(HTTPResponse(code: 404))])
        _ = try await a.branding("x"); _ = try await a.branding("x")
        XCTAssertEqual(ta.requests.count, 1)
        let (b, tb) = make([.failure, ok(#"{"titles":[{"title":"Neu","votes":1}]}"#)])
        let first = try await b.branding("x")
        XCTAssertEqual(first, .original)
        let cachedAfterFailure = await b.cached("x")
        XCTAssertNil(cachedAfterFailure)
        let second = try await b.branding("x")
        XCTAssertEqual(second.title, "Neu")
        XCTAssertEqual(tb.requests.count, 2)
    }

    func testServerErrorIsNotStored() async throws {
        let disk = InMemoryBrandingCache()
        let (client, _) = make([.response(HTTPResponse(code: 503))], disk: disk)
        _ = try await client.branding("x")
        let count = await disk.count
        XCTAssertEqual(count, 0)
    }

    func testDiskCacheSurvivesNewClientWithinTtlButNotBeyond() async throws {
        let disk = InMemoryBrandingCache()
        let (a, _) = make([ok(#"{"titles":[{"title":"Gespeichert","votes":1}]}"#)], disk: disk, now: { 1_000 })
        _ = try await a.branding("x")
        let (b, tb) = make([], disk: disk, now: { 1_000 + DeArrowClient.diskTtlMs - 1 })
        let fromDisk = try await b.branding("x")
        XCTAssertEqual(fromDisk.title, "Gespeichert")
        XCTAssertEqual(tb.requests.count, 0)
        let (c, tc) = make([ok(#"{"titles":[{"title":"Frisch","votes":1}]}"#)], disk: disk, now: { 1_000 + DeArrowClient.diskTtlMs + 1 })
        let fresh = try await c.branding("x")
        XCTAssertEqual(fresh.title, "Frisch")
        XCTAssertEqual(tc.requests.count, 1)
    }

    func testRamCacheAnswersSynchronouslyAfterFirstFetch() async throws {
        let (client, _) = make([ok(#"{"titles":[{"title":"T","votes":1}]}"#)])
        let before = await client.cached("x")
        XCTAssertNil(before)
        _ = try await client.branding("x")
        let after = await client.cached("x")
        XCTAssertEqual(after?.title, "T")
    }

    func testAtMostFourRequestsInParallel() async throws {
        final class Probe: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock(); private var running = 0; private(set) var peak = 0
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                lock.withLock { running += 1; peak = max(peak, running) }
                try await Task.sleep(nanoseconds: 20_000_000)
                lock.withLock { running -= 1 }
                return HTTPResponse(code: 404)
            }
        }
        let probe = Probe()
        let client = DeArrowClient(transport: probe)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 { group.addTask { _ = try await client.branding("v\(i)") } }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(probe.peak, 4)
        XCTAssertGreaterThan(probe.peak, 1)
    }
}
