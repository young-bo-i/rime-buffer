import Cocoa
import CRimeBridge
import UniformTypeIdentifiers

/// Visual settings surface for schema management, appearance/buffer toggles,
/// and local key-frequency statistics.
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
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
    private var candidateMetricFields: [CandidateWindowMetric: NSTextField] = [:]
    private var candidateMetricSteppers: [CandidateWindowMetric: NSStepper] = [:]
    private let statsDatePicker = NSDatePicker()
    private let statsSummary = NSTextField(labelWithString: "")
    private let statsTopKey = NSTextField(labelWithString: "")
    private let installStatus = NSTextField(labelWithString: "")
    private let heatmapView = KeyboardHeatmapView()

    private var userDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/RimeBuffer")
    }

    private var installLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer-install.log")
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
        configureCandidateMetricControls()

        statsDatePicker.datePickerElements = [.yearMonthDay]
        statsDatePicker.datePickerStyle = .textFieldAndStepper
        statsDatePicker.dateValue = Date()
        statsDatePicker.target = self
        statsDatePicker.action = #selector(statsDateChanged)

        statsSummary.font = .systemFont(ofSize: 13, weight: .semibold)
        statsTopKey.font = .systemFont(ofSize: 12)
        statsTopKey.textColor = .secondaryLabelColor
        installStatus.font = .systemFont(ofSize: 11)
        installStatus.textColor = .tertiaryLabelColor
        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        heatmapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
    }

    private func configureCandidateMetricControls() {
        for metric in CandidateWindowMetric.allCases {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: metric.range.lowerBound)
            formatter.maximum = NSNumber(value: metric.range.upperBound)

            let field = NSTextField(string: "")
            field.formatter = formatter
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.target = self
            field.action = #selector(candidateMetricFieldChanged(_:))
            field.delegate = self
            field.tag = metric.tag
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true

            let stepper = NSStepper()
            stepper.minValue = metric.range.lowerBound
            stepper.maxValue = metric.range.upperBound
            stepper.increment = 1
            stepper.target = self
            stepper.action = #selector(candidateMetricStepperChanged(_:))
            stepper.tag = metric.tag

            candidateMetricFields[metric] = field
            candidateMetricSteppers[metric] = stepper
        }
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
        let reinstallBtn = NSButton(title: "重新安装输入法", target: self, action: #selector(reinstallInputMethod))
        let openInstallLogBtn = NSButton(title: "打开安装日志", target: self, action: #selector(openInstallLog))
        let installButtons = NSStackView(views: [reinstallBtn, openInstallLogBtn])
        installButtons.orientation = .horizontal
        installButtons.spacing = 8
        let installNote = NSTextField(wrappingLabelWithString:
            "从当前源码目录运行 build_install.sh；会重新构建、替换并重启 RimeBuffer。")
        installNote.font = .systemFont(ofSize: 11)
        installNote.textColor = .tertiaryLabelColor

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
            spacer(16),
            sectionLabel("安装"),
            installButtons,
            installStatus,
            installNote,
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
            spacer(16),
            sectionLabel("候选窗尺寸"),
            candidateMetricsView(),
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

    private func candidateMetricsView() -> NSView {
        let rows = CandidateWindowMetric.allCases.map(candidateMetricRow)
        let applyBtn = NSButton(title: "应用修改", target: self, action: #selector(applyCandidateMetrics))
        applyBtn.bezelStyle = .rounded
        applyBtn.bezelColor = .controlAccentColor

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetCandidateMetrics))
        resetBtn.bezelStyle = .rounded
        let actions = NSStackView(views: [applyBtn, resetBtn])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: rows + [actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        return stack
    }

    private func candidateMetricRow(_ metric: CandidateWindowMetric) -> NSView {
        let label = NSTextField(labelWithString: metric.title)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let unit = NSTextField(labelWithString: metric.unit)
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor
        unit.translatesAutoresizingMaskIntoConstraints = false
        unit.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let field = candidateMetricFields[metric] ?? NSTextField(string: "")
        let stepper = candidateMetricSteppers[metric] ?? NSStepper()
        field.removeFromSuperview()
        stepper.removeFromSuperview()

        let row = NSStackView(views: [label, field, stepper, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
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
        refreshCandidateMetricControls()
        refreshStats()
    }

    private func refreshCandidateMetricControls() {
        for metric in CandidateWindowMetric.allCases {
            let value = CandidateWindowMetrics.value(for: metric)
            candidateMetricFields[metric]?.stringValue = formatMetricValue(value)
            candidateMetricSteppers[metric]?.doubleValue = Double(value)
        }
    }

    private func formatMetricValue(_ value: CGFloat) -> String {
        "\(Int(value.rounded()))"
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

    @objc private func reinstallInputMethod() {
        guard let script = installScriptURL() else {
            info("找不到 build_install.sh。默认查找：~/Documents/DEV/rime-buffer 或 ~/Documents/05-dev/apps/rime-buffer。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "重新安装 RimeBuffer？"
        alert.informativeText = "将从 \(script.deletingLastPathComponent().path) 运行 build_install.sh。构建完成后当前输入法进程会被重启。"
        alert.addButton(withTitle: "重新安装")
        alert.addButton(withTitle: "取消")
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
            installStatus.stringValue = "安装已启动，日志：~/rimebuffer-install.log"
            IMELog.write("settings: launched install script \(script.path)")
        } catch {
            installStatus.stringValue = "安装启动失败"
            info("安装启动失败：\(error.localizedDescription)")
        }
    }

    private func installScriptURL() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Documents/DEV/rime-buffer/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer/build_install.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

    @objc private func candidateMetricFieldChanged(_ sender: NSTextField) {
        syncCandidateMetricControl(tag: sender.tag, value: sender.doubleValue)
    }

    @objc private func candidateMetricStepperChanged(_ sender: NSStepper) {
        syncCandidateMetricControl(tag: sender.tag, value: sender.doubleValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              candidateMetricFields.values.contains(where: { $0 === field }) else { return }
        syncCandidateMetricControl(tag: field.tag, value: field.doubleValue)
    }

    private func syncCandidateMetricControl(tag: Int, value: Double) {
        guard let metric = CandidateWindowMetric.fromTag(tag) else { return }
        let clamped = clamp(value, to: metric.range)
        candidateMetricFields[metric]?.stringValue = formatMetricValue(CGFloat(clamped))
        candidateMetricSteppers[metric]?.doubleValue = clamped
    }

    @objc private func applyCandidateMetrics() {
        window?.makeFirstResponder(nil)
        var values: [CandidateWindowMetric: Double] = [:]
        for metric in CandidateWindowMetric.allCases {
            let raw = candidateMetricFields[metric]?.doubleValue
                ?? candidateMetricSteppers[metric]?.doubleValue
                ?? metric.defaultValue
            values[metric] = clamp(raw, to: metric.range)
        }
        CandidateWindowMetrics.apply(values)
        refreshCandidateMetricControls()
    }

    @objc private func resetCandidateMetrics() {
        CandidateWindowMetrics.resetToDefaults()
        refreshCandidateMetricControls()
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
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

    @objc private func openInstallLog() {
        NSWorkspace.shared.open(installLogURL)
    }

    private func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
