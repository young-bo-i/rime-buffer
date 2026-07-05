import Cocoa

/// The visible staging strip (P2): a frosted, nonactivating panel pinned to
/// the bottom-center of the screen while buffer mode is ON. Passive display —
/// it can never become key and never steals focus from the field being typed
/// into; interaction is limited to first-mouse buttons.
final class BufferSurface {
    static let shared = BufferSurface()

    private let panel: NSPanel
    private let visual = NSVisualEffectView()
    private let previewBox = NSView()
    private let previewLabel = NSTextField(labelWithString: "")
    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let flushButton = FirstMouseButton(title: "发送到输入框", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "清空", target: nil, action: nil)
    var shouldSuppress: (() -> Bool)?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 110),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 1

        let title = NSTextField(labelWithString: "缓冲区")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        flushButton.title = "发送到输入框"
        flushButton.bezelStyle = .rounded
        flushButton.controlSize = .small
        flushButton.target = self
        flushButton.action = #selector(flushTapped)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, hint, spacer, flushButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 8

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 7
        previewBox.layer?.borderWidth = 1

        previewLabel.font = .systemFont(ofSize: 16)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -10),
            previewLabel.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            previewLabel.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -6),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])

        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.alignment = .centerY

        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.horizontalScrollElasticity = .allowed
        chipScroll.verticalScrollElasticity = .none
        chipScroll.documentView = chipRow
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let column = NSStackView(views: [header, previewBox, chipScroll])
        column.orientation = .vertical
        column.spacing = 6
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
        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
            self?.refresh()
        }
    }

    @objc private func flushTapped() { BufferModel.shared.flushAll() }
    @objc private func clearTapped() { BufferModel.shared.clear() }

    /// Re-render from the model. Used as a fallback when the candidate panel
    /// cannot host the inline buffer.
    func refresh() {
        if shouldSuppress?() == true {
            panel.orderOut(nil)
            return
        }
        let model = BufferModel.shared
        guard model.shouldDisplay else {
            panel.orderOut(nil)
            return
        }

        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, block) in model.blocks.enumerated() {
            chipRow.addArrangedSubview(chip(for: block, index: index))
        }
        let text = model.stagedText
        previewLabel.stringValue = text.isEmpty ? "暂无缓冲内容" : text
        previewLabel.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
        previewLabel.toolTip = text.isEmpty ? nil : text

        hint.stringValue = model.blocks.isEmpty
            ? "缓冲模式开启 · 提交的内容会先暂存在这里"
            : model.enabled
                ? "\(model.blocks.count) 块 · \(model.stagedCharacterCount) 字 · 等待手动上屏"
                : "\(model.blocks.count) 块未上屏 · 缓冲模式已关闭"
        flushButton.isEnabled = !model.blocks.isEmpty
        clearButton.isEnabled = !model.blocks.isEmpty
        chipScroll.isHidden = model.blocks.isEmpty

        applyAppearance()
        panel.layoutIfNeeded()
        let width = surfaceWidth(for: model)
        updateChipDocumentSize(width: width)
        panel.setContentSize(NSSize(width: width, height: model.blocks.isEmpty ? 82 : 118))
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.minY + 12))
        }
        panel.orderFrontRegardless()
        scrollChipsToNewest()
    }

    private func chip(for block: BufferModel.Block, index: Int) -> NSView {
        let indexLabel = NSTextField(labelWithString: "\(index + 1)")
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.alignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = block.text

        let row = NSStackView(views: [indexLabel, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        box.layer?.cornerRadius = 6
        box.toolTip = block.text
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            box.heightAnchor.constraint(equalToConstant: 28),
        ])
        return box
    }

    private func surfaceWidth(for model: BufferModel) -> CGFloat {
        let textWidth = measuredWidth(model.stagedText, font: previewLabel.font ?? .systemFont(ofSize: 16)) + 72
        let chipWidth = chipRow.fittingSize.width + 48
        return max(460, min(max(textWidth, chipWidth), 940))
    }

    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 360 }
        let sample = String(text.prefix(80)) as NSString
        return sample.size(withAttributes: [.font: font]).width
    }

    private func updateChipDocumentSize(width: CGFloat) {
        let fit = chipRow.fittingSize
        let documentWidth = max(fit.width, width - 24)
        chipRow.setFrameSize(NSSize(width: documentWidth, height: 30))
    }

    private func scrollChipsToNewest() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        visual.material = RimeUI.isNight ? .hudWindow : .popover
        visual.layer?.borderColor = (RimeUI.isNight
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.separatorColor.withAlphaComponent(0.45)).cgColor
        previewBox.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(
            RimeUI.isNight ? 0.16 : 0.65
        ).cgColor
        previewBox.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.30).cgColor
    }
}

/// A button that works on the first click inside a never-key panel.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
