import Cocoa

/// Menu-bar entry point (user-requested): a persistent NSStatusItem mirroring
/// what the IMK input-source menu offers — schema switching, engine health,
/// log access, process restart. The IMK menu() on the controller is the
/// primary channel; this item is the always-visible backup.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var item: NSStatusItem?
    private(set) var schemaId = ""
    private(set) var schemaName = ""
    private(set) var healthy = true

    static let schemas: [(id: String, title: String)] = [
        ("my_combo", "并击 my_combo"),
        ("my_serial", "串击 my_serial"),
    ]

    func install() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis",
                                   accessibilityDescription: "RimeBuffer")
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        item = status
    }

    func update(schemaId: String, schemaName: String) {
        self.schemaId = schemaId
        self.schemaName = schemaName
    }

    func setHealthy(_ ok: Bool) {
        healthy = ok
        item?.button?.image = NSImage(
            systemSymbolName: ok ? "keyboard.badge.ellipsis" : "keyboard.badge.exclamationmark",
            accessibilityDescription: "RimeBuffer")
    }

    // Rebuild on every open so state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let health = NSMenuItem(
            title: healthy ? "RimeBuffer · \(schemaName.isEmpty ? "就绪" : schemaName)"
                           : "⚠️ 引擎异常 — 已退化为英文直通",
            action: nil, keyEquivalent: "")
        health.isEnabled = false
        menu.addItem(health)
        menu.addItem(.separator())

        for schema in Self.schemas {
            let mi = NSMenuItem(title: schema.title, action: #selector(chooseSchema(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = schema.id
            mi.state = schemaId == schema.id ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let buffer = NSMenuItem(title: "缓冲模式（先暂存再上屏）",
                                action: #selector(toggleBuffer), keyEquivalent: "")
        buffer.target = self
        buffer.state = BufferModel.shared.enabled ? .on : .off
        menu.addItem(buffer)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let log = NSMenuItem(title: "打开日志 (~/rimebuffer.log)", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let restart = NSMenuItem(title: "重启输入法进程", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
    }

    @objc private func chooseSchema(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        RimeBufferController.applyPreferredSchema(id)
    }

    @objc private func toggleBuffer() {
        BufferModel.shared.enabled.toggle()
        IMELog.write("buffer mode -> \(BufferModel.shared.enabled)")
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func restart() {
        IMELog.write("user requested restart from status menu")
        RimeBufferController.active?.forceCommit()   // don't strand a composition
        exit(0)   // the system relaunches the IME on demand
    }
}
