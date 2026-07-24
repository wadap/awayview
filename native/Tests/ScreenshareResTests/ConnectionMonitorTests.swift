import XCTest
@testable import ScreenshareRes

final class TailscaleRangeTests: XCTestCase {
    func testIPv4InRange() {
        XCTAssertTrue(isTailscaleIP("100.64.0.1"))
        XCTAssertTrue(isTailscaleIP("100.99.1.2"))
        XCTAssertTrue(isTailscaleIP("100.127.255.255"))
        XCTAssertTrue(isTailscaleIP("100.107.241.12"))
    }

    func testIPv4OutOfRange() {
        XCTAssertFalse(isTailscaleIP("100.63.255.255"))
        XCTAssertFalse(isTailscaleIP("100.128.0.1"))
        XCTAssertFalse(isTailscaleIP("99.64.0.1"))
        XCTAssertFalse(isTailscaleIP("192.168.1.10"))
        XCTAssertFalse(isTailscaleIP("100.64.0"))
        XCTAssertFalse(isTailscaleIP(""))
        XCTAssertFalse(isTailscaleIP("100.64.0.999"))
    }

    func testIPv6Range() {
        XCTAssertTrue(isTailscaleIP("fd7a:115c:a1e0::1"))
        XCTAssertTrue(isTailscaleIP("FD7A:115C:A1E0:AB12:4843:CD96:6265:B2B5"))
        XCTAssertFalse(isTailscaleIP("fd7a:115c:a1e1::1"))
        XCTAssertFalse(isTailscaleIP("fe80::1"))
        XCTAssertFalse(isTailscaleIP("::1"))
    }
}

final class ConnectionMonitorSmokeTests: XCTestCase {
    // 実カーネルバッファを歩いてクラッシュしないこと (中身は環境依存なので緩い検証)
    func testWalksRealBufferWithoutCrash() {
        _ = ConnectionMonitor(localPort: 5900).establishedForeignIPs()
        _ = ConnectionMonitor(localPort: 22).establishedForeignIPs()
    }

    // localPort フィルタ: 存在しないはずのポートでは空になる
    func testFiltersByLocalPort() {
        XCTAssertEqual(ConnectionMonitor(localPort: 1).establishedForeignIPs(), [])
    }
}
