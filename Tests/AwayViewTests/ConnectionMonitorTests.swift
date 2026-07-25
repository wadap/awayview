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
