import XCTest
@testable import GuevenCore

final class LinkPairUriTests: XCTestCase {
    private func uri(h: String = "192.168.1.20", p: String = "47001", fp: String = "AQIDBA", tk: String = "tok123", n: String? = "Wohnzimmer") -> String {
        var s = "gueventube://pair?h=\(h)&p=\(p)&fp=\(fp)&tk=\(tk)"
        if let n { s += "&n=\(n)" }
        return s
    }

    func testParsesValidLink() {
        let r = LinkPairUri.parse(uri())
        XCTAssertEqual(r?.host, "192.168.1.20")
        XCTAssertEqual(r?.port, 47001)
        XCTAssertEqual(r?.fingerprint, [1, 2, 3, 4])
        XCTAssertEqual(r?.token, "tok123")
        XCTAssertEqual(r?.name, "Wohnzimmer")
    }

    func testRejectsForeignSchemeAndHost() {
        XCTAssertNil(LinkPairUri.parse("https://pair?h=192.168.1.20&p=1&fp=AQID&tk=x"))
        XCTAssertNil(LinkPairUri.parse("gueventube://other?h=192.168.1.20&p=1&fp=AQID&tk=x"))
    }

    func testRejectsPublicAndNameHosts() {
        for h in ["8.8.8.8", "example.com", "172.32.0.1", "11.0.0.1", "192.169.0.1", "256.1.1.1", "1.2.3", "2001:db8::1"] {
            XCTAssertNil(LinkPairUri.parse(uri(h: h)), h)
        }
    }

    func testAcceptsLocalHosts() {
        for h in ["10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.0.1", "169.254.1.1", "127.0.0.1", "fe80::1", "fd12:3456::1", "::1", "[fe80::1]"] {
            XCTAssertNotNil(LinkPairUri.parse(uri(h: h)), h)
        }
    }

    func testRejectsBadIpv6() {
        for h in ["fe80::1::2", "fe80:1", ":::", "fe80::1%en0", "1:2:3:4:5:6:7:8:9", "fe80::12345"] {
            XCTAssertFalse(LinkPairUri.isLocalNetworkHost(h), h)
        }
    }

    func testRejectsBadPortFingerprintToken() {
        XCTAssertNil(LinkPairUri.parse(uri(p: "0")))
        XCTAssertNil(LinkPairUri.parse(uri(p: "70000")))
        XCTAssertNil(LinkPairUri.parse(uri(p: "abc")))
        XCTAssertNil(LinkPairUri.parse(uri(fp: "AQID=")))
        XCTAssertNil(LinkPairUri.parse(uri(fp: "A")))
        XCTAssertNil(LinkPairUri.parse(uri(tk: "")))
        XCTAssertNil(LinkPairUri.parse("gueventube://pair?h=192.168.1.20&p=1&fp=AQID"))
    }

    func testNameDefaultsAndIsTruncated() {
        XCTAssertEqual(LinkPairUri.parse(uri(n: nil))?.name, "Fernseher")
        XCTAssertEqual(LinkPairUri.parse(uri(n: "%20%20"))?.name, "Fernseher")
        XCTAssertEqual(LinkPairUri.parse(uri(n: String(repeating: "a", count: 100)))?.name.count, 64)
    }

    func testDescriptionHidesToken() {
        XCTAssertFalse(String(describing: LinkPairUri.parse(uri())!).contains("tok123"))
    }
}
