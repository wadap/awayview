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
        return " (\(f.string(from: date))〜)"
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
