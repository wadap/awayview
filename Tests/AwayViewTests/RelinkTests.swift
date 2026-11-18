import CoreGraphics
import XCTest
@testable import AwayView

final class RelinkTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, px: Int, py: Int, hz: Double) -> DisplayModeInfo {
        DisplayModeInfo(width: w, height: h, pixelWidth: px, pixelHeight: py, refreshRate: hz, mode: nil)
    }

    // --- 迂回モードの選出 ----------------------------------------------------

    func testDetourPrefersSameSizeWithDifferentScale() {
        // ポイント解像度が同じならウィンドウは動かない。実機の LG 5K2K はこの形
        let current = mode(3840, 1620, px: 7680, py: 3240, hz: 120)
        let modes = [
            current,
            mode(3840, 1620, px: 3840, py: 1620, hz: 120),
            mode(3840, 1620, px: 7680, py: 3240, hz: 60),
            mode(1920, 1080, px: 3840, py: 2160, hz: 120),
        ]
        let detour = DisplayController.relinkDetour(for: current, in: modes)
        XCTAssertEqual(detour?.resString, "3840x1620")
        XCTAssertEqual(detour?.pixelWidth, 3840)
    }

    func testDetourFallsBackToDifferentRefreshRate() {
        let current = mode(3840, 1620, px: 7680, py: 3240, hz: 120)
        let modes = [
            current,
            mode(3840, 1620, px: 7680, py: 3240, hz: 60),
            mode(3840, 1620, px: 7680, py: 3240, hz: 100),
            mode(1920, 1080, px: 3840, py: 2160, hz: 60),
        ]
        let detour = DisplayController.relinkDetour(for: current, in: modes)
        XCTAssertEqual(detour?.resString, "3840x1620")
        XCTAssertEqual(detour?.refreshRate, 100, "現在と違うレートのうち最も高いもの")
    }

    func testDetourTreatsNearlyEqualRatesAsSame() {
        // 119.88 と 120 は同じタイミングとして扱う (当て直しにならない)
        let current = mode(3840, 1620, px: 7680, py: 3240, hz: 120)
        let modes = [current, mode(3840, 1620, px: 7680, py: 3240, hz: 119.88)]
        XCTAssertNil(DisplayController.relinkDetour(for: current, in: modes))
    }

    func testDetourNeverChangesPointResolution() {
        let current = mode(1920, 1080, px: 1920, py: 1080, hz: 60)
        let modes = [current, mode(1280, 720, px: 1280, py: 720, hz: 60)]
        XCTAssertNil(DisplayController.relinkDetour(for: current, in: modes))
    }

    // --- ガード -------------------------------------------------------------

    func testRelinkIsDeferredWhenDisplayNotReady() {
        let suite = "awayview-unit-tests-relink"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let env = FakeDisplayEnvironment()
        env.add(0xDEAD_0002, uuid: "EXT", ready: false)
        let dc = RealDisplayController(defaults: defaults, environment: env)
        XCTAssertEqual(dc.relink(), .deferred)
    }
}
