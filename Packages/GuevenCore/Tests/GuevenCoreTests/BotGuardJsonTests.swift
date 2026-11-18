import XCTest
@testable import GuevenCore

final class BotGuardJsonTests: XCTestCase {
    private func scramble(_ text: String) -> String {
        Data(Array(text.utf8).map { $0 &- 97 }).base64EncodedString()
    }

    func testChallengeInPlainFormIsReshaped() throws {
        let raw = #"[["msg",["script();"],["//url"],"hash","PROGRAM","globalVm",null,"blob"]]"#
        let out = try BotGuardJson.parseChallengeData(raw)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["program"] as? String, "PROGRAM")
        XCTAssertEqual(obj["globalName"] as? String, "globalVm")
        XCTAssertEqual(obj["messageId"] as? String, "msg")
        XCTAssertEqual(obj["clientExperimentsStateBlob"] as? String, "blob")
        let interpreter = try XCTUnwrap(obj["interpreterJavascript"] as? [String: Any])
        XCTAssertEqual(interpreter["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String, "script();")
        XCTAssertEqual(interpreter["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] as? String, "//url")
    }

    func testScrambledChallengeIsDecoded() throws {
        let inner = #"["m",["s();"],["u"],"h","P","g",null,"b"]"#
        let raw = "[null,\"\(scramble(inner))\"]"
        let out = try BotGuardJson.parseChallengeData(raw)
        XCTAssertTrue(out.contains("\"program\":\"P\""), out)
        XCTAssertTrue(out.contains("s();"), out)
    }

    func testChallengeWithoutScriptIsRejected() {
        XCTAssertThrowsError(try BotGuardJson.parseChallengeData(#"[["m",[],null,"h","P","g"]]"#))
    }

    func testIntegrityTokenParsesBytesAndLifetime() throws {
        let b64 = Data([1, 2, 250]).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let parsed = try BotGuardJson.parseIntegrityToken("[\"\(b64)\",43200,null]")
        XCTAssertEqual(parsed.bytes, [1, 2, 250])
        XCTAssertEqual(parsed.lifetimeSeconds, 43200)
        XCTAssertEqual(try BotGuardJson.parseIntegrityToken("[\"\(b64)\"]").lifetimeSeconds, 3600)
    }

    func testU8ToBase64IsUrlSafe() throws {
        XCTAssertEqual(try BotGuardJson.u8ToBase64("251,255,191"), "-_-_")
        XCTAssertThrowsError(try BotGuardJson.u8ToBase64("1,300"))
        XCTAssertThrowsError(try BotGuardJson.u8ToBase64(""))
    }

    func testIdentifierSafety() {
        XCTAssertTrue(BotGuardJson.isSafeIdentifier("dQw4w9WgXcQ"))
        XCTAssertTrue(BotGuardJson.isSafeIdentifier("Cgt4YWJj%3D"))
        XCTAssertFalse(BotGuardJson.isSafeIdentifier("a\"b"))
        XCTAssertFalse(BotGuardJson.isSafeIdentifier(""))
        XCTAssertFalse(BotGuardJson.isSafeIdentifier(String(repeating: "a", count: 513)))
    }
}
