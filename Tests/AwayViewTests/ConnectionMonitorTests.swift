import XCTest
@testable import AwayView

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

// 列挙結果の三値化。ここが潰れると一過性の sysctl 失敗が「切断」に化ける
final class ConnectionProbeTests: XCTestCase {
    private let cidrs = CIDRMatcher(["100.64.0.0/10"])

    /// lister をすげ替えたモニタ。code < 0 はエラー、>= 0 は ips を書き込んだ件数
    private func monitor(code: Int32, ips: [String] = []) -> ConnectionMonitor {
        ConnectionMonitor(localPort: 5900, matcher: cidrs) { _, out, cap in
            let text = ips.joined(separator: "\n")
            if !text.isEmpty {
                let bytes = Array(text.utf8CString)
                precondition(bytes.count <= cap)
                for (i, b) in bytes.enumerated() { out[i] = b }
            }
            return code
        }
    }

    func testEnumerationErrorIsUnavailable() {
        XCTAssertEqual(monitor(code: -1).probe(), .unavailable,
                       "列挙エラーは「接続なし」ではなく判定不能")
    }

    func testZeroConnectionsIsNone() {
        XCTAssertEqual(monitor(code: 0).probe(), ConnectionProbe.none)
    }

    func testMatchingConnectionIsRemote() {
        XCTAssertEqual(monitor(code: 1, ips: ["100.79.107.126"]).probe(),
                       .remote("100.79.107.126"))
    }

    func testConnectionOutsideCIDRIsNone() {
        XCTAssertEqual(monitor(code: 1, ips: ["192.168.1.5"]).probe(), ConnectionProbe.none)
    }

    func testEnumerationErrorIsDistinctFromEmptyList() {
        XCTAssertNil(monitor(code: -1).enumerateForeignIPs())
        XCTAssertEqual(monitor(code: 0).enumerateForeignIPs(), [])
    }
}
