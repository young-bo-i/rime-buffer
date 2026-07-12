import Cocoa
import QuartzCore

/// Compact buffer renderer that can live inside the candidate panel. It reads
/// from BufferModel only; delivery and clearing still go through the model.
final class BufferInlineView: NSView {
    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let leadingSpacer = NSView()
    private let caretView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "等待暂存内容")
    private let flushButton = HoldProgressButton(title: "", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "", target: nil, action: nil)

    var preferredHeight: CGFloat {
        34
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail

        configureIconButton(flushButton,
                            symbolName: "paperplane.fill",
                            toolTip: "按住 1.2 秒发送")
        flushButton.holdDuration = 1.2
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

        caretView.wantsLayer = true
        caretView.layer?.cornerRadius = 1
        caretView.translatesAutoresizingMaskIntoConstraints = false
        caretView.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caretView.heightAnchor.constraint(equalToConstant: 18).isActive = true

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
    func refresh(preedit: String = "") -> Bool {
        let model = BufferModel.shared
        let shouldShow = model.shouldDisplay
        let preeditText = preedit.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = model.active

        chipRow.arrangedSubviews.forEach {
            chipRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        chipRow.addArrangedSubview(leadingSpacer)

        let insertionIndex = min(max(model.insertionIndex, 0), model.blocks.count)
        if model.blocks.isEmpty, preeditText.isEmpty {
            emptyLabel.stringValue = model.loadingMessage ?? "等待暂存内容"
            chipRow.addArrangedSubview(emptyLabel)
            if active {
                chipRow.addArrangedSubview(caretView)
            }
        } else if active {
            for index in 0...model.blocks.count {
                if index == insertionIndex {
                    if !preeditText.isEmpty {
                        chipRow.addArrangedSubview(preeditChip(text: preeditText))
                    }
                    chipRow.addArrangedSubview(caretView)
                }
                if index < model.blocks.count {
                    chipRow.addArrangedSubview(chip(for: model.blocks[index]))
                }
            }
        } else {
            for block in model.blocks {
                chipRow.addArrangedSubview(chip(for: block))
            }
            if !preeditText.isEmpty {
                chipRow.addArrangedSubview(preeditChip(text: preeditText))
            }
        }

        active ? startCaretBlinking() : stopCaretBlinking()
        flushButton.isEnabled = !model.blocks.isEmpty
        clearButton.isEnabled = !model.blocks.isEmpty

        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToInsertionPoint()
        isHidden = !shouldShow
        return shouldShow
    }

    func setFlushProgress(_ progress: Double?) {
        flushButton.setExternalProgress(progress)
    }

    private func chip(for block: BufferModel.Block) -> NSView {
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = RimeUI.textPrimary
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

    private func preeditChip(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text
        label.textColor = RimeUI.textPrimary

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(
            RimeUI.isNight ? 0.34 : 0.22
        ).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        box.layer?.cornerRadius = 6
        box.toolTip = text
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

    private func scrollChipsToInsertionPoint() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        guard BufferModel.shared.active else {
            chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            chipScroll.reflectScrolledClipView(chipScroll.contentView)
            return
        }

        let visible = chipScroll.contentView.bounds
        let caretFrame = caretView.frame.insetBy(dx: -14, dy: 0)
        var targetX = visible.minX
        if caretFrame.minX < visible.minX {
            targetX = max(0, caretFrame.minX)
        } else if caretFrame.maxX > visible.maxX {
            targetX = max(0, min(maxX, caretFrame.maxX - chipScroll.contentSize.width))
        } else {
            targetX = min(max(0, visible.minX), maxX)
        }

        chipScroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.borderColor = RimeUI.borderStrong.cgColor
        caretView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        emptyLabel.textColor = RimeUI.isNight ? RimeUI.textSecondary : RimeUI.textMuted
        flushButton.contentTintColor = flushButton.isEnabled ? RimeUI.textSecondary : RimeUI.textMuted
        clearButton.contentTintColor = clearButton.isEnabled ? RimeUI.textSecondary : RimeUI.textMuted
    }

    private func startCaretBlinking() {
        guard caretView.layer?.animation(forKey: "bufferCaretBlink") == nil else { return }
        caretView.layer?.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.15
        animation.duration = 0.58
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caretView.layer?.add(animation, forKey: "bufferCaretBlink")
    }

    private func stopCaretBlinking() {
        caretView.layer?.removeAnimation(forKey: "bufferCaretBlink")
        caretView.layer?.opacity = 1
    }

    @objc private func flushTapped() {
        BufferModel.shared.sendAll()
    }

    @objc private func clearTapped() {
        BufferModel.shared.clear()
    }
}

/// A button that works on the first click inside a never-key panel.
class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HoldProgressButton: FirstMouseButton {
    var holdDuration: TimeInterval = 1.2

    private var holdStartedAt: CFAbsoluteTime = 0
    private var completed = false
    private var externalProgressActive = false
    private var progressAmount: CGFloat = 0
    private var progressVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupProgressDrawing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupProgressDrawing()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIconFillProgress()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        externalProgressActive = false
        beginHold()

        var tracking = true
        while tracking {
            if !completed {
                updateHoldProgress()
            }

            guard let window,
                  let next = window.nextEvent(
                    matching: NSEvent.EventTypeMask([.leftMouseDragged, .leftMouseUp]),
                    until: Date(timeIntervalSinceNow: 1.0 / 60.0),
                    inMode: .eventTracking,
                    dequeue: true
                  ) else {
                continue
            }

            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !bounds.insetBy(dx: -8, dy: -8).contains(point), !completed {
                    cancelHold()
                    tracking = false
                }
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }

        resetProgressAfterTracking()
    }

    func setExternalProgress(_ progress: Double?) {
        guard let progress else {
            guard externalProgressActive else { return }
            externalProgressActive = false
            setIconProgress(0, visible: false)
            return
        }

        externalProgressActive = true
        let clamped = CGFloat(min(max(progress, 0), 1))
        setIconProgress(clamped, visible: clamped > 0)
    }

    private func setupProgressDrawing() {
        wantsLayer = true
    }

    private func beginHold() {
        completed = false
        holdStartedAt = CFAbsoluteTimeGetCurrent()
        setIconProgress(0, visible: true)
    }

    private func updateHoldProgress() {
        let elapsed = CFAbsoluteTimeGetCurrent() - holdStartedAt
        let progress = min(max(elapsed / max(holdDuration, 0.1), 0), 1)
        setIconProgress(CGFloat(progress), visible: true)
        if progress >= 1 {
            completed = true
            sendAction(action, to: target)
        }
    }

    private func cancelHold() {
        completed = false
        setIconProgress(0, visible: false)
    }

    private func resetProgressAfterTracking() {
        if completed {
            setIconProgress(1, visible: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.externalProgressActive else { return }
            self.setIconProgress(0, visible: false)
            self.completed = false
        }
    }

    private func setIconProgress(_ progress: CGFloat, visible: Bool) {
        progressAmount = min(max(progress, 0), 1)
        progressVisible = visible
        needsDisplay = true
    }

    private func drawIconFillProgress() {
        guard progressVisible,
              progressAmount > 0,
              let symbol = image,
              let tinted = tintedSymbolImage(symbol, color: NSColor.controlAccentColor) else {
            return
        }

        let rect = iconRect(for: symbol)
        guard rect.width > 0, rect.height > 0 else { return }

        let fillHeight = rect.height * progressAmount
        let clipRect = isFlipped
            ? NSRect(x: rect.minX, y: rect.maxY - fillHeight, width: rect.width, height: fillHeight)
            : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillHeight)

        NSGraphicsContext.saveGraphicsState()
        clipRect.clip()
        tinted.draw(in: rect,
                    from: NSRect(origin: .zero, size: tinted.size),
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func iconRect(for symbol: NSImage) -> NSRect {
        let maxSide = max(1, min(bounds.width, bounds.height) - 8)
        let imageSize = symbol.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let scale = min(1, maxSide / max(imageSize.width, imageSize.height))
        let drawSize = NSSize(width: imageSize.width * scale,
                              height: imageSize.height * scale)
        return NSRect(x: bounds.midX - drawSize.width / 2,
                      y: bounds.midY - drawSize.height / 2,
                      width: drawSize.width,
                      height: drawSize.height)
    }

    private func tintedSymbolImage(_ symbol: NSImage, color: NSColor) -> NSImage? {
        let image = NSImage(size: symbol.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: nil)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
