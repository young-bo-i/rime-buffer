import Cocoa

/// Compact buffer renderer that can live inside the candidate panel. It reads
/// from BufferModel only; delivery and clearing still go through the model.
final class BufferInlineView: NSView {
    private let titleLabel = NSTextField(labelWithString: "缓冲区")
    private let hintLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let flushButton = FirstMouseButton(title: "发送", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "清空", target: nil, action: nil)

    private let previewBox = NSView()
    private var hasBlocks = false

    var preferredHeight: CGFloat {
        hasBlocks ? 86 : 30
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        flushButton.bezelStyle = .rounded
        flushButton.controlSize = .mini
        flushButton.target = self
        flushButton.action = #selector(flushTapped)

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .mini
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, hintLabel, spacer, flushButton, clearButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 7
        previewBox.layer?.borderWidth = 1

        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
            previewLabel.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 4),
            previewLabel.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -4),
            previewBox.heightAnchor.constraint(equalToConstant: 28),
        ])

        chipRow.orientation = .horizontal
        chipRow.spacing = 5
        chipRow.alignment = .centerY

        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.horizontalScrollElasticity = .allowed
        chipScroll.verticalScrollElasticity = .none
        chipScroll.documentView = chipRow
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let column = NSStackView(views: [header, previewBox, chipScroll])
        column.orientation = .vertical
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 5, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func refresh() -> Bool {
        let model = BufferModel.shared
        let shouldShow = model.shouldDisplay
        hasBlocks = !model.blocks.isEmpty

        chipRow.arrangedSubviews.forEach {
            chipRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, block) in model.blocks.enumerated() {
            chipRow.addArrangedSubview(chip(for: block, index: index))
        }

        let text = model.stagedText
        previewLabel.stringValue = text
        previewLabel.toolTip = text.isEmpty ? nil : text
        previewLabel.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor

        hintLabel.stringValue = model.blocks.isEmpty
            ? "等待暂存内容"
            : "\(model.blocks.count) 块 · \(model.stagedCharacterCount) 字"
        flushButton.isHidden = model.blocks.isEmpty
        clearButton.isHidden = model.blocks.isEmpty
        flushButton.isEnabled = !model.blocks.isEmpty
        clearButton.isEnabled = !model.blocks.isEmpty
        previewBox.isHidden = model.blocks.isEmpty
        chipScroll.isHidden = model.blocks.isEmpty

        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToNewest()
        isHidden = !shouldShow
        return shouldShow
    }

    private func chip(for block: BufferModel.Block, index: Int) -> NSView {
        let indexLabel = NSTextField(labelWithString: "\(index + 1)")
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.alignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = block.text

        let row = NSStackView(views: [indexLabel, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3

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

    private func updateChipDocumentSize() {
        let fit = chipRow.fittingSize
        let documentWidth = max(fit.width, chipScroll.contentSize.width)
        chipRow.setFrameSize(NSSize(width: documentWidth, height: 24))
    }

    private func scrollChipsToNewest() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.borderColor = RimeUI.borderStrong.cgColor
        titleLabel.textColor = RimeUI.textSecondary
        hintLabel.textColor = RimeUI.textMuted
        previewBox.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(
            RimeUI.isNight ? 0.14 : 0.62
        ).cgColor
        previewBox.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
    }

    @objc private func flushTapped() {
        BufferModel.shared.flushAll()
    }

    @objc private func clearTapped() {
        BufferModel.shared.clear()
    }
}
