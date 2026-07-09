import Cocoa

/// Menu provider for the SYSTEM input-source menu: RimeBufferController.menu()
/// calls populate(_:) so all features (schema switching, buffer mode, remote
/// typing, updates, log, restart) live under the system input menu — the same
/// place every input method exposes its options. The standalone NSStatusItem
/// is no longer installed by default (install() kept for debugging).
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var item: NSStatusItem?
    private(set) var schemaId = ""
    private(set) var schemaName = ""
    private(set) var healthy = true

    /// Schemas to offer — the ones Rime ACTUALLY deployed (not hard-coded), so
    /// we never present a schema that isn't installed (which would switch the
    /// session to an empty schema with no candidates). Falls back to a default
    /// when the engine isn't up yet.
    static func availableSchemas() -> [(id: String, title: String)] {
        let list = rimeEngine.schemaList()
        if list.isEmpty { return [("my_serial", "串击")] }
        return list.map { ($0.id, $0.name) }
    }

    func install() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = status
        refreshButton()
        // An available/staged update tints the menu-bar icon so it's noticeable
        // without a nagging alert; the menu itself offers the one-click install.
        UpdateManager.shared.onChange = { [weak self] in self?.refreshButton() }
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
                accessibilityDescription: "恩特输入法")
        }
        button.contentTintColor = UpdateManager.shared.pendingVersion != nil ? .controlAccentColor : nil
    }

    // Rebuild on every open so state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    /// Build the full feature menu. Shared by the (optional) status item and
    /// the IMK menu() on the controller, so the system input menu carries
    /// everything. All targets point at self — IMK keeps the NSMenu object in
    /// this process and invokes target/action on click (sender may arrive as
    /// the item or wrapped in a dictionary; handlers unwrap both).
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let version = UpdateManager.shared.currentVersion
        let health = NSMenuItem(
            title: healthy ? "恩特输入法 v\(version) · \(schemaName.isEmpty ? "就绪" : schemaName)"
                           : "⚠️ 引擎异常 — 已退化为英文直通",
            action: nil, keyEquivalent: "")
        health.isEnabled = false
        menu.addItem(health)
        menu.addItem(.separator())

        // Staged update, if any, gets top billing with a one-click install.
        if UpdateManager.shared.isUpdateReady, let newVersion = UpdateManager.shared.pendingVersion {
            let update = NSMenuItem(title: "🎉 有新版本 v\(newVersion) — 立即更新",
                                    action: #selector(installUpdate), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
        }

        for schema in Self.availableSchemas() {
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

        // 隔空传字：把 commit 的文字发到已配对的另一台 Mac。配对靠"请求→同意"，无需配对码。
        let remote = RemoteTypingService.shared
        let remoteStatus = NSMenuItem(title: "隔空传字 · \(remote.statusSummary)", action: nil, keyEquivalent: "")
        remoteStatus.isEnabled = false
        menu.addItem(remoteStatus)

        let remoteToggle = NSMenuItem(title: "启用隔空传字", action: #selector(toggleRemote), keyEquivalent: "")
        remoteToggle.target = self
        remoteToggle.state = RemoteConfig.enabled ? .on : .off
        menu.addItem(remoteToggle)

        if RemoteConfig.enabled {
            // 配对新设备：列出发现的、尚未配对的设备，点一下发起请求。
            let pairSub = NSMenu()
            let untrusted = remote.status.discovered.filter { !$0.trusted }
            if untrusted.isEmpty {
                let none = NSMenuItem(title: "（未发现设备）", action: nil, keyEquivalent: "")
                none.isEnabled = false
                pairSub.addItem(none)
            } else {
                for p in untrusted {
                    let mi = NSMenuItem(title: p.name, action: #selector(pairDevice(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = p.id
                    pairSub.addItem(mi)
                }
            }
            let pairItem = NSMenuItem(title: "配对新设备", action: nil, keyEquivalent: "")
            pairItem.submenu = pairSub
            menu.addItem(pairItem)

            if !remote.status.trusted.isEmpty {
                let trustedSub = NSMenu()
                for t in remote.status.trusted {
                    let mi = NSMenuItem(title: "取消配对：\(t.name)", action: #selector(unpairDevice(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = t.pubB64
                    trustedSub.addItem(mi)
                }
                let trustedItem = NSMenuItem(title: "已配对设备", action: nil, keyEquivalent: "")
                trustedItem.submenu = trustedSub
                menu.addItem(trustedItem)
            }
        }

        let remoteName = NSMenuItem(title: "本机名称：\(RemoteConfig.deviceName)",
                                    action: #selector(setDeviceName), keyEquivalent: "")
        remoteName.target = self
        menu.addItem(remoteName)
        menu.addItem(.separator())

        let checkUpdate = NSMenuItem(title: "检查更新…", action: #selector(checkUpdate), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

        let log = NSMenuItem(title: "打开日志 (~/rimebuffer.log)", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let restart = NSMenuItem(title: "重启输入法进程", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
    }

    @objc private func installUpdate() {
        UpdateManager.shared.promptAndInstall()
    }

    @objc private func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    // MARK: 隔空传字

    @objc private func toggleRemote() {
        RemoteConfig.enabled.toggle()
        if RemoteConfig.enabled { RemoteTypingService.shared.restart() }
        else { RemoteTypingService.shared.stop() }
        IMELog.write("remote typing enabled -> \(RemoteConfig.enabled)")
    }

    /// IMK delivers the clicked item either directly or wrapped in a
    /// dictionary under IMKCommandMenuItem, depending on macOS version.
    private func menuItem(from sender: Any?) -> NSMenuItem? {
        (sender as? NSMenuItem)
            ?? ((sender as? [String: Any])?["IMKCommandMenuItem"] as? NSMenuItem)
    }

    @objc private func pairDevice(_ sender: Any?) {
        // Connects + handshakes; the SAS-confirm dialog (onPairConfirm) pops once
        // we've reached the peer, then the other Mac shows 同意.
        guard let id = menuItem(from: sender)?.representedObject as? String else { return }
        RemoteTypingService.shared.requestPair(peerID: id)
    }

    @objc private func unpairDevice(_ sender: Any?) {
        guard let pubB64 = menuItem(from: sender)?.representedObject as? String else { return }
        RemoteTypingService.shared.unpair(pubB64: pubB64)
    }

    @objc private func setDeviceName() {
        guard let name = promptText(
            title: "本机名称",
            message: "这个名字会显示在对方 Mac 上。", initial: RemoteConfig.deviceName) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { RemoteConfig.deviceName = trimmed; RemoteTypingService.shared.restart() }
    }

    private func promptText(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        alert.window.makeFirstResponder(field)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func chooseSchema(_ sender: Any?) {
        guard let id = menuItem(from: sender)?.representedObject as? String else { return }
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
        KeyFrequencyStore.shared.saveNow()
        exit(0)   // the system relaunches the IME on demand
    }
}
