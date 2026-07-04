import Cocoa

/// The visible staging strip (P2): a frosted, nonactivating panel pinned to
/// the bottom-center of the screen while buffer mode is ON. Passive display —
/// it can never become key and never steals focus from the field being typed
/// into; interaction is limited to first-mouse buttons.
final class BufferSurface {
    static let shared = BufferSurface()

    private let panel: NSPanel
    private let chipRow = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let flushButton = FirstMouseButton(title: "立即上屏", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "清空", target: nil, action: nil)

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let title = NSTextField(labelWithString: "缓冲区")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        flushButton.bezelStyle = .rounded
        flushButton.controlSize = .small
        flushButton.target = self
        flushButton.action = #selector(flushTapped)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let header = NSStackView(views: [title, hint, NSView(), flushButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 8

        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.alignment = .centerY

        let chipScroll = NSScrollView()
        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.verticalScrollElasticity = .none
        chipScroll.documentView = chipRow
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let column = NSStackView(views: [header, chipScroll])
        column.orientation = .vertical
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            column.topAnchor.constraint(equalTo: visual.topAnchor),
            column.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        panel.contentView = visual
    }

    @objc private func flushTapped() { BufferModel.shared.flushAll() }
    @objc private func clearTapped() { BufferModel.shared.clear() }

    /// Re-render from the model. Visible whenever buffer mode is ON.
    func refresh() {
        let model = BufferModel.shared
        guard model.enabled else {
            panel.orderOut(nil)
            return
        }

        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for block in model.blocks {
            chipRow.addArrangedSubview(chip(for: block))
        }
        hint.stringValue = model.blocks.isEmpty
            ? "缓冲模式开启 · 提交的内容会先暂存在这里"
            : "\(model.blocks.count) 块 · \(Int(model.lifetime))s 后自动上屏"
        flushButton.isEnabled = !model.blocks.isEmpty
        clearButton.isEnabled = !model.blocks.isEmpty

        panel.layoutIfNeeded()
        let width = max(420, min(chipRow.fittingSize.width + 48, 900))
        panel.setContentSize(NSSize(width: width, height: 64))
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.minY + 12))
        }
        panel.orderFrontRegardless()
    }

    private func chip(for block: BufferModel.Block) -> NSView {
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        box.layer?.cornerRadius = 6
        box.alphaValue = block.fadeStartedAt == nil ? 1.0 : 0.35   // fading = about to flush
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        return box
    }
}

/// A button that works on the first click inside a never-key panel.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
