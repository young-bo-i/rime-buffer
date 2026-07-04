import Cocoa
import CRimeBridge

/// Visual settings (v1) — the "modern IME" configuration surface:
///   · 方案管理: list deployed schemas, import a .schema.yaml (auto-added to
///     schema_list), export one, redeploy-and-restart in place.
///   · 缓冲区: enable + block lifetime.
/// Lives in the IME process; shown from the status menu.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let schemaPopUp = NSPopUpButton()
    private let bufferCheck = NSButton(checkboxWithTitle: "启用缓冲模式（提交先暂存，到期自动上屏）", target: nil, action: nil)
    private let lifetimeSlider = NSSlider(value: 3, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let lifetimeLabel = NSTextField(labelWithString: "3 秒")

    private var userDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/RimeBuffer")
    }

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: UI construction

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "RimeBuffer 设置"
        win.isReleasedWhenClosed = false

        func sectionLabel(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }

        schemaPopUp.target = self
        schemaPopUp.action = #selector(schemaChosen)

        let importBtn = NSButton(title: "导入方案…", target: self, action: #selector(importSchema))
        let exportBtn = NSButton(title: "导出选中方案…", target: self, action: #selector(exportSchema))
        let deployBtn = NSButton(title: "重新部署并重启", target: self, action: #selector(deployAndRestart))
        deployBtn.bezelColor = .controlAccentColor
        let schemaButtons = NSStackView(views: [importBtn, exportBtn, deployBtn])
        schemaButtons.orientation = .horizontal
        schemaButtons.spacing = 8

        bufferCheck.target = self
        bufferCheck.action = #selector(bufferToggled)
        lifetimeSlider.target = self
        lifetimeSlider.action = #selector(lifetimeChanged)
        let lifetimeRow = NSStackView(views: [NSTextField(labelWithString: "块存活时间"), lifetimeSlider, lifetimeLabel])
        lifetimeRow.orientation = .horizontal
        lifetimeRow.spacing = 8
        lifetimeSlider.translatesAutoresizingMaskIntoConstraints = false
        lifetimeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let openDirBtn = NSButton(title: "打开配置目录", target: self, action: #selector(openDir))
        let note = NSTextField(wrappingLabelWithString:
            "配置目录是 ~/Library/RimeBuffer（独立于 Squirrel 的 ~/Library/Rime，避免词库锁冲突）。导入的方案会自动加入 schema_list；改动配置后点「重新部署并重启」生效。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let column = NSStackView(views: [
            sectionLabel("方案管理（并击 / 串击 / 自定义）"),
            schemaPopUp, schemaButtons,
            spacer(12),
            sectionLabel("缓冲区"),
            bufferCheck, lifetimeRow,
            spacer(12),
            openDirBtn, note,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        win.contentView = NSView()
        win.contentView!.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
            column.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
        ])
        window = win
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
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
        lifetimeSlider.doubleValue = BufferModel.shared.lifetime
        lifetimeLabel.stringValue = "\(Int(BufferModel.shared.lifetime)) 秒"
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

    @objc private func schemaChosen() {
        guard let id = schemaPopUp.selectedItem?.representedObject as? String else { return }
        RimeBufferController.applyPreferredSchema(id)
    }

    @objc private func importSchema() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["yaml"]
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
            DispatchQueue.main.async { exit(0) }   // text-input system relaunches us
        }
    }

    @objc private func bufferToggled() {
        BufferModel.shared.enabled = bufferCheck.state == .on
    }

    @objc private func lifetimeChanged() {
        BufferModel.shared.lifetime = lifetimeSlider.doubleValue.rounded()
        lifetimeLabel.stringValue = "\(Int(lifetimeSlider.doubleValue.rounded())) 秒"
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
