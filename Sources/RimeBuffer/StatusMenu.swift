import Cocoa
import CRimeBridge

/// Menu provider for ETInput's own status-bar control. The system input-source
/// menu is intentionally left alone; it is for choosing input sources, while
/// this menu is the product control surface.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var item: NSStatusItem?
    private(set) var schemaId = ""
    private(set) var schemaName = ""
    private(set) var healthy = true

    private var installLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer-install.log")
    }

    func install() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = status
        refreshButton()
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
    }

    func update(schemaId: String, schemaName: String) {
        self.schemaId = schemaId
        self.schemaName = schemaName
    }

    func setHealthy(_ ok: Bool) {
        healthy = ok
        refreshButton()
    }

    /// The custom monochrome menu-bar glyph (bundled), rendered as a template so
    /// macOS tints it for light/dark menu bars.
    private static let menubarImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-template", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    private func refreshButton() {
        guard let button = item?.button else { return }
        if healthy, let img = Self.menubarImage {
            button.image = img
        } else {
            button.image = NSImage(
                systemSymbolName: healthy ? "keyboard.badge.ellipsis" : "keyboard.badge.exclamationmark",
                accessibilityDescription: "Enter输入法")
        }
        button.contentTintColor = nil
    }

    // Rebuild on every open so state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    /// Keep the menu bar surface as a single entry point. Detailed controls
    /// live in Settings, not in this tiny dropdown.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let checkUpdate = NSMenuItem(title: "检查更新…", action: #selector(checkUpdate), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

        let log = NSMenuItem(title: "打开日志 (~/rimebuffer.log)", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let deploy = NSMenuItem(title: "重新部署并重启", action: #selector(deployAndRestart), keyEquivalent: "")
        deploy.target = self
        menu.addItem(deploy)

        let reinstall = NSMenuItem(title: "重新安装输入法…", action: #selector(reinstallInputMethod), keyEquivalent: "")
        reinstall.target = self
        menu.addItem(reinstall)

        let restart = NSMenuItem(title: "重启输入法进程", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func deployAndRestart() {
        RimeBufferController.active?.forceCommit()
        IMELog.write("status menu: deploy requested")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rimeEngine.start()
            let ok = BBRimeDeploy()
            IMELog.write("status menu: deploy=\(ok), restarting")
            DispatchQueue.main.async {
                KeyFrequencyStore.shared.saveNow()
                exit(0)
            }
        }
    }

    @objc private func reinstallInputMethod() {
        guard let script = installScriptURL() else {
            showInfo("找不到 build_install.sh。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "重新安装 Enter输入法？"
        alert.informativeText = "将从 \(script.deletingLastPathComponent().path) 运行 build_install.sh。构建完成后当前输入法进程会被重启。"
        alert.addButton(withTitle: "重新安装")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        RimeBufferController.active?.forceCommit()
        KeyFrequencyStore.shared.saveNow()

        let command = [
            "cd \(shellQuote(script.deletingLastPathComponent().path))",
            "nohup /bin/bash ./build_install.sh > \(shellQuote(installLogURL.path)) 2>&1 &",
        ].joined(separator: " && ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
            IMELog.write("status menu: launched install script \(script.path)")
        } catch {
            showInfo("安装启动失败：\(error.localizedDescription)")
        }
    }

    @objc private func restart() {
        IMELog.write("status menu: restart requested")
        RimeBufferController.active?.forceCommit()
        KeyFrequencyStore.shared.saveNow()
        exit(0)
    }

    private func installScriptURL() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/DEV/rime-buffer/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer/build_install.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
