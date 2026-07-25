import XCTest
@testable import AwayView

final class CIDRMatcherTests: XCTestCase {
    let tailscale = CIDRMatcher(CIDRMatcher.defaultCIDRs)

    func testIPv4InRange() {
        XCTAssertTrue(tailscale.matches("100.64.0.1"))
        XCTAssertTrue(tailscale.matches("100.99.1.2"))
        XCTAssertTrue(tailscale.matches("100.127.255.255"))
    }

    func testIPv4OutOfRange() {
        XCTAssertFalse(tailscale.matches("100.63.255.255"))
        XCTAssertFalse(tailscale.matches("100.128.0.1"))
        XCTAssertFalse(tailscale.matches("192.168.1.10"))
        XCTAssertFalse(tailscale.matches("100.64.0"))       // 不完全な v4
        XCTAssertFalse(tailscale.matches(""))
        XCTAssertFalse(tailscale.matches("100.64.0.999"))
    }

    func testIPv6Range() {
        XCTAssertTrue(tailscale.matches("fd7a:115c:a1e0::1"))
        XCTAssertTrue(tailscale.matches("FD7A:115C:A1E0:AB12:4843:CD96:6265:B2B5"))
        XCTAssertFalse(tailscale.matches("fd7a:115c:a1e1::1"))
        XCTAssertFalse(tailscale.matches("fe80::1"))
        XCTAssertFalse(tailscale.matches("::1"))
    }

    func testCustomRuleAndExactHost() {
        let m = CIDRMatcher(["192.168.1.0/24", "10.0.0.1/32"])
        XCTAssertTrue(m.matches("192.168.1.42"))
        XCTAssertFalse(m.matches("192.168.2.1"))
        XCTAssertTrue(m.matches("10.0.0.1"))
        XCTAssertFalse(m.matches("10.0.0.2"))
    }

    func testInvalidEntriesAreIgnored() {
        let m = CIDRMatcher(["not-a-cidr", "100.64.0.0/10", "1.2.3.4/33", "1.2.3.4"])
        XCTAssertTrue(m.matches("100.99.1.2"))    // 有効エントリは生きる
        XCTAssertFalse(m.matches("1.2.3.4"))      // prefix なし・不正はマッチ源にならない
    }

    func testEmptyListMatchesNothing() {
        let m = CIDRMatcher([])
        XCTAssertFalse(m.matches("100.99.1.2"))
        XCTAssertFalse(m.matches("fd7a:115c:a1e0::1"))
    }

    func testParseCIDRValidation() {
        XCTAssertNotNil(CIDRMatcher.parseCIDR("100.64.0.0/10"))
        XCTAssertNotNil(CIDRMatcher.parseCIDR("fd7a:115c:a1e0::/48"))
        XCTAssertNotNil(CIDRMatcher.parseCIDR("0.0.0.0/0"))
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0"))       // prefix なし
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0/33"))    // v4 上限超え
        XCTAssertNil(CIDRMatcher.parseCIDR("fd7a::/129"))       // v6 上限超え
        XCTAssertNil(CIDRMatcher.parseCIDR("hello/8"))
    }
}
