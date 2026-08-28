import AppKit

// メニューバー UI とアプリ全体の組み立て。メニュー構成は SwiftBar 版と同一
// (3 モードラジオ + 解像度サブメニュー + ログ + 常駐設定 + 終了)。
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let writer: ObservationWriter
    private let settings: SettingsStore
    private let display: RealDisplayController
    private var machine: StateMachine!
    private var statusItem: NSStatusItem!
    private var timer: DispatchSourceTimer?
    private var settingsWindow: SettingsWindowController?

    private var currentState: WatchState = .home
    private var currentIP: String?
    private var lastLogged: WatchState?
    private let origin = InstallOrigin.detect()
    private let version = AppVersion.current()
    private var pendingRelease: Release?
    private var isChecking = false
    private var updateTimer: DispatchSourceTimer?

    init(stateDirectory: URL? = nil) {
        self.writer = stateDirectory.map { ObservationWriter(directory: $0) } ?? ObservationWriter()
        self.settings = SettingsStore()
        self.display = RealDisplayController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        display.log = { [writer] message in writer.log(message) }
        Hooks.log = { [writer] message in writer.log(message) }

        machine = StateMachine(
            connection: SettingsBackedConnection(settings: settings),
            display: display,
            flags: settings
        ) { [weak self] state, ip in
            self?.stateChanged(state, ip)
        }
        machine.onLowApplied = { Hooks.run("on_low") }
        machine.onHighRestored = { Hooks.run("on_high") }
        // 列挙不能は状態遷移ではないので writeState はせず、ログにだけ残す。
        // 連続すると sysctl 側の恒常的な問題を示す
        machine.onProbeUnavailable = { [writer] in
            writer.log("!! connection probe unavailable (holding previous state)")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🏠"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        writer.log("watcher started (native)")

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 3)   // POLL_INTERVAL 相当
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // 更新チェック: 起動 5 分後から 1 時間ごとに「24 時間経ったか」を見る。
        // 判定を時刻ベースにしているのは、再起動を繰り返しても過剰に叩かないため
        let u = DispatchSource.makeTimerSource(queue: .main)
        u.schedule(deadline: .now() + 300, repeating: 3600)
        u.setEventHandler { [weak self] in self?.autoCheckIfDue() }
        u.resume()
        updateTimer = u

        UpdateInstaller.log = { [writer] message in writer.log(message) }
    }

    private func tick() {
        machine.tick()
        updateIcon()
    }

    private func stateChanged(_ state: WatchState, _ ip: String?) {
        currentState = state
        currentIP = ip
        if state != lastLogged {
            switch state {
            case .low: writer.log("-> LOW (remote connection)")
            case .lowManual: writer.log("-> LOW (manual)")
            case .override: writer.log("-> HIGH (override)")
            case .home: writer.log("-> HIGH (restored)")
            }
            lastLogged = state
        }
        writer.writeState(state, remoteIP: ip)
    }

    private func updateIcon() {
        let icon: String
        if display.resolveTarget() == nil {
            icon = "⚠️"
        } else {
            switch currentState {
            case .low, .lowManual: icon = "💻"
            case .override: icon = "📌"
            case .home: icon = "🏠"
            }
        }
        statusItem.button?.title = icon
    }

    // --- 更新 ------------------------------------------------------------

    private func autoCheckIfDue() {
        guard settings.autoCheckEnabled else { return }
        if let last = settings.lastCheckedAt, Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        checkForUpdates(manual: false)
    }

    private func checkForUpdates(manual: Bool) {
        guard !isChecking, let version else { return }
        isChecking = true
        let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: version)
        // ネットワーク I/O は同期なので背景キューで回す
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = checker.check()
            DispatchQueue.main.async { self?.checkFinished(result, manual: manual) }
        }
    }

    private func checkFinished(_ result: UpdateCheckResult, manual: Bool) {
        isChecking = false
        settings.lastCheckedAt = Date()
        switch result {
        case .upToDate:
            pendingRelease = nil
            writer.log("update check: up to date")
            if manual, let version {
                alert(L("update.up_to_date", version.description))
            }
        case .available(let release):
            pendingRelease = release
            writer.log("update check: \(release.version) available")
        case .failed(let reason):
            // 確認できなかっただけ。watcher は止めない (hooks の失敗と同じ規律)
            writer.log("!! update check failed: \(reason)")
            if manual { alert(L("update.failed", reason)) }
        }
    }

    @objc private func checkForUpdatesManually() {
        checkForUpdates(manual: true)
    }

    @objc private func copyBrewCommand() {
        let command = "brew upgrade --cask awayview"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        alert(L("update.copied", command))
    }

    @objc private func installUpdate() {
        guard let release = pendingRelease else { return }
        // 低解像度のまま再起動すると、その解像度をホームとして誤学習しうる。
        // 適用がユーザー操作起点でも、リモート接続中に押される可能性は残るので状態で塞ぐ
        guard currentState == .home else {
            alert(L("update.blocked_low"))
            return
        }
        writer.log("update: installing \(release.version)")
        switch UpdateInstaller.install(release) {
        case .ok:
            UpdateInstaller.relaunch()
            NSApp.terminate(nil)
        case .failed(let reason):
            writer.log("!! update failed: \(reason)")
            alertWithReleasesLink(L("update.install_failed", reason), url: release.htmlURL)
        }
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)   // accessory アプリなので明示活性化
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("update.ok"))
        a.runModal()
    }

    private func alertWithReleasesLink(_ message: String, url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("update.open_releases"))
        a.addButton(withTitle: L("update.ok"))
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateMenuItem() -> NSMenuItem {
        if isChecking {
            return disabled(L("menu.checking"))
        }
        guard let release = pendingRelease else {
            let item = NSMenuItem(title: L("menu.check_updates"),
                                  action: #selector(checkForUpdatesManually),
                                  keyEquivalent: "")
            item.target = self
            return item
        }
        switch origin {
        case .homebrew:
            // brew 管理下でアプリが自分を置き換えると brew 側の版情報がずれる。
            // ここではコマンドを渡すだけにする
            let item = NSMenuItem(title: L("menu.update_available_brew", release.version.description),
                                  action: #selector(copyBrewCommand),
                                  keyEquivalent: "")
            item.target = self
            return item
        case .direct:
            let item = NSMenuItem(title: L("menu.update_available", release.version.description),
                                  action: #selector(installUpdate),
                                  keyEquivalent: "")
            item.target = self
            return item
        }
    }

    // --- メニュー構築 (開くたびに再構築) ----------------------------------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if display.resolveTarget() == nil {
            menu.addItem(disabled(L("menu.no_display")))
            menu.addItem(.separator())
        }

        menu.addItem(disabled(L("menu.state", stateLabel())))
        menu.addItem(disabled(L("menu.connection", currentIP ?? L("menu.connection.none"))))
        menu.addItem(.separator())

        let mode = settings.currentMode
        menu.addItem(modeItem(L("mode.auto"), .auto, current: mode))
        menu.addItem(modeItem(L("mode.high"), .high, current: mode))
        menu.addItem(modeItem(L("mode.low"), .low, current: mode))
        menu.addItem(.separator())

        let modes = display.resolveTarget().map { DisplayController.allModes(for: $0) } ?? []
        menu.addItem(resParent(kind: .high, modes: modes))
        menu.addItem(resParent(kind: .low, modes: modes))
        menu.addItem(.separator())

        let logItem = NSMenuItem(title: L("menu.open_log"), action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(disabled(L("menu.version", version?.description ?? "dev")))
        menu.addItem(updateMenuItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func stateLabel() -> String {
        switch currentState {
        case .home: return L("state.home")
        case .low: return L("state.low")
        case .lowManual: return L("state.low_manual", modeTimeSuffix())
        case .override: return L("state.override", modeTimeSuffix())
        }
    }

    private func modeTimeSuffix() -> String {
        guard let date = settings.modeChangedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return L("state.time_suffix", f.string(from: date))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func modeItem(_ title: String, _ mode: WatchMode, current: WatchMode) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode
        item.state = mode == current ? .on : .off
        return item
    }

    private enum ResKind { case high, low }

    private func resParent(kind: ResKind, modes: [DisplayModeInfo]) -> NSMenuItem {
        let selected = kind == .high ? settings.resHigh : settings.resLow
        let defaultLabel: String
        switch kind {
        case .high:
            let home = display.storedHome().map { " (\($0.width)x\($0.height))" } ?? ""
            defaultLabel = L("res.high.default", home)
        case .low:
            defaultLabel = L("res.low.default")
        }
        let title = kind == .high ? L("res.high.title", selected ?? defaultLabel)
                                  : L("res.low.title", selected ?? defaultLabel)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let def = NSMenuItem(title: defaultLabel,
                             action: kind == .high ? #selector(selectResHigh(_:)) : #selector(selectResLow(_:)),
                             keyEquivalent: "")
        def.target = self
        def.representedObject = nil as String?
        def.state = selected == nil ? .on : .off
        submenu.addItem(def)

        var seen = Set<String>()
        for m in modes.sorted(by: { ($0.width, $0.height) > ($1.width, $1.height) }) {
            guard seen.insert(m.resString).inserted else { continue }
            let item = NSMenuItem(title: m.resString,
                                  action: kind == .high ? #selector(selectResHigh(_:)) : #selector(selectResLow(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = m.resString
            item.state = selected == m.resString ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // --- アクション -------------------------------------------------------

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? WatchMode else { return }
        settings.setMode(mode)
        tick()   // 即反映
    }

    @objc private func selectResHigh(_ sender: NSMenuItem) {
        settings.setResHigh(sender.representedObject as? String)
        tick()
    }

    @objc private func selectResLow(_ sender: NSMenuItem) {
        settings.setResLow(sender.representedObject as? String)
        tick()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(writer.directory.appendingPathComponent("watch.log"))
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in self?.tick() }
        }
        settingsWindow?.show()
    }
}
