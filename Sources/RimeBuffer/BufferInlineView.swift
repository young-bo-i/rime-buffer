import Cocoa

/// Compact buffer renderer that can live inside the candidate panel. It reads
/// from BufferModel only; delivery and clearing still go through the model.
final class BufferInlineView: NSView {
    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let leadingSpacer = NSView()
    private let emptyLabel = NSTextField(labelWithString: "等待暂存内容")
    private let flushButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "", target: nil, action: nil)

    var preferredHeight: CGFloat {
        34
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail

        configureIconButton(flushButton,
                            symbolName: "paperplane.fill",
                            toolTip: "发送到输入框")
        flushButton.target = self
        flushButton.action = #selector(flushTapped)

        configureIconButton(clearButton,
                            symbolName: "trash",
                            toolTip: "清空缓冲区")
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        chipRow.orientation = .horizontal
        chipRow.spacing = 5
        chipRow.alignment = .centerY
        chipRow.distribution = .fill
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.horizontalScrollElasticity = .allowed
        chipScroll.verticalScrollElasticity = .none
        chipScroll.documentView = chipRow
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chipScroll.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let controls = NSStackView(views: [flushButton, clearButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [chipScroll, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 7)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func refresh() -> Bool {
        let model = BufferModel.shared
        let shouldShow = model.shouldDisplay

        chipRow.arrangedSubviews.forEach {
            chipRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        chipRow.addArrangedSubview(leadingSpacer)
        if model.blocks.isEmpty {
            chipRow.addArrangedSubview(emptyLabel)
        } else {
            for block in model.blocks {
                chipRow.addArrangedSubview(chip(for: block))
            }
        }

        flushButton.isEnabled = !model.blocks.isEmpty
        clearButton.isEnabled = !model.blocks.isEmpty

        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToNewest()
        isHidden = !shouldShow
        return shouldShow
    }

    private func chip(for block: BufferModel.Block) -> NSView {
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = block.text

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(
            RimeUI.isNight ? 0.22 : 0.14
        ).cgColor
        box.layer?.cornerRadius = 6
        box.toolTip = block.text
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     symbolName: String,
                                     toolTip: String) {
        button.image = RimeUI.symbol(symbolName, pointSize: 13, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.toolTip = toolTip
        button.contentTintColor = RimeUI.textSecondary
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func updateChipDocumentSize() {
        let fit = chipRow.fittingSize
        let documentWidth = max(fit.width, chipScroll.contentSize.width)
        chipRow.setFrameSize(NSSize(width: documentWidth, height: 24))
        chipRow.needsLayout = true
        chipRow.layoutSubtreeIfNeeded()
    }

    private func scrollChipsToNewest() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.borderColor = RimeUI.borderStrong.cgColor
        emptyLabel.textColor = RimeUI.textMuted
        flushButton.contentTintColor = flushButton.isEnabled ? RimeUI.textSecondary : RimeUI.textMuted
        clearButton.contentTintColor = clearButton.isEnabled ? RimeUI.textSecondary : RimeUI.textMuted
    }

    @objc private func flushTapped() {
        BufferModel.shared.sendAllAndExit()
    }

    @objc private func clearTapped() {
        BufferModel.shared.clear()
    }
}

/// A button that works on the first click inside a never-key panel.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
