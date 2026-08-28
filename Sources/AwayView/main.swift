import AppKit
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
    let settings = SettingsStore()
    let monitor = ConnectionMonitor(localPort: settings.port,
                                    matcher: CIDRMatcher(settings.cidrs))
    let ips = monitor.establishedForeignIPs()
    print("port \(settings.port) ESTABLISHED foreign IPs: \(ips.isEmpty ? "(none)" : ips.joined(separator: ", "))")
    let matched: String = switch monitor.probe() {
    case .remote(let ip): ip
    case .none: "(none)"
    case .unavailable: "(enumeration failed)"
    }
    print("matched remote: \(matched)")
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

// 実機検証用: 更新チェックと適用を CLI から叩ける (ユニットテストの届かない範囲)
if args.contains("--check-update") {
    let current: AppVersion = AppVersion.current() ?? AppVersion(major: 0, minor: 0, patch: 0)
    print("current: \(current)")
    let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: current)
    switch checker.check() {
    case .upToDate: print("up to date"); exit(0)
    case .available(let r): print("available: \(r.version) \(r.downloadURL)"); exit(0)
    case .failed(let why): print("check FAILED: \(why)"); exit(1)
    }
}

if args.contains("--install-update") {
    // .build/release/AwayView のような素の実行ファイルでは bundleURL が
    // 親ディレクトリを指す。そのまま置換すると無関係なディレクトリを壊すので拒否する
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        print("refusing: --install-update only works from inside AwayView.app")
        exit(1)
    }
    let current: AppVersion = AppVersion.current() ?? AppVersion(major: 0, minor: 0, patch: 0)
    let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: current)
    UpdateInstaller.log = { print($0) }
    switch checker.check() {
    case .upToDate: print("up to date"); exit(0)
    case .failed(let why): print("check FAILED: \(why)"); exit(1)
    case .available(let release):
        switch UpdateInstaller.install(release) {
        case .ok: print("installed \(release.version)"); exit(0)
        case .failed(let why): print("install FAILED: \(why)"); exit(1)
        }
    }
}

if args.contains("--help") || args.contains("-h") {
    print("usage: AwayView [--list-modes | --list-connections | --capture-home | --apply <WxH|default> | --restore | --check-update | --install-update]")
    print("引数なしで起動するとメニューバーアプリとして常駐する")
    exit(0)
}

// 引数なし: メニューバーアプリとして常駐
let stateDir = ProcessInfo.processInfo.environment["AWAYVIEW_STATE_DIR"]
    .map { URL(fileURLWithPath: $0) }
let app = NSApplication.shared
let controller = AppController(stateDirectory: stateDir)
app.delegate = controller
app.setActivationPolicy(.accessory)   // Dock に出さない (メニューバーのみ)
app.run()
