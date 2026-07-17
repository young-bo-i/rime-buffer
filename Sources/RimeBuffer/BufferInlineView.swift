import Cocoa
import QuartzCore

/// Compact block rail used by the independent workbench window. It never holds
/// an IMK client or action buttons: delivery/clear live in the expandable
/// controller shelf, while this view only renders and selects staged blocks.
final class BufferInlineView: NSView {
    private struct RenderedBlock: Equatable {
        let id: UUID
        let text: String
        let origin: Origin
    }

    private struct RenderSignature: Equatable {
        let blocks: [RenderedBlock]
        let insertionIndex: Int
        let active: Bool
        let preedit: String
        let loadingMessage: String?
        let shielded: Bool
        let selectedBlockID: UUID?
        let isNight: Bool
    }

    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let leadingSpacer = NSView()
    private let caretView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "等待暂存内容")
    private let enterHoldProgressLayer = CALayer()
    private var renderedBlockIDs: [UUID] = []
    private var lastRenderSignature: RenderSignature?
    private var contentShielded = false
    private var enterHoldProgress: CGFloat?
    private(set) var selectedBlockID: UUID?
    private(set) var renderPassCount = 0
    var onSelectionChange: ((UUID?) -> Void)?
    var renderedBlockCount: Int { renderedBlockIDs.count }
    var isEnterHoldProgressVisible: Bool { enterHoldProgress != nil }
    var canClearContent: Bool {
        !contentShielded
            && (!BufferModel.shared.blocks.isEmpty
                || BufferModel.shared.loadingMessage != nil)
    }

    var preferredHeight: CGFloat {
        34
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        enterHoldProgressLayer.cornerRadius = 1
        enterHoldProgressLayer.zPosition = 50
        enterHoldProgressLayer.opacity = 0
        layer?.addSublayer(enterHoldProgressLayer)
        updateHairlineWidth()

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail

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

        let row = NSStackView(views: [chipScroll])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHairlineWidth()
    }

    override func layout() {
        super.layout()
        updateHairlineWidth()
        updateEnterHoldProgressLayer()
    }

    private func updateHairlineWidth() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.borderWidth = 1 / max(scale, 1)
    }

    func setEnterHoldProgress(_ progress: Double?) {
        enterHoldProgress = progress.map { CGFloat(min(max($0, 0), 1)) }
        updateEnterHoldProgressLayer()
    }

    private func updateEnterHoldProgressLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let enterHoldProgress {
            enterHoldProgressLayer.opacity = 1
            enterHoldProgressLayer.frame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width * enterHoldProgress,
                height: 2
            )
        } else {
            enterHoldProgressLayer.opacity = 0
            enterHoldProgressLayer.frame = .zero
        }
        CATransaction.commit()
    }

    @discardableResult
    func refresh(preedit: String = "", shielded: Bool = false) -> Bool {
        let model = BufferModel.shared
        let preeditText = preedit.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = model.active
        contentShielded = shielded
        if shielded {
            setEnterHoldProgress(nil)
        }

        let signature = RenderSignature(
            blocks: model.blocks.map { RenderedBlock(id: $0.id, text: $0.text, origin: $0.origin) },
            insertionIndex: min(max(model.insertionIndex, 0), model.blocks.count),
            active: active,
            preedit: preeditText,
            loadingMessage: model.loadingMessage,
            shielded: shielded,
            selectedBlockID: selectedBlockID,
            isNight: RimeUI.isNight
        )
        if signature == lastRenderSignature {
            isHidden = shielded
            applyAppearance()
            return false
        }
        lastRenderSignature = signature
        renderPassCount += 1

        chipRow.arrangedSubviews.forEach {
            chipRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        renderedBlockIDs.removeAll(keepingCapacity: true)
        chipRow.addArrangedSubview(leadingSpacer)

        if shielded {
            emptyLabel.stringValue = "内容已隐藏"
            chipRow.addArrangedSubview(emptyLabel)
            stopCaretBlinking()
            isHidden = true
            applyAppearance()
            return true
        }

        let insertionIndex = signature.insertionIndex
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
                    chipRow.addArrangedSubview(chip(for: model.blocks[index], index: index))
                }
            }
        } else {
            for (index, block) in model.blocks.enumerated() {
                chipRow.addArrangedSubview(chip(for: block, index: index))
            }
            if !preeditText.isEmpty {
                chipRow.addArrangedSubview(preeditChip(text: preeditText))
            }
        }

        active ? startCaretBlinking() : stopCaretBlinking()
        if let selectedBlockID,
           !model.blocks.contains(where: { $0.id == selectedBlockID }) {
            self.selectedBlockID = nil
            onSelectionChange?(nil)
        }
        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToInsertionPoint()
        isHidden = false
        return true
    }

    /// Colored provenance dot for a non-local block. Rime commits (local typing)
    /// stay unbadged so ordinary use looks exactly as before; external origins
    /// get a 6pt dot whose color matches the source family.
    private func originBadge(for origin: Origin) -> NSView? {
        let color: NSColor
        switch origin {
        case .rime: return nil
        case .remotePeer: color = RimeUI.color(0x9B8CFF)        // paired Mac — violet
        case .marine, .mcp: color = RimeUI.color(0xF59E0B)      // local agent — amber
        case .http, .sse, .ssh: color = RimeUI.color(0x4A9FD8)  // network feed — blue
        }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return dot
    }

    private func chip(for block: BufferModel.Block, index: Int) -> NSView {
        if renderedBlockIDs.count <= index {
            renderedBlockIDs.append(block.id)
        } else {
            renderedBlockIDs[index] = block.id
        }
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = RimeUI.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = block.text

        let row = NSStackView(views: [label])
        if let badge = originBadge(for: block.origin) {
            row.insertArrangedSubview(badge, at: 0)
            row.setCustomSpacing(5, after: badge)
        }
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = FirstMouseButton(title: "", target: self, action: #selector(blockTapped(_:)))
        box.tag = index
        box.isBordered = false
        box.focusRingType = .none
        box.setButtonType(.momentaryChange)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(
            RimeUI.isNight ? 0.22 : 0.14
        ).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = selectedBlockID == block.id ? 1 : 0
        box.layer?.borderColor = NSColor.controlAccentColor.cgColor
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
        enterHoldProgressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        emptyLabel.textColor = RimeUI.isNight ? RimeUI.textSecondary : RimeUI.textMuted
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

    @objc private func blockTapped(_ sender: NSButton) {
        guard renderedBlockIDs.indices.contains(sender.tag) else { return }
        let id = renderedBlockIDs[sender.tag]
        selectedBlockID = selectedBlockID == id ? nil : id
        onSelectionChange?(selectedBlockID)
        _ = refresh()
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
