import CoreGraphics
import Foundation

let args = CommandLine.arguments

if args.contains("--list-modes") {
    for id in DisplayController.onlineDisplays() {
        let uuid = DisplayController.uuidString(for: id) ?? "?"
        let role = CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external"
        let main = CGDisplayIsMain(id) != 0 ? " main" : ""
        print("Display \(id) [\(role)\(main)] UUID=\(uuid)")
        if let cur = CGDisplayCopyDisplayMode(id) {
            print("  current: \(cur.width)x\(cur.height) (px \(cur.pixelWidth)x\(cur.pixelHeight)) @\(Int(cur.refreshRate))Hz")
        }
        var seen = Set<String>()
        let modes = DisplayController.allModes(for: id)
            .sorted { ($0.width, $0.height) > ($1.width, $1.height) }
        for m in modes {
            let key = "\(m.resString)\(m.isHiDPI ? "@2x" : "")"
            guard seen.insert(key).inserted else { continue }
            print("  \(m.resString)\(m.isHiDPI ? " HiDPI" : "      ") px=\(m.pixelWidth)x\(m.pixelHeight) @\(Int(m.refreshRate))Hz")
        }
    }
    exit(0)
}

if args.contains("--list-connections") {
    let monitor = ConnectionMonitor()
    let ips = monitor.establishedForeignIPs()
    print("port 5900 ESTABLISHED foreign IPs: \(ips.isEmpty ? "(none)" : ips.joined(separator: ", "))")
    if let ts = monitor.tailscaleRemoteIP() {
        print("tailscale remote: \(ts)")
    } else {
        print("tailscale remote: (none)")
    }
    exit(0)
}

// 実機検証用: ホーム学習 → 低解像度適用 → 復帰の往復を CLI で叩ける
if let i = args.firstIndex(of: "--apply"), i + 1 < args.count {
    // 検証専用: capture はしない (低解像度中に実行してもホームを誤学習しない)
    let dc = RealDisplayController()
    dc.log = { print($0) }
    let ok = dc.applyLow(args[i + 1] == "default" ? nil : args[i + 1])
    print(ok ? "applied" : "apply FAILED")
    exit(ok ? 0 : 1)
}

if args.contains("--restore") {
    let dc = RealDisplayController()
    dc.log = { print($0) }
    switch dc.restoreHome(explicit: nil) {
    case .ok: print("restored"); exit(0)
    case .noCache: print("no home cache"); exit(1)
    case .failed: print("restore FAILED"); exit(1)
    }
}

if args.contains("--capture-home") {
    let dc = RealDisplayController()
    dc.captureHome(onlyIfMissing: false)
    if let home = dc.storedHome() {
        print("home: \(home.width)x\(home.height)\(home.isHiDPI ? " HiDPI" : "")")
        exit(0)
    }
    print("capture FAILED (display inactive?)")
    exit(1)
}

print("usage: ScreenshareRes --list-modes | --list-connections | --capture-home | --apply <WxH|default> | --restore")
exit(2)
