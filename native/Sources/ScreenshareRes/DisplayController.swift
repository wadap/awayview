import CoreGraphics
import Foundation

// Swift に公開されていない CG シンボル。displayplacer の persistent id と同じ UUID を返す
@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
func CGDisplayCreateUUIDFromDisplayID(_ display: UInt32) -> Unmanaged<CFUUID>?

/// CoreGraphics 直叩きの表示制御。まずはモード列挙（Task 1 スパイク範囲）。
struct DisplayModeInfo {
    let width: Int        // ポイント解像度
    let height: Int
    let pixelWidth: Int   // 物理ピクセル
    let pixelHeight: Int
    let refreshRate: Double
    let mode: CGDisplayMode

    var isHiDPI: Bool { pixelWidth > width }
    var resString: String { "\(width)x\(height)" }
}

enum DisplayController {
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// HiDPI(scaled) モードを含む全モード。displayplacer 相当の一覧が取れるかの検証対象
    static func allModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        return raw.map {
            DisplayModeInfo(width: $0.width, height: $0.height,
                            pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                            refreshRate: $0.refreshRate, mode: $0)
        }
    }
}
