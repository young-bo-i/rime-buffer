import Cocoa
import CRimeBridge
import UniformTypeIdentifiers

/// Visual settings surface for schema management, appearance/buffer toggles,
/// and local key-frequency statistics.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private enum Page: Int, CaseIterable {
        case schemas
        case appearance
        case keyStats

        var title: String {
            switch self {
            case .schemas: return "方案"
            case .appearance: return "外观与缓冲"
            case .keyStats: return "按键统计"
            }
        }
    }

    private var window: NSWindow?
    private let sidebar = NSStackView()
    private let contentHost = NSView()
    private var navButtons: [Page: NSButton] = [:]
    private var selectedPage: Page = .schemas
    private var statsObserver: NSObjectProtocol?

    private let schemaPopUp = NSPopUpButton()
    private let appearancePopUp = NSPopUpButton()
    private let bufferCheck = NSButton(checkboxWithTitle: "启用缓冲模式（提交先暂存，手动确认上屏）", target: nil, action: nil)
    private let statsDatePicker = NSDatePicker()
    private let statsSummary = NSTextField(labelWithString: "")
    private let statsTopKey = NSTextField(labelWithString: "")
    private let heatmapView = KeyboardHeatmapView()

    private var userDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/RimeBuffer")
    }

    func show() {
        if window == nil { build() }
        reload()
        showPage(selectedPage)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: UI construction

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "RimeBuffer 设置"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 860, height: 600)

        configureControls()

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        for page in Page.allCases {
            let button = NSButton(title: page.title, target: self, action: #selector(pageChosen(_:)))
            button.tag = page.rawValue
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 136).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            sidebar.addArrangedSubview(button)
            navButtons[page] = button
        }
        sidebar.addArrangedSubview(flexSpacer())

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [sidebar, divider, contentHost])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        win.contentView = NSView()
        win.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 160),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])

        statsObserver = NotificationCenter.default.addObserver(
            forName: .keyFrequencyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.selectedPage == .keyStats else { return }
            self?.refreshStats()
        }

        window = win
    }

    private func configureControls() {
        schemaPopUp.target = self
        schemaPopUp.action = #selector(schemaChosen)

        bufferCheck.target = self
        bufferCheck.action = #selector(bufferToggled)

        appearancePopUp.removeAllItems()
        for mode in RimeAppearanceMode.allCases {
            appearancePopUp.addItem(withTitle: mode.title)
            appearancePopUp.lastItem?.representedObject = mode.rawValue
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(appearanceChosen)

        statsDatePicker.datePickerElements = [.yearMonthDay]
        statsDatePicker.datePickerStyle = .textFieldAndStepper
        statsDatePicker.dateValue = Date()
        statsDatePicker.target = self
        statsDatePicker.action = #selector(statsDateChanged)

        statsSummary.font = .systemFont(ofSize: 13, weight: .semibold)
        statsTopKey.font = .systemFont(ofSize: 12)
        statsTopKey.textColor = .secondaryLabelColor
        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        heatmapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
    }

    private func showPage(_ page: Page) {
        selectedPage = page
        for (p, button) in navButtons {
            button.state = p == page ? .on : .off
            button.contentTintColor = p == page ? .controlAccentColor : .labelColor
        }

        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let pageView: NSView
        switch page {
        case .schemas: pageView = schemaPage()
        case .appearance: pageView = appearancePage()
        case .keyStats: pageView = keyStatsPage()
        }
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pageView.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor),
        ])
        if page == .keyStats { refreshStats() }
    }

    private func schemaPage() -> NSView {
        let importBtn = NSButton(title: "导入方案…", target: self, action: #selector(importSchema))
        let exportBtn = NSButton(title: "导出选中方案…", target: self, action: #selector(exportSchema))
        let deployBtn = NSButton(title: "重新部署并重启", target: self, action: #selector(deployAndRestart))
        deployBtn.bezelColor = .controlAccentColor
        let schemaButtons = NSStackView(views: [importBtn, exportBtn, deployBtn])
        schemaButtons.orientation = .horizontal
        schemaButtons.spacing = 8

        let openDirBtn = NSButton(title: "打开配置目录", target: self, action: #selector(openDir))
        let note = NSTextField(wrappingLabelWithString:
            "配置目录是 ~/Library/RimeBuffer。导入的方案会自动加入 schema_list；改动配置后点「重新部署并重启」生效。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        return contentColumn([
            title("方案"),
            caption("管理并击、串击和自定义 Rime schema。"),
            spacer(8),
            sectionLabel("当前方案"),
            schemaPopUp,
            schemaButtons,
            spacer(16),
            sectionLabel("配置目录"),
            openDirBtn,
            note,
        ])
    }

    private func appearancePage() -> NSView {
        return contentColumn([
            title("外观与缓冲"),
            caption("调整输入法界面外观，以及提交内容是否先进入缓冲区。"),
            spacer(8),
            sectionLabel("缓冲区"),
            bufferCheck,
            spacer(16),
            sectionLabel("外观"),
            appearancePopUp,
        ])
    }

    private func keyStatsPage() -> NSView {
        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refreshStatsTapped))
        let clearDayBtn = NSButton(title: "清空当天", target: self, action: #selector(clearStatsDay))
        let clearAllBtn = NSButton(title: "清空全部", target: self, action: #selector(clearStatsAll))
        let controls = NSStackView(views: [statsDatePicker, refreshBtn, flexSpacer(), clearDayBtn, clearAllBtn])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        return contentColumn([
            title("按键统计"),
            caption("按天统计本输入法收到的物理按键次数；只保存按键计数，不保存输入内容。"),
            spacer(8),
            controls,
            spacer(8),
            statsSummary,
            statsTopKey,
            heatmapView,
        ])
    }

    private func contentColumn(_ views: [NSView]) -> NSView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func title(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 20, weight: .semibold)
        return l
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }

    // MARK: State

    private func reload() {
        schemaPopUp.removeAllItems()
        for schema in installedSchemas() {
            schemaPopUp.addItem(withTitle: "\(schema.name)（\(schema.id)）")
            schemaPopUp.lastItem?.representedObject = schema.id
        }
        let preferred = UserDefaults.standard.string(forKey: "preferredSchema")
            ?? StatusMenu.shared.schemaId
        if let idx = (0..<schemaPopUp.numberOfItems).first(where: {
            schemaPopUp.item(at: $0)?.representedObject as? String == preferred
        }) {
            schemaPopUp.selectItem(at: idx)
        }
        bufferCheck.state = BufferModel.shared.enabled ? .on : .off
        if let idx = (0..<appearancePopUp.numberOfItems).first(where: {
            appearancePopUp.item(at: $0)?.representedObject as? String == RimeUI.appearance.rawValue
        }) {
            appearancePopUp.selectItem(at: idx)
        }
        refreshStats()
    }

    private func refreshStats() {
        let snapshot = KeyFrequencyStore.shared.snapshot(for: statsDatePicker.dateValue)
        heatmapView.snapshot = snapshot
        statsSummary.stringValue = "\(snapshot.dayKey) · 总按键 \(snapshot.total) 次 · 覆盖 \(snapshot.counts.count) 个键"
        if let top = snapshot.topKeyId {
            let count = snapshot.counts[top] ?? 0
            let ratio = snapshot.total > 0 ? Double(count) / Double(snapshot.total) * 100 : 0
            statsTopKey.stringValue = "最高频：\(KeyboardLayout.displayName(for: top)) · \(count) 次 · \(String(format: "%.1f", ratio))%"
        } else {
            statsTopKey.stringValue = "最高频：暂无"
        }
    }

    /// (id, display name) for every *.schema.yaml in the user dir.
    private func installedSchemas() -> [(id: String, name: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: userDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasSuffix(".schema.yaml") }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let id = firstMatch(#"schema_id:\s*(\S+)"#, in: text)
                    ?? url.lastPathComponent.replacingOccurrences(of: ".schema.yaml", with: "")
                let name = firstMatch(#"(?m)^\s{2}name:\s*\"?([^\"\n]+)\"?"#, in: text) ?? id
                return (id, name)
            }
            .sorted { $0.id < $1.id }
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Actions

    @objc private func pageChosen(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        reload()
        showPage(page)
    }

    @objc private func schemaChosen() {
        guard let id = schemaPopUp.selectedItem?.representedObject as? String else { return }
        RimeBufferController.applyPreferredSchema(id)
    }

    @objc private func importSchema() {
        let panel = NSOpenPanel()
        if let yaml = UTType(filenameExtension: "yaml") {
            panel.allowedContentTypes = [yaml]
        }
        panel.message = "选择一个 .schema.yaml 方案文件（并击方案同样适用）"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            let dest = userDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            let text = try String(contentsOf: dest, encoding: .utf8)
            let id = firstMatch(#"schema_id:\s*(\S+)"#, in: text)
                ?? src.lastPathComponent.replacingOccurrences(of: ".schema.yaml", with: "")
            try addToSchemaList(id)
            IMELog.write("settings: imported schema \(id)")
            reload()
            info("已导入「\(id)」并加入方案列表。点「重新部署并重启」生效。")
        } catch {
            info("导入失败：\(error.localizedDescription)")
        }
    }

    @objc private func exportSchema() {
        guard let id = schemaPopUp.selectedItem?.representedObject as? String else { return }
        let src = userDir.appendingPathComponent("\(id).schema.yaml")
        guard FileManager.default.fileExists(atPath: src.path) else {
            info("找不到 \(id).schema.yaml")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(id).schema.yaml"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            info("已导出到 \(dest.path)")
        } catch {
            info("导出失败：\(error.localizedDescription)")
        }
    }

    /// Append `- schema: <id>` to patch.schema_list in default.custom.yaml
    /// (with a .bak of the previous version). Naive line surgery, logged.
    private func addToSchemaList(_ id: String) throws {
        let file = userDir.appendingPathComponent("default.custom.yaml")
        var text = (try? String(contentsOf: file, encoding: .utf8))
            ?? "patch:\n  schema_list:\n"
        guard !text.contains("schema: \(id)") else { return }
        try? text.write(to: userDir.appendingPathComponent("default.custom.yaml.bak"),
                        atomically: true, encoding: .utf8)
        if let range = text.range(of: "schema_list:") {
            let insertAt = text.index(range.upperBound, offsetBy: 0)
            let lineEnd = text[insertAt...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            text.insert(contentsOf: "    - schema: \(id)\n", at: lineEnd)
        } else {
            text += "\npatch:\n  schema_list:\n    - schema: \(id)\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @objc private func deployAndRestart() {
        RimeBufferController.active?.forceCommit()
        info("开始部署…完成后输入法会自动重启。")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rimeEngine.start()
            let ok = BBRimeDeploy()
            IMELog.write("settings: deploy=\(ok), restarting")
            DispatchQueue.main.async {
                KeyFrequencyStore.shared.saveNow()
                exit(0)   // text-input system relaunches us
            }
        }
    }

    @objc private func bufferToggled() {
        BufferModel.shared.enabled = bufferCheck.state == .on
    }

    @objc private func appearanceChosen() {
        guard let raw = appearancePopUp.selectedItem?.representedObject as? String,
              let mode = RimeAppearanceMode(rawValue: raw) else { return }
        RimeUI.appearance = mode
        IMELog.write("appearance -> \(mode.rawValue)")
    }

    @objc private func statsDateChanged() {
        refreshStats()
    }

    @objc private func refreshStatsTapped() {
        refreshStats()
    }

    @objc private func clearStatsDay() {
        KeyFrequencyStore.shared.clear(day: statsDatePicker.dateValue)
        refreshStats()
    }

    @objc private func clearStatsAll() {
        KeyFrequencyStore.shared.clear(day: nil)
        refreshStats()
    }

    @objc private func openDir() {
        NSWorkspace.shared.open(userDir)
    }

    private func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
