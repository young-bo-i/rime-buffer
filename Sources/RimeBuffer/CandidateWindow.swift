import Cocoa

/// In-process candidate window. The default view is a compact horizontal strip;
/// Down opens a 3-row picker so every current-page candidate remains selectable.
final class CandidateWindow {
    private let panel: NSPanel
    private let root = NSStackView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let candidateScroll = NSScrollView()
    private let candidateStack = NSStackView()
    private let pageButton = CandidateActionButton(symbolName: "chevron.down", title: "")
    private let settingsButton = CandidateActionButton(symbolName: "gearshape", title: "设置")
    private let inlineBuffer = BufferInlineView()
    private var stripHeightConstraint: NSLayoutConstraint!
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var inlineBufferHeightConstraint: NSLayoutConstraint!
    private var lastGoodRect: [String: NSRect] = [:]

    private var currentContext = RimeContextModel()
    private var currentSignature = ""
    private var selectedIndex = 0
    private var gridExpanded = false
    private var bufferOnly = false
    private var lastCaretRect = NSRect.zero
    private var lastBundleId = ""
    private var lastShowPreedit = false

    var onSelect: ((Int) -> Void)?
    var onSettings: (() -> Void)?
    var onInlineBufferVisibilityChanged: (() -> Void)?

    var hasCandidates: Bool { panel.isVisible && !currentContext.candidates.isEmpty }
    var isShowingInlineBuffer: Bool { panel.isVisible && !inlineBuffer.isHidden }
    var isGridExpanded: Bool { gridExpanded }
    var selectedCandidateIndex: Int? {
        guard hasCandidates else { return nil }
        return clamp(selectedIndex, count: currentContext.candidates.count)
    }

    private let baseWidth: CGFloat = 500
    private let compactStripHeight: CGFloat = 44
    private let expandedStripHeight: CGFloat = 126
    private let compactCandidateHeight: CGFloat = 34
    private let expandedCandidateHeight: CGFloat = 114
    private let preeditHeight: CGFloat = 24
    private let candidateFontSize: CGFloat = 18
    private let labelFontSize: CGFloat = 13

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: baseWidth, height: compactStripHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        preeditLabel.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        preeditLabel.lineBreakMode = .byTruncatingTail
        preeditLabel.isHidden = true
        preeditLabel.heightAnchor.constraint(equalToConstant: preeditHeight).isActive = true

