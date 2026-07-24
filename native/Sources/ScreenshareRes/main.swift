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

print("usage: ScreenshareRes --list-modes | --list-connections")
exit(2)
