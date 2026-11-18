import XCTest
@testable import GuevenCore

/// Port von `PlayerClientsTest.kt` und `SearchFiltersTest.kt`.
final class ClientsTests: XCTestCase {
    private func client(_ body: JSON) -> JSON? { body.path("context", "client") }

    func testSamsungProfileMatchesYtDlpFix() {
        let tv = DefaultPlayerClients.tvSamsung
        XCTAssertEqual(tv.clientName, "TVHTML5")
        XCTAssertEqual(tv.clientNameId, 7)
        XCTAssertEqual(tv.clientVersion, "5.20260707")
        XCTAssertEqual(tv.deviceMake, "Samsung")
        XCTAssertEqual(tv.deviceModel, "UKS9800")
        XCTAssertEqual(tv.osName, "Tizen")
        XCTAssertEqual(tv.osVersion, "2.4.0")
        XCTAssertEqual(tv.userAgent, "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")
        XCTAssertTrue(tv.supportsOAuth)
        XCTAssertFalse(DefaultPlayerClients.visionOS.requiresJsPlayer)
        XCTAssertTrue(DefaultPlayerClients.web.requiresPoToken)
    }

    func testRequestBodyCarriesDeviceFieldsAndPayload() {
        let body = buildRequestBody(client: .of(DefaultPlayerClients.tvSamsung), visitorData: "VISITOR", hl: "de", gl: "DE",
                                    payload: [("videoId", "abc")])
        let c = client(body)
        XCTAssertEqual(c.str("clientName"), "TVHTML5")
        XCTAssertEqual(c.str("deviceMake"), "Samsung")
        XCTAssertEqual(c.str("osName"), "Tizen")
        XCTAssertEqual(c.str("visitorData"), "VISITOR")
        XCTAssertEqual(body.str("videoId"), "abc")
        XCTAssertNil(body.path("context", "thirdParty"))
        XCTAssertEqual(body.path("context", "user").bool("lockedSafetyMode"), false)
    }

    func testEmbeddedBodyHasThirdPartyAndEmbedScreen() {
        let body = buildRequestBody(client: .of(DefaultPlayerClients.webEmbedded), visitorData: nil, hl: "de", gl: "DE")
        XCTAssertEqual(body.path("context", "thirdParty").str("embedUrl"), "https://www.google.com/")
        XCTAssertEqual(client(body).str("clientScreen"), "EMBED")
        XCTAssertNil(client(body)?.objectValue?["visitorData"])
        XCTAssertNil(client(body)?.objectValue?["deviceMake"])
    }

    func testBodySerializesInOrderAndEscapes() {
        let body = buildRequestBody(client: .of(.tvhtml5, version: "1"), visitorData: nil, hl: "de", gl: "DE",
                                    payload: [("query", "a\"b\\c\n\u{1}ä")])
        let text = body.serialized()
        XCTAssertTrue(text.hasPrefix(#"{"context":{"client":{"clientName":"TVHTML5","clientVersion":"1","hl":"de","gl":"DE","userAgent":"#))
        XCTAssertTrue(text.hasSuffix(#","query":"a\"b\\c\n\u0001ä"}"#))
        XCTAssertEqual(try JSONParser.parse(text), body, "Rundlauf")
    }

    func testParsesProfileFileAndIgnoresUnknownKeys() throws {
        let profiles = try PlayerClientProfileParser.parse(#"""
        {"version":2,"clients":[
          {"id":"tv_x","label":"TV X","clientName":"TVHTML5","clientNameId":7,"clientVersion":"5.1",
           "userAgent":"UA","deviceMake":"Foo","supportsOAuth":true,"neu":"egal"},
          {"id":"off","label":"Aus","clientName":"WEB","clientNameId":1,"clientVersion":"2.0","userAgent":"UA","enabled":false}
        ]}
        """#)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].deviceMake, "Foo")
        XCTAssertTrue(profiles[0].supportsOAuth)
        XCTAssertFalse(profiles[1].enabled)
    }

    func testRejectsInvalidProfileFiles() {
        let invalid = [
            #"{"clients":[]}"#,
            #"{"clients":[{"id":"a","label":"A","clientName":"WEB","clientNameId":1,"clientVersion":"2","userAgent":"UA","enabled":false}]}"#,
            #"{"clients":[{"id":"a","label":"A","clientName":"WEB","clientNameId":1,"clientVersion":"2","userAgent":" "}]}"#,
            #"{"clients":[{"id":"","label":"A","clientName":"WEB","clientNameId":1,"clientVersion":"2","userAgent":"UA"}]}"#,
            "kein json",
        ]
        for text in invalid { XCTAssertThrowsError(try PlayerClientProfileParser.parse(text), text) }
    }

    func testSearchFilterParams() {
        XCTAssertNil(SearchFilters().toParams())
        XCTAssertEqual(SearchFilters(type: .video).toParams(), "EgIQAQ==")
        XCTAssertEqual(SearchFilters(sort: .date).toParams(), "CAI=")
        XCTAssertEqual(SearchFilters(sort: .date, type: .video).toParams(), "CAISAhAB")
        XCTAssertEqual(SearchFilters(date: .week, type: .video).toParams(), "EgQIAxAB")
        XCTAssertEqual(SearchFilters(liveOnly: true).toParams(), "EgJAAQ==")
    }
}
