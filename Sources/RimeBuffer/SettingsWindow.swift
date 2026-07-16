import Cocoa
import CRimeBridge

/// Central settings surface for input schemas, candidate UI, buffer mode,
/// remote typing, and local diagnostics.
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private enum Page: Int, CaseIterable {
        // 输入法组
        case input
        case candidateWindow
        case maintenance
        // 工作台组
        case buffer
        case connections
        case processors

        var title: String {
            switch self {
            case .input: return "输入"
            case .candidateWindow: return "候选窗"
            case .maintenance: return "维护"
            case .buffer: return "缓冲区"
            case .connections: return "连接"
            case .processors: return "处理器"
            }
        }

        var group: String {
            switch self {
            case .input, .candidateWindow, .maintenance: return "输入法"
            case .buffer, .connections, .processors: return "工作台"
            }
        }
    }

    private var window: NSWindow?
    private let sidebar = NSStackView()
    private let contentHost = NSView()
    private var navButtons: [Page: NSButton] = [:]
    private var selectedPage: Page = .input
    private var statsObserver: NSObjectProtocol?

    private var schemaChecks: [String: NSButton] = [:]
    private let currentSchemaLabel = NSTextField(labelWithString: "")
    private let schemaApplyStatus = NSTextField(labelWithString: "")
    private let appearancePopUp = NSPopUpButton()
    private let bufferCheck = NSButton(checkboxWithTitle: "启用缓冲模式（提交先暂存，手动确认上屏）", target: nil, action: nil)
    private let resetOnAppSwitchCheck = NSButton(checkboxWithTitle: "切换到其他应用时清空缓冲区", target: nil, action: nil)
    private var candidateMetricFields: [CandidateWindowMetric: NSTextField] = [:]
    private var candidateMetricSteppers: [CandidateWindowMetric: NSStepper] = [:]
    private let chordDurationField = NSTextField(string: "")
    private let chordDurationStepper = NSStepper()
    private let statsDatePicker = NSDatePicker()
    private let statsSummary = NSTextField(labelWithString: "")
    private let statsTopKey = NSTextField(labelWithString: "")
    private let installStatus = NSTextField(labelWithString: "")
    private let heatmapView = KeyboardHeatmapView()
    private let remoteCheck = NSButton(checkboxWithTitle: "启用隔空传字", target: nil, action: nil)
    private let remoteNameField = NSTextField(string: "")
    private let remoteStatusLabel = NSTextField(labelWithString: "")
    private let remoteDevicesStack = NSStackView()
    private var remoteDiscoveredIDs: [String] = []
    private var remoteTrustedKeys: [String] = []

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

    /// Dev-only: render one settings page to a PNG by drawing the window's own
    /// view hierarchy (no screen-recording permission needed). Used to preview
    /// the UI without a live input session.
    func renderForPreview(pageIndex: Int, to path: String) {
        if window == nil { build() }
        reload()
        showPage(Page(rawValue: pageIndex) ?? .buffer)
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        content.display()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    // MARK: UI construction

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Enter输入法 设置"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 860, height: 600)

        configureControls()

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        var lastGroup: String?
        for page in Page.allCases {
            if page.group != lastGroup {
                sidebar.addArrangedSubview(sidebarGroupHeader(page.group, first: lastGroup == nil))
                lastGroup = page.group
            }
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
            guard self?.selectedPage == .maintenance else { return }
            self?.refreshStats()
        }

        window = win
    }

    private func configureControls() {
        for (index, option) in InputSchemaCatalog.options.enumerated() {
            let button = NSButton(checkboxWithTitle: option.name,
                                  target: self,
                                  action: #selector(schemaToggled(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.toolTip = option.detail
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            schemaChecks[option.id] = button
        }
        currentSchemaLabel.font = .systemFont(ofSize: 12)
        currentSchemaLabel.textColor = .secondaryLabelColor
        schemaApplyStatus.font = .systemFont(ofSize: 11)
        schemaApplyStatus.textColor = .tertiaryLabelColor

        bufferCheck.target = self
        bufferCheck.action = #selector(bufferToggled)
        resetOnAppSwitchCheck.target = self
        resetOnAppSwitchCheck.action = #selector(resetOnAppSwitchToggled)

        appearancePopUp.removeAllItems()
        for mode in RimeAppearanceMode.allCases {
            appearancePopUp.addItem(withTitle: mode.title)
            appearancePopUp.lastItem?.representedObject = mode.rawValue
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(appearanceChosen)
        configureCandidateMetricControls()
        configureChordControl()

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

        remoteCheck.target = self
        remoteCheck.action = #selector(remoteToggled)
        remoteNameField.placeholderString = Host.current().localizedName ?? "Mac"
        remoteNameField.translatesAutoresizingMaskIntoConstraints = false
        remoteNameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        remoteStatusLabel.font = .systemFont(ofSize: 12)
        remoteStatusLabel.textColor = .secondaryLabelColor
        remoteDevicesStack.orientation = .vertical
        remoteDevicesStack.alignment = .leading
        remoteDevicesStack.spacing = 6
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

    private func configureChordControl() {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        formatter.minimum = NSNumber(value: ChordSettings.range.lowerBound)
        formatter.maximum = NSNumber(value: ChordSettings.range.upperBound)

        chordDurationField.formatter = formatter
        chordDurationField.alignment = .right
        chordDurationField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        chordDurationField.target = self
        chordDurationField.action = #selector(chordDurationFieldChanged)
        chordDurationField.delegate = self
        chordDurationField.translatesAutoresizingMaskIntoConstraints = false
        chordDurationField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        chordDurationStepper.minValue = ChordSettings.range.lowerBound
        chordDurationStepper.maxValue = ChordSettings.range.upperBound
        chordDurationStepper.increment = 0.01
        chordDurationStepper.valueWraps = false
        chordDurationStepper.target = self
        chordDurationStepper.action = #selector(chordDurationStepperChanged)
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
        case .input: pageView = inputPage()
        case .candidateWindow: pageView = candidateWindowPage()
        case .buffer: pageView = bufferPage()
        case .connections: pageView = connectionsPage()
        case .processors: pageView = processorsPage()
        case .maintenance: pageView = maintenancePage()
        }
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pageView.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor),
        ])
        if page == .maintenance { refreshStats() }
        if page == .connections { refreshRemoteStatus() }
    }

    private func sidebarGroupHeader(_ title: String, first: Bool) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let wrap = NSStackView(views: [label])
        wrap.orientation = .horizontal
        wrap.edgeInsets = NSEdgeInsets(top: first ? 2 : 12, left: 6, bottom: 4, right: 6)
        return wrap
    }

    private func inputPage() -> NSView {
        let deployBtn = NSButton(title: "应用方案并重启", target: self, action: #selector(deployAndRestart))
        deployBtn.bezelColor = .controlAccentColor

        let openDirBtn = NSButton(title: "打开配置目录", target: self, action: #selector(openDir))
        let note = NSTextField(wrappingLabelWithString:
            "配置目录是 ~/Library/RimeBuffer。未显示的方案文件仅作为词典或反查依赖保留，不会出现在 F4。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let chordNote = NSTextField(wrappingLabelWithString:
            "仅并击方案生效：多个键在此间隔内先后按下会合并成一次并击。值越小越跟手，太小容易漏字。默认 0.10 秒，修改后立即生效。")
        chordNote.font = .systemFont(ofSize: 11)
        chordNote.textColor = .tertiaryLabelColor

        return contentColumn([
            title("输入"),
            caption("勾选允许使用的方案；实际切换统一使用 F4。"),
            spacer(8),
            sectionLabel("F4 输入方案"),
            currentSchemaLabel,
            schemaChecklistView(),
            schemaApplyStatus,
            deployBtn,
            spacer(16),
            sectionLabel("并击间隔"),
            chordDurationRow(),
            chordNote,
            spacer(16),
            sectionLabel("配置目录"),
            openDirBtn,
            note,
        ])
    }

    private func chordDurationRow() -> NSView {
        let label = NSTextField(labelWithString: "并击间隔")
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor
        unit.translatesAutoresizingMaskIntoConstraints = false
        unit.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetChordDuration))
        resetBtn.bezelStyle = .rounded

        chordDurationField.removeFromSuperview()
        chordDurationStepper.removeFromSuperview()
        let row = NSStackView(views: [label, chordDurationField, chordDurationStepper, unit, resetBtn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func schemaChecklistView() -> NSView {
        let rows = InputSchemaCatalog.options.compactMap { option -> NSView? in
            guard let check = schemaChecks[option.id] else { return nil }
            check.removeFromSuperview()

            let detail = NSTextField(labelWithString: option.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingTail

            let row = NSStackView(views: [check, detail])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func candidateWindowPage() -> NSView {
        return contentColumn([
            title("候选窗"),
            caption("调整候选窗主题、尺寸和候选文字密度。"),
            spacer(8),
            sectionLabel("主题"),
            appearancePopUp,
            spacer(16),
            sectionLabel("尺寸与文字"),
            candidateMetricsView(),
        ])
    }

    private func bufferPage() -> NSView {
        let note = NSTextField(wrappingLabelWithString:
            "缓冲区开启后，Rime 提交内容会先进入输入法内部暂存区；按 Enter 手动发送，不会自动清空未确认内容。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let resetNote = NSTextField(wrappingLabelWithString:
            "开启后，焦点切到别的应用会清空未发送的暂存内容，避免缓冲内容跨应用残留。打开本设置窗不算切换应用。")
        resetNote.font = .systemFont(ofSize: 11)
        resetNote.textColor = .tertiaryLabelColor

        let secureNote = NSTextField(wrappingLabelWithString:
            "安全：当焦点位于密码框（系统安全输入生效）时，缓冲区内容不会被发送。此保护始终开启，无法关闭。")
        secureNote.font = .systemFont(ofSize: 11)
        secureNote.textColor = .tertiaryLabelColor

        return contentColumn([
            title("缓冲区"),
            caption("把提交内容先暂存，再由你确认发送到当前输入框。"),
            spacer(8),
            sectionLabel("模式"),
            bufferCheck,
            note,
            spacer(16),
            sectionLabel("安全与清理"),
            resetOnAppSwitchCheck,
            resetNote,
            spacer(8),
            secureNote,
        ])
    }

    private func connectionsPage() -> NSView {
        let applyNameBtn = NSButton(title: "应用名称", target: self, action: #selector(applyRemoteName))
        let nameRow = NSStackView(views: [remoteNameField, applyNameBtn])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 8

        let sourcesNote = NSTextField(wrappingLabelWithString:
            "外部来源把文字送进缓冲区，需你逐条接受后才成为可发送的块。以下来源即将支持。")
        sourcesNote.font = .systemFont(ofSize: 11)
        sourcesNote.textColor = .tertiaryLabelColor

        let sources = NSStackView(views: [
            comingSoonRow("本地智能体（MCP）", "Claude Code / Codex 通过 MCP 推送草稿", "M2"),
            comingSoonRow("HTTP 推送", "脚本经本地端口 POST 文字", "M2"),
            comingSoonRow("SSE 订阅", "订阅外部事件流，流式进缓冲区", "M6"),
            comingSoonRow("SSH", "远程主机命令输出流式进缓冲区", "M6"),
        ])
        sources.orientation = .vertical
        sources.alignment = .leading
        sources.spacing = 8

        return contentColumn([
            title("连接"),
            caption("配对设备与外部来源的收发与信任，都在这里管理。"),
            spacer(8),
            sectionLabel("配对设备（隔空传字）"),
            remoteCheck,
            remoteStatusLabel,
            spacer(8),
            secondaryLabel("本机名称"),
            nameRow,
            spacer(6),
            secondaryLabel("已配对设备"),
            remoteDevicesStack,
            spacer(16),
            sectionLabel("外部来源"),
            sourcesNote,
            sources,
        ])
    }

    private func processorsPage() -> NSView {
        let note = NSTextField(wrappingLabelWithString:
            "处理器在文字发送前对缓冲区内容做变换，结果作为新块回到缓冲区供你确认。以下处理器即将支持。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let procs = NSStackView(views: [
            comingSoonRow("翻译", "Apple 设备端翻译，中英互译，本地运行", "M3"),
            comingSoonRow("AI 润色 / 改写", "OpenAI 兼容接口，流式返回", "M4"),
        ])
        procs.orientation = .vertical
        procs.alignment = .leading
        procs.spacing = 8

        return contentColumn([
            title("处理器"),
            caption("发送前把缓冲区文字翻译或用 AI 改写。"),
            spacer(8),
            sectionLabel("可用处理器"),
            note,
            procs,
        ])
    }

    /// A disabled preview row for a not-yet-built connection/processor, with a
    /// milestone tag so the settings window shows where the workbench is going
    /// without pretending the control works yet.
    private func comingSoonRow(_ name: String, _ detail: String, _ milestone: String) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let textCol = NSStackView(views: [nameLabel, detailLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 1

        let tag = NSTextField(labelWithString: milestone)
        tag.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        tag.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [dot, textCol, flexSpacer(), tag])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        row.alphaValue = 0.7
        return row
    }

    private func maintenancePage() -> NSView {
        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refreshStatsTapped))
        let clearDayBtn = NSButton(title: "清空当天", target: self, action: #selector(clearStatsDay))
        let clearAllBtn = NSButton(title: "清空全部", target: self, action: #selector(clearStatsAll))
        let controls = NSStackView(views: [statsDatePicker, refreshBtn, flexSpacer(), clearDayBtn, clearAllBtn])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let checkUpdateBtn = NSButton(title: "检查更新…", target: self, action: #selector(checkUpdate))
        let openLogBtn = NSButton(title: "打开运行日志", target: self, action: #selector(openRuntimeLog))
        let restartBtn = NSButton(title: "重启输入法进程", target: self, action: #selector(restartInputMethod))
        let runtimeButtons = NSStackView(views: [checkUpdateBtn, openLogBtn, restartBtn])
        runtimeButtons.orientation = .horizontal
        runtimeButtons.spacing = 8

        let reinstallBtn = NSButton(title: "重新安装输入法", target: self, action: #selector(reinstallInputMethod))
        let openInstallLogBtn = NSButton(title: "打开安装日志", target: self, action: #selector(openInstallLog))
        let installButtons = NSStackView(views: [reinstallBtn, openInstallLogBtn])
        installButtons.orientation = .horizontal
        installButtons.spacing = 8
        let installNote = NSTextField(wrappingLabelWithString:
            "重新安装会从当前源码目录运行 build_install.sh，构建完成后替换并重启输入法进程。")
        installNote.font = .systemFont(ofSize: 11)
        installNote.textColor = .tertiaryLabelColor

        return contentColumn([
            title("维护"),
            caption("更新、日志、重启、重新安装和本地诊断。"),
            spacer(8),
            sectionLabel("运行状态"),
            runtimeButtons,
            spacer(12),
            sectionLabel("安装"),
            installButtons,
            installStatus,
            installNote,
            spacer(16),
            sectionLabel("按键统计"),
            caption("按天统计本输入法收到的物理按键次数；只保存按键计数，不保存输入内容。"),
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

    private func secondaryLabel(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
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
        var enabled = SchemaListStore.enabledIDs(at: userDir.appendingPathComponent("default.custom.yaml"))
        if enabled.isEmpty {
            enabled = InputSchemaCatalog.normalized(rimeEngine.schemaList().map(\.id))
        }
        if enabled.isEmpty { enabled = InputSchemaCatalog.defaultEnabledIDs }
        let enabledSet = Set(enabled)
        for option in InputSchemaCatalog.options {
            schemaChecks[option.id]?.state = enabledSet.contains(option.id) ? .on : .off
        }
        let currentName = StatusMenu.shared.schemaName.isEmpty
            ? (UserDefaults.standard.string(forKey: "preferredSchema") ?? "尚未载入")
            : StatusMenu.shared.schemaName
        currentSchemaLabel.stringValue = "当前：\(currentName) · 按 F4 切换"
        if schemaApplyStatus.stringValue.isEmpty {
            schemaApplyStatus.stringValue = "勾选项都会出现在 F4；至少保留一个。"
        }
        bufferCheck.state = BufferModel.shared.enabled ? .on : .off
        resetOnAppSwitchCheck.state = BufferModel.shared.resetOnAppSwitch ? .on : .off
        if let idx = (0..<appearancePopUp.numberOfItems).first(where: {
            appearancePopUp.item(at: $0)?.representedObject as? String == RimeUI.appearance.rawValue
        }) {
            appearancePopUp.selectItem(at: idx)
        }
        refreshCandidateMetricControls()
        refreshChordDurationControl()
        refreshRemoteStatus()
        refreshStats()
    }

    func remoteStatusDidChange() {
        guard selectedPage == .connections else { return }
        refreshRemoteStatus()
    }

    private func refreshCandidateMetricControls() {
        for metric in CandidateWindowMetric.allCases {
            let value = CandidateWindowMetrics.value(for: metric)
            candidateMetricFields[metric]?.stringValue = formatMetricValue(value)
            candidateMetricSteppers[metric]?.doubleValue = Double(value)
        }
    }

    private func refreshChordDurationControl() {
        let value = ChordSettings.duration
        chordDurationField.stringValue = String(format: "%.2f", value)
        chordDurationStepper.doubleValue = value
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

    private func refreshRemoteStatus() {
        remoteCheck.state = RemoteConfig.enabled ? .on : .off
        remoteNameField.stringValue = RemoteConfig.deviceName
        let status = RemoteTypingService.shared.status
        remoteStatusLabel.stringValue = "状态：\(RemoteTypingService.shared.statusSummary)"

        remoteDevicesStack.arrangedSubviews.forEach {
            remoteDevicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        remoteDiscoveredIDs.removeAll()
        remoteTrustedKeys.removeAll()

        guard RemoteConfig.enabled else {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("开启后会在局域网和附近设备中发现可配对的 Mac。"))
            return
        }

        let untrusted = status.discovered.filter { !$0.trusted }
        if !untrusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("发现的设备"))
            for peer in untrusted {
                let button = NSButton(title: "配对：\(peer.name)", target: self, action: #selector(pairRemoteDevice(_:)))
                button.tag = remoteDiscoveredIDs.count
                remoteDiscoveredIDs.append(peer.id)
                remoteDevicesStack.addArrangedSubview(button)
            }
        }

        if !status.trusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("已配对设备"))
            for peer in status.trusted {
                let button = NSButton(title: "取消配对：\(peer.name)", target: self, action: #selector(unpairRemoteDevice(_:)))
                button.tag = remoteTrustedKeys.count
                remoteTrustedKeys.append(peer.pubB64)
                remoteDevicesStack.addArrangedSubview(button)
            }
        }

        if untrusted.isEmpty, status.trusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("尚未发现设备。确认另一台 Mac 已开启隔空传字。"))
        }
    }

    // MARK: Actions

    @objc private func pageChosen(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        reload()
        showPage(page)
    }

    @objc private func schemaToggled(_ sender: NSButton) {
        let enabled = selectedSchemaIDs()
        guard !enabled.isEmpty else {
            sender.state = .on
            NSSound.beep()
            schemaApplyStatus.stringValue = "至少保留一个输入方案。"
            return
        }
        do {
            try persistSchemaSelection(enabled)
            schemaApplyStatus.stringValue = "已保存；点击「应用方案并重启」后更新 F4。"
        } catch {
            reload()
            info("保存方案失败：\(error.localizedDescription)")
        }
    }

    private func selectedSchemaIDs() -> [String] {
        InputSchemaCatalog.options.compactMap { option in
            schemaChecks[option.id]?.state == .on ? option.id : nil
        }
    }

    private func persistSchemaSelection(_ ids: [String]? = nil) throws {
        let enabled = ids ?? selectedSchemaIDs()
        try SchemaListStore.writeEnabledIDs(enabled,
                                            to: userDir.appendingPathComponent("default.custom.yaml"))
        let preferred = UserDefaults.standard.string(forKey: "preferredSchema") ?? ""
        if !enabled.contains(preferred), let fallback = enabled.first {
            UserDefaults.standard.set(fallback, forKey: "preferredSchema")
            IMELog.write("settings: disabled preferred schema \(preferred); fallback -> \(fallback)")
        }
        IMELog.write("settings: F4 schemas -> \(enabled.joined(separator: ","))")
    }

    @objc private func deployAndRestart() {
        do {
            try persistSchemaSelection()
        } catch {
            info("无法应用方案：\(error.localizedDescription)")
            return
        }
        RimeBufferController.active?.forceCommit()
        info("开始部署…完成后输入法会自动重启。")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rimeEngine.start()
            let ok = BBRimeDeploy()
            IMELog.write("settings: deploy=\(ok)")
            DispatchQueue.main.async {
                guard ok else {
                    self.info("部署失败，输入法没有重启。请查看运行日志。")
                    return
                }
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
        alert.messageText = "重新安装 Enter输入法？"
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
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/DEV/rime-buffer/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer/build_install.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @objc private func resetOnAppSwitchToggled() {
        BufferModel.shared.resetOnAppSwitch = resetOnAppSwitchCheck.state == .on
        IMELog.write("setting resetOnAppSwitch=\(resetOnAppSwitchCheck.state == .on)")
    }

    @objc private func bufferToggled() {
        BufferModel.shared.enabled = bufferCheck.state == .on
    }

    @objc private func remoteToggled() {
        RemoteConfig.enabled = remoteCheck.state == .on
        if RemoteConfig.enabled {
            RemoteTypingService.shared.restart()
        } else {
            RemoteTypingService.shared.stop()
        }
        IMELog.write("settings: remote typing enabled -> \(RemoteConfig.enabled)")
        refreshRemoteStatus()
    }

    @objc private func applyRemoteName() {
        let trimmed = remoteNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RemoteConfig.deviceName = trimmed
        if RemoteConfig.enabled { RemoteTypingService.shared.restart() }
        IMELog.write("settings: remote device name -> \(trimmed)")
        refreshRemoteStatus()
    }

    @objc private func pairRemoteDevice(_ sender: NSButton) {
        guard remoteDiscoveredIDs.indices.contains(sender.tag) else { return }
        RemoteTypingService.shared.requestPair(peerID: remoteDiscoveredIDs[sender.tag])
    }

    @objc private func unpairRemoteDevice(_ sender: NSButton) {
        guard remoteTrustedKeys.indices.contains(sender.tag) else { return }
        RemoteTypingService.shared.unpair(pubB64: remoteTrustedKeys[sender.tag])
    }

    @objc private func appearanceChosen() {
        guard let raw = appearancePopUp.selectedItem?.representedObject as? String,
              let mode = RimeAppearanceMode(rawValue: raw) else { return }
        RimeUI.appearance = mode
        IMELog.write("appearance -> \(mode.rawValue)")
    }

    @objc private func chordDurationFieldChanged() {
        applyChordDuration(chordDurationField.doubleValue)
    }

    @objc private func chordDurationStepperChanged() {
        applyChordDuration(chordDurationStepper.doubleValue)
    }

    @objc private func resetChordDuration() {
        window?.makeFirstResponder(nil)
        ChordSettings.resetToDefault()
        refreshChordDurationControl()
    }

    /// Persist + broadcast the new chord window (setter clamps to range), then
    /// snap the field/stepper back to the stored value.
    private func applyChordDuration(_ value: Double) {
        ChordSettings.duration = value
        refreshChordDurationControl()
    }

    @objc private func candidateMetricFieldChanged(_ sender: NSTextField) {
        syncCandidateMetricControl(tag: sender.tag, value: sender.doubleValue)
    }

    @objc private func candidateMetricStepperChanged(_ sender: NSStepper) {
        syncCandidateMetricControl(tag: sender.tag, value: sender.doubleValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === chordDurationField {
            applyChordDuration(field.doubleValue)
            return
        }
        guard candidateMetricFields.values.contains(where: { $0 === field }) else { return }
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

    @objc private func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    @objc private func openRuntimeLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func restartInputMethod() {
        RimeBufferController.active?.forceCommit()
        KeyFrequencyStore.shared.saveNow()
        IMELog.write("settings: restart requested")
        exit(0)
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
