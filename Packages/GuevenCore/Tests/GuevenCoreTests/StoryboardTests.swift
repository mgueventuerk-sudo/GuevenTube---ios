import XCTest
@testable import GuevenCore

final class StoryboardTests: XCTestCase {
    private let spec = "https://i.ytimg.com/sb/ID/storyboard3_L$L/$N.jpg?sqp=ABC|48#27#100#10#10#0#default#rs$AAA|80#45#100#10#10#0#M$M#rs$BBB|160#90#50#5#5#2000#M$M#sig$X"

    func testParseLevels() {
        let sb = Storyboard.parse(spec)!
        XCTAssertEqual(sb.levels.count, 3)
        XCTAssertEqual(sb.levels[0].frameWidth, 48); XCTAssertEqual(sb.levels[0].name, "default"); XCTAssertEqual(sb.levels[0].signature, "rs$AAA")
        XCTAssertEqual(sb.levels[2].intervalMs, 2000); XCTAssertEqual(sb.levels[2].columns, 5)
    }

    func testParseRejectsBadInput() {
        XCTAssertNil(Storyboard.parse(nil)); XCTAssertNil(Storyboard.parse("  ")); XCTAssertNil(Storyboard.parse("https://x/y"))
        XCTAssertNil(Storyboard.parse("http://x/$N|48#27#100#10#10#0#d"))                 // kein https
        XCTAssertNil(Storyboard.parse("https://x/$N|48#27#0#10#10#0#d"))                  // 0 Bilder
        XCTAssertNil(Storyboard.parse("https://x/$N|48#27#100#10#d"))                     // zu wenige Felder
        XCTAssertEqual(Storyboard.parse("https://x/$N|48#27#100#10#10#0#d|kaputt")?.levels.count, 1)
        XCTAssertNil(Storyboard.parse("https://x/$N|48#27#100#10#10#0#d#  ")!.levels[0].signature)
    }

    func testLevelChoice() {
        let sb = Storyboard.parse(spec)!
        XCTAssertEqual(sb.level(minWidth: 160)?.frameWidth, 80 + 80)                       // erste Stufe ≥ 160 px
        XCTAssertEqual(sb.level(minWidth: 50)?.frameWidth, 80)
        XCTAssertEqual(sb.level(minWidth: 1000)?.frameWidth, 160)                          // sonst die größte
        XCTAssertNil(Storyboard.parse("https://x/$N|48#27#1#1#1#0#d")?.level())            // 1 Bild ist unbrauchbar
    }

    func testFrameAtEvenSpread() {
        let sb = Storyboard.parse("https://x/L$L/$N.jpg|80#45#100#10#10#0#M$M#sig")!
        let f = sb.frameAt(positionMs: 55_000, durationMs: 100_000)!           // Intervall 1000 ms → Bild 55
        XCTAssertEqual(f.sheetUrl, "https://x/L0/M0.jpg?sigh=sig"); XCTAssertEqual(f.column, 5); XCTAssertEqual(f.row, 5)
        XCTAssertNil(sb.frameAt(positionMs: 5, durationMs: 0))
    }

    func testFrameAtSecondSheetAndClamping() {
        let sb = Storyboard.parse("https://x/L$L/$N.jpg?a=b|80#45#100#5#5#2000#M$M")!
        let f = sb.frameAt(positionMs: 60_000, durationMs: 0)!                  // Index 30 → Bogen 1, Stelle 5
        XCTAssertEqual(f.sheetUrl, "https://x/L0/M1.jpg?a=b"); XCTAssertEqual([f.column, f.row], [0, 1])
        let last = sb.frameAt(positionMs: 10_000_000, durationMs: 0)!           // auf 99 begrenzt → Bogen 3, Stelle 24
        XCTAssertEqual(last.sheetUrl, "https://x/L0/M3.jpg?a=b"); XCTAssertEqual([last.column, last.row], [4, 4])
        let first = sb.frameAt(positionMs: -5, durationMs: 0)!; XCTAssertEqual([first.column, first.row], [0, 0])
    }

    func testLevelIndexCountsAllLevels() {
        let sb = Storyboard.parse("https://x/L$L/$N.jpg|48#27#1#1#1#0#a|80#45#10#5#2#1000#b")!   // erste Stufe unbrauchbar
        XCTAssertEqual(sb.frameAt(positionMs: 0, durationMs: 0)?.sheetUrl, "https://x/L1/b.jpg")
    }

    func testRepositoryUsesCacheThenFetchAndRemembersMisses() async {
        final class C: @unchecked Sendable { var fetches = 0; var cached: String? }
        let c = C()
        let repo = StoryboardRepository(cachedSpec: { _ in c.cached }, fetchSpec: { _ in c.fetches += 1; return .some(nil) })
        let none = await repo.storyboard("a"); XCTAssertNil(none)
        _ = await repo.storyboard("a"); XCTAssertEqual(c.fetches, 1)               // Fehlschlag gemerkt
        c.cached = spec
        let hit = await StoryboardRepository(cachedSpec: { _ in c.cached }, fetchSpec: { _ in c.fetches += 1; return .none }).storyboard("b")
        XCTAssertNotNil(hit); XCTAssertEqual(c.fetches, 1)                          // aus der Player-Antwort, ohne Netz
    }

    func testRepositoryFetchSuccessErrorAndNoProfile() async {
        struct E: Error {}
        final class C: @unchecked Sendable { var fetches = 0 }
        let c = C(); let spec = self.spec
        let ok = StoryboardRepository(cachedSpec: { _ in nil }, fetchSpec: { _ in c.fetches += 1; return .some(spec) })
        let a = await ok.storyboard("v"); XCTAssertNotNil(a); _ = await ok.storyboard("v"); XCTAssertEqual(c.fetches, 1)
        let bad = StoryboardRepository(cachedSpec: { _ in nil }, fetchSpec: { _ in c.fetches += 1; throw E() })
        let b = await bad.storyboard("v"); XCTAssertNil(b); _ = await bad.storyboard("v"); XCTAssertEqual(c.fetches, 2)
        let np = StoryboardRepository(cachedSpec: { _ in nil }, fetchSpec: { _ in c.fetches += 1; return .none })
        let n = await np.storyboard("v"); XCTAssertNil(n); _ = await np.storyboard("v"); XCTAssertEqual(c.fetches, 3)
    }
}