        strip.wantsLayer = true
        strip.layer?.cornerRadius = 12
        strip.layer?.borderWidth = 1
        strip.layer?.masksToBounds = true
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: compactStripHeight)
        stripHeightConstraint.isActive = true

        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = 6
        candidateStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        candidateScroll.drawsBackground = false
        candidateScroll.hasHorizontalScroller = false
        candidateScroll.hasVerticalScroller = false
        candidateScroll.horizontalScrollElasticity = .none
        candidateScroll.verticalScrollElasticity = .none
        candidateScroll.documentView = candidateStack
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateHeightConstraint = candidateScroll.heightAnchor.constraint(equalToConstant: compactCandidateHeight)
        candidateHeightConstraint.isActive = true

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 30).isActive = true

        pageButton.target = self
        pageButton.action = #selector(toggleGridTapped)
        pageButton.toolTip = "展开候选"
        pageButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        pageButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "打开设置"
        settingsButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let barRow = NSStackView(views: [candidateScroll, divider, pageButton, settingsButton])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = 7
        barRow.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(barRow)
        NSLayoutConstraint.activate([
            barRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 7),
            barRow.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -7),
            barRow.topAnchor.constraint(equalTo: strip.topAnchor, constant: 5),
            barRow.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -5),
        ])

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(preeditLabel)
        root.addArrangedSubview(strip)
        root.addArrangedSubview(inlineBuffer)
        inlineBuffer.isHidden = true
        inlineBufferHeightConstraint = inlineBuffer.heightAnchor.constraint(equalToConstant: 0)
        inlineBufferHeightConstraint.isActive = true

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preeditLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            preeditLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            inlineBuffer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            inlineBuffer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        panel.contentView = content

        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
            self?.renderCandidates()
            self?.refreshBuffer()
        }
    }

    func update(_ ctx: RimeContextModel, caretRect: NSRect, bundleId: String, showPreedit: Bool) {
        guard !ctx.candidates.isEmpty || (showPreedit && !ctx.preedit.isEmpty) else {
            hide()
            return
        }

        let sameComposition = ctx.input == currentContext.input && ctx.preedit == currentContext.preedit
        let signature = contextSignature(ctx)
        if signature != currentSignature {
            selectedIndex = clamp(ctx.highlightedIndex, count: ctx.candidates.count)
            currentSignature = signature
        }
        if !sameComposition { gridExpanded = false }

        currentContext = ctx
        bufferOnly = false
        lastCaretRect = caretRect
        lastBundleId = bundleId
        lastShowPreedit = showPreedit

        preeditLabel.stringValue = showPreedit ? (ctx.preedit.isEmpty ? ctx.input : ctx.preedit) : ""
        preeditLabel.isHidden = preeditLabel.stringValue.isEmpty
        applyAppearance()
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: caretRect, bundleId: bundleId)
        panel.orderFrontRegardless()
        onInlineBufferVisibilityChanged?()
    }

    func showBufferOnly(caretRect: NSRect, bundleId: String) {
        guard BufferModel.shared.shouldDisplay else {
            hide()
            return
        }
        bufferOnly = true
        gridExpanded = false
        currentContext = RimeContextModel()
        currentSignature = ""
        selectedIndex = 0
        lastCaretRect = caretRect
        lastBundleId = bundleId
        lastShowPreedit = false
        preeditLabel.stringValue = ""
        preeditLabel.isHidden = true
        applyAppearance()
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: caretRect, bundleId: bundleId)
        panel.orderFrontRegardless()
        onInlineBufferVisibilityChanged?()
    }

    func hide() {
        let wasShowingInlineBuffer = isShowingInlineBuffer
        gridExpanded = false
        bufferOnly = false
        panel.orderOut(nil)
        if wasShowingInlineBuffer {
            onInlineBufferVisibilityChanged?()
        }
    }

    func refreshBuffer() {
        refreshInlineBuffer()
        guard panel.isVisible else {
            onInlineBufferVisibilityChanged?()
            return
        }
        if inlineBuffer.isHidden, currentContext.candidates.isEmpty, preeditLabel.isHidden {
            hide()
            return
        }
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        onInlineBufferVisibilityChanged?()
    }

    @discardableResult
    func expandGrid() -> Bool {
        guard !currentContext.candidates.isEmpty else { return false }
        gridExpanded = true
        renderCandidates()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    func collapseGrid() -> Bool {
        guard gridExpanded else { return false }
        gridExpanded = false
        renderCandidates()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        guard !currentContext.candidates.isEmpty else { return false }
        selectedIndex = clamp(selectedIndex + delta, count: currentContext.candidates.count)
        renderCandidates()
        scrollSelectedIntoView()
        return true
    }

    // MARK: Positioning

    private func layoutPanel(caretRect: NSRect, bundleId: String) {
        let width = panelWidth(for: currentContext, caretRect: caretRect)
        let bufferHeight = inlineBuffer.isHidden ? 0 : inlineBuffer.preferredHeight + root.spacing
        let height = (gridExpanded ? expandedStripHeight : compactStripHeight)
            + (preeditLabel.isHidden ? 0 : preeditHeight + root.spacing)
            + bufferHeight
        panel.setContentSize(NSSize(width: width, height: height))
        panel.layoutIfNeeded()
        updateCandidateDocumentSize()
        scrollSelectedIntoView()
        panel.setFrameOrigin(origin(for: caretRect, bundleId: bundleId))
    }

    private func origin(for caretRect: NSRect, bundleId: String) -> NSPoint {
        var anchor = caretRect
        if isPlausible(anchor) {
            lastGoodRect[bundleId] = anchor
        } else if let cached = lastGoodRect[bundleId] {
            anchor = cached
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 120)
        }

        let screen = screen(containing: anchor)
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.minX
        var y = anchor.minY - panel.frame.height - 6
        if y < vf.minY { y = anchor.maxY + 6 }
        x = min(max(x, vf.minX + 6), vf.maxX - panel.frame.width - 6)
        y = min(max(y, vf.minY + 6), vf.maxY - panel.frame.height - 6)
        return NSPoint(x: x, y: y)
    }

    private func isPlausible(_ r: NSRect) -> Bool {
        guard r != .zero, r.height > 2, r.height < 300 else { return false }
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(r.origin) }
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -8, dy: -8).contains(rect.origin) }
            ?? NSScreen.main
    }

    private func panelWidth(for ctx: RimeContextModel, caretRect: NSRect) -> CGFloat {
        let visibleWidth = (screen(containing: caretRect)?.visibleFrame.width ?? baseWidth) - 12
        let firstWidth = ctx.candidates.first.map {
            measuredCandidateWidth($0, highlighted: selectedIndex == 0, compact: true)
        } ?? 0
        let minimumForFirstCandidate = firstWidth + 124
        return min(max(baseWidth, minimumForFirstCandidate), max(420, visibleWidth))
    }

    // MARK: Rendering

    private func renderCandidates() {
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        stripHeightConstraint.constant = gridExpanded ? expandedStripHeight : compactStripHeight
        candidateHeightConstraint.constant = gridExpanded ? expandedCandidateHeight : compactCandidateHeight
        pageButton.isEnabled = !bufferOnly && !currentContext.candidates.isEmpty
        candidateScroll.isHidden = false
        pageButton.image = RimeUI.symbol(gridExpanded ? "chevron.up" : "chevron.down",
                                         pointSize: 17,
                                         weight: .semibold)
        pageButton.toolTip = gridExpanded ? "收起候选" : "展开候选"

        if bufferOnly {
            applyAppearance()
            updateCandidateDocumentSize()
            return
        } else if gridExpanded {
            renderGrid()
        } else {
            renderCompactRow()
        }
        applyAppearance()
        updateCandidateDocumentSize()
    }

    private func refreshInlineBuffer() {
        let visible = inlineBuffer.refresh()
        inlineBufferHeightConstraint.constant = visible ? inlineBuffer.preferredHeight : 0
    }

    private func renderCompactRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = 6

        for (i, c) in currentContext.candidates.enumerated() {
            candidateStack.addArrangedSubview(candidateButton(
                index: i,
                candidate: c,
                highlighted: i == selectedIndex,
                compact: true,
                width: nil
            ))
        }
    }

    private func renderGrid() {
        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = 5

        let count = currentContext.candidates.count
        guard count > 0 else { return }
        let rows = min(3, count)
        let columns = Int(ceil(Double(count) / Double(rows)))
        let cellWidth = gridCellWidth(columns: columns)

        for rowIndex in 0..<rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false

            let start = rowIndex * columns
            let end = min(start + columns, count)
            guard start < end else { continue }
            for i in start..<end {
                row.addArrangedSubview(candidateButton(
                    index: i,
                    candidate: currentContext.candidates[i],
                    highlighted: i == selectedIndex,
                    compact: false,
                    width: cellWidth
                ))
            }
            candidateStack.addArrangedSubview(row)
        }
    }

    private func candidateButton(
        index: Int,
        candidate: RimeCandidateModel,
        highlighted: Bool,
        compact: Bool,
        width: CGFloat?
    ) -> NSButton {
        let button = CandidatePillButton()
        button.tag = index
        button.target = self
        button.action = #selector(candidateTapped(_:))
        button.attributedTitle = candidateTitle(candidate, highlighted: highlighted)
        button.layer?.backgroundColor = highlighted
            ? RimeUI.selectedCandidateColor.cgColor
            : NSColor.clear.cgColor
        button.layer?.borderColor = highlighted
            ? NSColor.clear.cgColor
            : RimeUI.border.withAlphaComponent(0.35).cgColor
        button.layer?.borderWidth = highlighted ? 0 : 1
        button.toolTip = candidate.comment.isEmpty
            ? candidate.text
            : "\(candidate.text)  \(candidate.comment)"

        let naturalWidth = ceil(measuredCandidateWidth(candidate, highlighted: highlighted, compact: compact))
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width ?? naturalWidth),
            button.heightAnchor.constraint(equalToConstant: compact ? 34 : 32),
        ])
        return button
    }

    private func candidateTitle(_ c: RimeCandidateModel, highlighted: Bool) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let labelColor = highlighted ? NSColor.white.withAlphaComponent(0.86) : RimeUI.textMuted
        let textColor = highlighted ? NSColor.white : RimeUI.textSecondary
        let baseline = (candidateFontSize - labelFontSize) / 2

        line.append(NSAttributedString(
            string: "\(c.label.isEmpty ? "" : c.label) ",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .semibold),
                         .foregroundColor: labelColor,
                         .baselineOffset: baseline]))
        line.append(NSAttributedString(
            string: c.text,
            attributes: [.font: NSFont.systemFont(ofSize: candidateFontSize, weight: highlighted ? .semibold : .regular),
                         .foregroundColor: textColor]))
        return line
    }

    private func measuredCandidateWidth(_ c: RimeCandidateModel, highlighted: Bool, compact: Bool) -> CGFloat {
        candidateTitle(c, highlighted: highlighted).size().width + (compact ? 20 : 14)
    }

    private func gridCellWidth(columns: Int) -> CGFloat {
        let sideControlsWidth: CGFloat = 1 + 32 + 64 + 7 * 3
        let available = baseWidth - 14 - sideControlsWidth - CGFloat(max(columns - 1, 0)) * 6
        return max(70, floor(available / CGFloat(max(columns, 1))))
    }

    private func updateCandidateDocumentSize() {
        let fit = candidateStack.fittingSize
        let height = gridExpanded ? expandedCandidateHeight : compactCandidateHeight
        candidateStack.setFrameSize(NSSize(width: max(fit.width, candidateScroll.contentSize.width),
                                           height: height))
    }

    private func scrollSelectedIntoView() {
        guard !gridExpanded,
              let selected = candidateStack.arrangedSubviews.first(where: { $0 is NSButton && $0.tag == selectedIndex })
        else { return }
        candidateScroll.layoutSubtreeIfNeeded()
        candidateStack.layoutSubtreeIfNeeded()
        let contentWidth = candidateScroll.contentSize.width
        let maxX = max(0, candidateStack.frame.width - contentWidth)
        let targetX = min(max(0, selected.frame.midX - contentWidth / 2), maxX)
        candidateScroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        candidateScroll.reflectScrolledClipView(candidateScroll.contentView)
    }

    private func applyAppearance() {
        preeditLabel.textColor = RimeUI.textPrimary
        strip.layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        strip.layer?.borderColor = RimeUI.borderStrong.cgColor
        pageButton.contentTintColor = RimeUI.textSecondary
        settingsButton.contentTintColor = RimeUI.textSecondary
    }

    private func contextSignature(_ ctx: RimeContextModel) -> String {
        let candidates = ctx.candidates.map { "\($0.label):\($0.text):\($0.comment)" }.joined(separator: "|")
        return "\(ctx.input)#\(ctx.preedit)#\(ctx.pageNo)#\(candidates)"
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    @objc private func candidateTapped(_ sender: NSButton) {
        selectedIndex = clamp(sender.tag, count: currentContext.candidates.count)
        onSelect?(selectedIndex)
    }

    @objc private func toggleGridTapped() {
        _ = gridExpanded ? collapseGrid() : expandGrid()
    }

    @objc private func settingsTapped() {
        onSettings?()
    }
}

private final class CandidatePillButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        cell?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CandidateActionButton: NSButton {
    init(symbolName: String, title: String) {
        super.init(frame: .zero)
        self.title = title
        image = RimeUI.symbol(symbolName, pointSize: title.isEmpty ? 17 : 14, weight: .semibold)
        image?.isTemplate = true
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        font = .systemFont(ofSize: 14, weight: .semibold)
        contentTintColor = RimeUI.textSecondary
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
