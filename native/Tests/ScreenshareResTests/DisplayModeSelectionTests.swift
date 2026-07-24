import XCTest
@testable import ScreenshareRes

final class DisplayModeSelectionTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, hiDPI: Bool, hz: Double = 120) -> DisplayModeInfo {
        DisplayModeInfo(width: w, height: h,
                        pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h,
                        refreshRate: hz, mode: nil)
    }

    // 実機 (3840x1620 の 40 インチ) のモード一覧を模したフィクスチャ
    private var modes: [DisplayModeInfo] {
        [
            mode(3840, 1620, hiDPI: false), mode(3840, 1620, hiDPI: true),
            mode(2560, 1080, hiDPI: false), mode(2560, 1080, hiDPI: true),
            mode(1920, 1080, hiDPI: false), mode(1920, 1080, hiDPI: true),
            mode(1920, 810, hiDPI: false), mode(1920, 810, hiDPI: true),
            mode(1600, 1200, hiDPI: false),
            mode(1280, 540, hiDPI: false, hz: 60), mode(1280, 540, hiDPI: true),
        ]
    }

    func testFindModePrefersHiDPIAndHigherRefresh() {
        let m = DisplayController.findMode("1920x810", in: modes)
        XCTAssertEqual(m?.resString, "1920x810")
        XCTAssertEqual(m?.isHiDPI, true)
    }

    func testFindModeExactOnly() {
        XCTAssertNil(DisplayController.findMode("1234x567", in: modes))
        XCTAssertNil(DisplayController.findMode("not-a-res", in: modes))
    }

    // 低解像度の既定 = ホームの半分 (同アスペクト・HiDPI 優先)
    func testDefaultLowIsHalfOfHome() {
        let m = DisplayController.defaultLowMode(homeWidth: 3840, homeHeight: 1620, in: modes)
        XCTAssertEqual(m?.resString, "1920x810")
        XCTAssertEqual(m?.isHiDPI, true)
    }

    // ちょうど半分が無ければ同アスペクトで半分以下の最大を選ぶ
    func testDefaultLowFallsBackToNearestSameAspect() {
        let noHalf = modes.filter { $0.resString != "1920x810" }
        let m = DisplayController.defaultLowMode(homeWidth: 3840, homeHeight: 1620, in: noHalf)
        XCTAssertEqual(m?.resString, "1280x540")
        XCTAssertEqual(m?.isHiDPI, true)
    }

    func testDefaultLowNilWhenNothingFits() {
        let only43 = [mode(1600, 1200, hiDPI: false)]
        XCTAssertNil(DisplayController.defaultLowMode(homeWidth: 3840, homeHeight: 1620, in: only43))
    }
}
