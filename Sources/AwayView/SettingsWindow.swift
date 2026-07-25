import AppKit
import ServiceManagement
import SwiftUI

// 設定ウィンドウ: SwiftUI Form を NSWindow にホスト。バリデーションは保存時。
// ポート/CIDR は SettingsStore へ書くだけで、次 tick から効く (再起動不要)。
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, onChange: onChange))
        window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AwayViewSettings")
        if !window.setFrameUsingName("AwayViewSettings") {
            window.center()   // 初回のみ
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)   // accessory アプリなので明示活性化
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let settings: SettingsStore
    let onChange: () -> Void

    @State private var portText: String
    @State private var cidrText: String
    @State private var launchAtLogin: Bool
    @State private var message: String?
    @State private var isError = false

    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        _portText = State(initialValue: String(settings.port))
        _cidrText = State(initialValue: settings.cidrs.joined(separator: "\n"))
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.port"))
                TextField("5900", text: $portText)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.cidrs"))
                TextEditor(text: $cidrText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 72)
                    .border(Color.secondary.opacity(0.3))
                Text(L("settings.cidrs.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(L("settings.launch_at_login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        message = error.localizedDescription
                        isError = true
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
                Spacer()
                Button(L("settings.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        guard let p = Int(trimmedPort), (1...65535).contains(p) else {
            message = L("settings.error.port")
            isError = true
            return
        }
        let lines = cidrText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines where CIDRMatcher.parseCIDR(line) == nil {
            message = L("settings.error.cidr", line)
            isError = true
            return
        }
        settings.port = UInt16(p)
        portText = String(p)
        settings.cidrs = lines
        message = L("settings.saved")
        isError = false
        onChange()
    }
}
