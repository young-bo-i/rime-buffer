import Cocoa

extension Notification.Name {
    static let candidateWindowMetricsDidChange = Notification.Name("CandidateWindowMetricsDidChange")
}

enum CandidateWindowMetric: String, CaseIterable {
    case baseWidth
    case compactStripHeight
    case compactCandidateHeight
    case preeditHeight
    case candidateFontSize
    case labelFontSize

    var title: String {
        switch self {
        case .baseWidth: return "基础宽度"
        case .compactStripHeight: return "候选条高度"
        case .compactCandidateHeight: return "候选按钮高度"
        case .preeditHeight: return "预编辑高度"
        case .candidateFontSize: return "候选字大小"
        case .labelFontSize: return "序号大小"
        }
    }

    var unit: String {
        switch self {
        case .candidateFontSize, .labelFontSize: return "pt"
        default: return "px"
        }
    }

    var defaultValue: Double {
        switch self {
        case .baseWidth: return 460
        case .compactStripHeight: return 34
        case .compactCandidateHeight: return 24
        case .preeditHeight: return 20
        case .candidateFontSize: return 16
        case .labelFontSize: return 10
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .baseWidth: return 360...900
        case .compactStripHeight: return 32...64
        case .compactCandidateHeight: return 22...44
        case .preeditHeight: return 18...36
        case .candidateFontSize: return 12...24
        case .labelFontSize: return 9...18
        }
    }

    var userDefaultsKey: String { "candidateWindow.\(rawValue)" }

    var tag: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static func fromTag(_ tag: Int) -> CandidateWindowMetric? {
        guard allCases.indices.contains(tag) else { return nil }
        return allCases[tag]
    }
}

struct CandidateWindowMetrics {
    private static let compactDefaultsMigrationKey = "candidateWindow.compactDefaultsMigrated.v1"

    let baseWidth: CGFloat
    let compactStripHeight: CGFloat
    let compactCandidateHeight: CGFloat
    let preeditHeight: CGFloat
    let candidateFontSize: CGFloat
    let labelFontSize: CGFloat

    static var current: CandidateWindowMetrics {
        CandidateWindowMetrics(
            baseWidth: value(for: .baseWidth),
            compactStripHeight: value(for: .compactStripHeight),
            compactCandidateHeight: value(for: .compactCandidateHeight),
            preeditHeight: value(for: .preeditHeight),
            candidateFontSize: value(for: .candidateFontSize),
            labelFontSize: value(for: .labelFontSize)
        )
    }

    static func value(for metric: CandidateWindowMetric) -> CGFloat {
        migrateCompactDefaultsIfNeeded()
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: metric.userDefaultsKey) != nil else {
            return CGFloat(metric.defaultValue)
        }
        return CGFloat(clamp(defaults.double(forKey: metric.userDefaultsKey), to: metric.range))
    }

    static func set(_ value: Double, for metric: CandidateWindowMetric) {
        let clamped = clamp(value, to: metric.range)
        UserDefaults.standard.set(clamped, forKey: metric.userDefaultsKey)
        IMELog.write("candidate window metric \(metric.rawValue)=\(clamped)")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    static func apply(_ values: [CandidateWindowMetric: Double]) {
        for metric in CandidateWindowMetric.allCases {
            guard let value = values[metric] else { continue }
            UserDefaults.standard.set(clamp(value, to: metric.range),
                                      forKey: metric.userDefaultsKey)
        }
        IMELog.write("candidate window metrics applied")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    static func resetToDefaults() {
        for metric in CandidateWindowMetric.allCases {
            UserDefaults.standard.removeObject(forKey: metric.userDefaultsKey)
        }
        IMELog.write("candidate window metrics reset")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func migrateCompactDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: compactDefaultsMigrationKey) else { return }
        let oldDefaults: [CandidateWindowMetric: Double] = [
            .compactStripHeight: 40,
            .compactCandidateHeight: 30,
            .preeditHeight: 22,
            .labelFontSize: 11,
        ]
        for (metric, oldValue) in oldDefaults {
            guard defaults.object(forKey: metric.userDefaultsKey) != nil else { continue }
            if abs(defaults.double(forKey: metric.userDefaultsKey) - oldValue) < 0.001 {
                defaults.set(metric.defaultValue, forKey: metric.userDefaultsKey)
            }
        }
        defaults.set(true, forKey: compactDefaultsMigrationKey)
    }
}

struct CandidateSelection {
    let pageOffset: Int
    let index: Int
}

/// In-process candidate window. Candidates default to a compact one-line strip
/// and can expand into a three-row preview of consecutive Rime pages.
final class CandidateWindow {
    private static let candidateSpacing: CGFloat = 3
    private static let candidateSeparatorWidth: CGFloat = 8
    private static let barSpacing: CGFloat = 4
    private static let barHorizontalPadding: CGFloat = 5
    private static let actionButtonSize: CGFloat = 28
    private static let compactCandidateHorizontalPadding: CGFloat = 6
    private static let expandedRowSpacing: CGFloat = 3
    private static let expandedMaxRows = 3
    private static let characterSelectionTagBase = 200_000

    private let panel: NSPanel
    private let root = NSStackView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let candidateScroll = NSScrollView()
    private let candidateStack = NSStackView()
    private let settingsButton = CandidateActionButton(symbolName: "gearshape", title: "")
    private let inlineBuffer = BufferInlineView()
    private var stripHeightConstraint: NSLayoutConstraint!
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var preeditHeightConstraint: NSLayoutConstraint!
    private var dividerHeightConstraint: NSLayoutConstraint!
    private var barTopConstraint: NSLayoutConstraint!
    private var barBottomConstraint: NSLayoutConstraint!
    private var inlineBufferHeightConstraint: NSLayoutConstraint!
    private var lastGoodRect: [String: NSRect] = [:]

    private var currentContext = RimeContextModel()
    private var currentSignature = ""
    private var selectedIndex = 0
    private var visualPageIndex = 0
    private var expandedPages: [RimeContextModel] = []
    private var expandedSelectionPageOffset = 0
    private var characterSelectionText = ""
    private var characterSelectionIndex = 0
    private var bufferOnly = false
    private var lastCaretRect = NSRect.zero
    private var lastBundleId = ""
    private var bufferFlushProgress: Double?

    var onSelect: ((CandidateSelection) -> Void)?
    var onSettings: (() -> Void)?

    var hasCandidates: Bool { panel.isVisible && !currentContext.candidates.isEmpty }
    var isShowingInlineBuffer: Bool { panel.isVisible && !inlineBuffer.isHidden }
    var isVisible: Bool { panel.isVisible }
    var isExpanded: Bool { !expandedPages.isEmpty }
    var isSingleCharacterSelectionActive: Bool { !characterSelectionText.isEmpty }
    var rawInputForCommit: String { currentContext.input }
    var selectedCandidateText: String? {
        guard hasCandidates else { return nil }
        if isExpanded {
            let pageOffset = clamp(expandedSelectionPageOffset, count: expandedPages.count)
            let row = expandedPages[pageOffset].candidates
            guard !row.isEmpty else { return nil }
            return row[clamp(selectedIndex, count: row.count)].text
        }
        guard !currentContext.candidates.isEmpty else { return nil }
        return currentContext.candidates[clamp(selectedIndex, count: currentContext.candidates.count)].text
    }
    var selectedSingleCharacterText: String? {
        guard isSingleCharacterSelectionActive else { return nil }
        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return nil }
        return String(chars[clamp(characterSelectionIndex, count: chars.count)])
    }
    var selectedCandidateSelection: CandidateSelection? {
        guard hasCandidates else { return nil }
        if isExpanded {
            let pageOffset = clamp(expandedSelectionPageOffset, count: expandedPages.count)
            let row = expandedPages[pageOffset].candidates
            guard !row.isEmpty else { return nil }
            return CandidateSelection(pageOffset: pageOffset,
                                      index: clamp(selectedIndex, count: row.count))
        }
        return CandidateSelection(pageOffset: 0,
                                  index: clamp(selectedIndex, count: currentContext.candidates.count))
    }
    private let bufferActionTag = -1000

    init() {
        let metrics = CandidateWindowMetrics.current
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: metrics.baseWidth,
                                            height: metrics.compactStripHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        preeditLabel.font = .monospacedSystemFont(ofSize: max(12, metrics.preeditHeight - 5),
                                                  weight: .regular)
        preeditLabel.lineBreakMode = .byTruncatingTail
        preeditLabel.isHidden = true
        preeditHeightConstraint = preeditLabel.heightAnchor.constraint(equalToConstant: metrics.preeditHeight)
        preeditHeightConstraint.isActive = true

        strip.wantsLayer = true
        strip.layer?.cornerRadius = 12
        strip.layer?.borderWidth = 1
        strip.layer?.masksToBounds = true
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: metrics.compactStripHeight)
        stripHeightConstraint.isActive = true

        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing
        candidateStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        candidateScroll.drawsBackground = false
        candidateScroll.hasHorizontalScroller = false
        candidateScroll.hasVerticalScroller = false
        candidateScroll.horizontalScrollElasticity = .none
        candidateScroll.verticalScrollElasticity = .none
        candidateScroll.documentView = candidateStack
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateHeightConstraint = candidateScroll.heightAnchor.constraint(equalToConstant: metrics.compactCandidateHeight)
        candidateHeightConstraint.isActive = true

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        dividerHeightConstraint = divider.heightAnchor.constraint(equalToConstant: dividerHeight(for: metrics))
        dividerHeightConstraint.isActive = true

        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "打开设置"
        settingsButton.widthAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true

        let barRow = NSStackView(views: [candidateScroll, divider, settingsButton])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = Self.barSpacing
        barRow.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(barRow)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint = barRow.topAnchor.constraint(equalTo: strip.topAnchor, constant: padding)
        barBottomConstraint = barRow.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -padding)
        NSLayoutConstraint.activate([
            barRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Self.barHorizontalPadding),
            barRow.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -Self.barHorizontalPadding),
            barTopConstraint,
            barBottomConstraint,
        ])

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(preeditLabel)
        root.addArrangedSubview(inlineBuffer)
        root.addArrangedSubview(strip)
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
        NotificationCenter.default.addObserver(
            forName: .candidateWindowMetricsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyMetrics()
            self?.renderCandidates()
            self?.refreshBuffer()
        }
    }

    func update(_ ctx: RimeContextModel, caretRect: NSRect, bundleId: String, showPreedit: Bool) {
        guard !ctx.candidates.isEmpty || (showPreedit && !ctx.preedit.isEmpty) else {
            hide()
            return
        }

        bufferOnly = false
        strip.isHidden = false
        let signature = contextSignature(ctx)
        let signatureChanged = signature != currentSignature
        if signature != currentSignature {
            resetExpandedState()
            resetCharacterSelectionState()
            selectedIndex = clamp(ctx.highlightedIndex, count: ctx.candidates.count)
            currentSignature = signature
        }

        currentContext = ctx
        lastCaretRect = caretRect
        lastBundleId = bundleId
        if signatureChanged {
            visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        } else {
            visualPageIndex = clampVisualPage(visualPageIndex, panelWidth: activePanelWidth())
            if isExpanded {
                expandedPages[0] = ctx
            }
        }

        let bufferOwnsPreedit = BufferModel.shared.active
        preeditLabel.stringValue = showPreedit && !bufferOwnsPreedit
            ? (ctx.preedit.isEmpty ? ctx.input : ctx.preedit)
            : ""
        preeditLabel.isHidden = preeditLabel.stringValue.isEmpty
        applyAppearance()
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: caretRect, bundleId: bundleId)
        panel.orderFrontRegardless()
    }

    func showBufferOnly(caretRect: NSRect, bundleId: String) {
        guard BufferModel.shared.shouldDisplay else {
            hide()
            return
        }
        bufferOnly = true
        visualPageIndex = 0
        selectedIndex = 0
        resetExpandedState()
        resetCharacterSelectionState()
        currentContext = RimeContextModel()
        currentSignature = ""
        lastCaretRect = caretRect
        lastBundleId = bundleId
        preeditLabel.stringValue = ""
        preeditLabel.isHidden = true
        strip.isHidden = true
        applyAppearance()
        refreshInlineBuffer()
        layoutPanel(caretRect: caretRect, bundleId: bundleId)
        panel.orderFrontRegardless()
    }

    func hide() {
        visualPageIndex = 0
        selectedIndex = 0
        resetExpandedState()
        resetCharacterSelectionState()
        bufferOnly = false
        currentContext = RimeContextModel()
        currentSignature = ""
        preeditLabel.stringValue = ""
        preeditLabel.isHidden = true
        strip.isHidden = false
        panel.orderOut(nil)
    }

    func refreshBuffer() {
        refreshInlineBuffer()
        guard panel.isVisible else {
            return
        }
        if bufferOnly, !BufferModel.shared.shouldDisplay {
            hide()
            return
        }
        if inlineBuffer.isHidden, currentContext.candidates.isEmpty, preeditLabel.isHidden {
            hide()
            return
        }
        if !currentContext.candidates.isEmpty {
            renderCandidates()
        }
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
    }

    func setBufferFlushProgress(_ progress: Double?) {
        bufferFlushProgress = progress
        inlineBuffer.setFlushProgress(progress)
    }

    @discardableResult
    func beginSingleCharacterSelection(candidateText: String) -> Bool {
        let chars = Array(candidateText)
        guard chars.count > 1 else { return false }
        resetExpandedState()
        characterSelectionText = candidateText
        characterSelectionIndex = 0
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    func moveSingleCharacterSelection(delta: Int) -> Bool {
        guard isSingleCharacterSelectionActive else { return false }
        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return false }
        characterSelectionIndex = clamp(characterSelectionIndex + delta, count: chars.count)
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    func cancelSingleCharacterSelection() {
        guard isSingleCharacterSelectionActive else { return }
        resetCharacterSelectionState()
        selectedIndex = clamp(selectedIndex, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        if isExpanded {
            return moveExpandedSelection(columnDelta: delta)
        }
        guard !currentContext.candidates.isEmpty else { return false }
        selectedIndex = clamp(selectedIndex + delta, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    @discardableResult
    func moveExpandedSelection(rowDelta: Int) -> Bool {
        guard isExpanded else { return false }
        if rowDelta < 0, expandedSelectionPageOffset == 0 {
            return collapseExpanded()
        }
        let nextOffset = expandedSelectionPageOffset + rowDelta
        guard expandedPages.indices.contains(nextOffset) else { return true }
        expandedSelectionPageOffset = nextOffset
        selectedIndex = clamp(selectedIndex, count: expandedPages[nextOffset].candidates.count)
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    @discardableResult
    func expand(with pages: [RimeContextModel]) -> Bool {
        let visiblePages = Array(pages.prefix(Self.expandedMaxRows))
            .filter { !$0.candidates.isEmpty }
        guard !visiblePages.isEmpty else { return false }
        expandedPages = visiblePages
        expandedSelectionPageOffset = min(expandedSelectionPageOffset, expandedPages.count - 1)
        selectedIndex = clamp(selectedIndex,
                              count: expandedPages[expandedSelectionPageOffset].candidates.count)
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    func collapseExpanded() -> Bool {
        guard isExpanded else { return false }
        resetExpandedState()
        selectedIndex = clamp(selectedIndex, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        refreshInlineBuffer()
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
        return true
    }

    private func moveExpandedSelection(columnDelta: Int) -> Bool {
        guard isExpanded,
              expandedPages.indices.contains(expandedSelectionPageOffset) else {
            return false
        }
        let row = expandedPages[expandedSelectionPageOffset].candidates
        guard !row.isEmpty else { return false }
        selectedIndex = clamp(selectedIndex + columnDelta, count: row.count)
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    private func resetExpandedState() {
        expandedPages.removeAll()
        expandedSelectionPageOffset = 0
    }

    private func resetCharacterSelectionState() {
        characterSelectionText = ""
        characterSelectionIndex = 0
    }

    @discardableResult
    func movePage(delta: Int) -> Bool {
        guard !currentContext.candidates.isEmpty else { return false }
        let pages = candidatePages(panelWidth: activePanelWidth())
        guard !pages.isEmpty else { return false }
        let currentPage = clampVisualPage(visualPageIndex, pageCount: pages.count)
        let nextPage = currentPage + delta
        guard pages.indices.contains(nextPage) else { return false }

        visualPageIndex = nextPage
        if let first = pages[nextPage].first {
            selectedIndex = first
        }
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    func performBufferAction() {
        guard !BufferModel.shared.active else {
            IMELog.write("candidate buffer action ignored; already enabled")
            renderCandidates()
            refreshBuffer()
            return
        }
        BufferModel.shared.enabled = true
        IMELog.write("candidate buffer action -> on")
        renderCandidates()
        refreshBuffer()
    }

    // MARK: Positioning

    private func layoutPanel(caretRect: NSRect, bundleId: String) {
        let metrics = CandidateWindowMetrics.current
        let width = panelWidth(caretRect: caretRect)
        let bufferHeight = inlineBuffer.isHidden ? 0 : inlineBuffer.preferredHeight + root.spacing
        let stripHeight = strip.isHidden ? 0 : stripHeightConstraint.constant
        let height = stripHeight
            + (preeditLabel.isHidden ? 0 : metrics.preeditHeight + root.spacing)
            + bufferHeight
        panel.setContentSize(NSSize(width: width, height: height))
        panel.layoutIfNeeded()
        updateCandidateDocumentSize()
        resetCandidateScroll()
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

    private func panelWidth(caretRect: NSRect) -> CGFloat {
        let metrics = CandidateWindowMetrics.current
        let visibleWidth = (screen(containing: caretRect)?.visibleFrame.width ?? metrics.baseWidth) - 12
        return min(max(metrics.baseWidth, 360), max(360, visibleWidth))
    }

    // MARK: Rendering

    private func renderCandidates() {
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        applyMetrics()
        visualPageIndex = clampVisualPage(visualPageIndex, panelWidth: activePanelWidth())
        candidateScroll.isHidden = false

        if isSingleCharacterSelectionActive {
            renderSingleCharacterSelectionRow()
        } else if isExpanded {
            renderExpandedMatrix()
        } else {
            renderCompactRow()
        }
        applyAppearance()
        updateCandidateDocumentSize()
    }

    private func refreshInlineBuffer() {
        let bufferPreedit = BufferModel.shared.active
            ? (currentContext.preedit.isEmpty ? currentContext.input : currentContext.preedit)
            : ""
        let visible = inlineBuffer.refresh(preedit: bufferPreedit)
        inlineBuffer.setFlushProgress(bufferFlushProgress)
        inlineBufferHeightConstraint.constant = visible ? inlineBuffer.preferredHeight : 0
    }

    private func renderCompactRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing

        let panelWidth = activePanelWidth()
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let indices = currentVisualCandidateIndices(panelWidth: panelWidth)
        for (offset, i) in indices.enumerated() {
            if offset > 0 {
                candidateStack.addArrangedSubview(candidateSeparatorView())
            }
            let c = currentContext.candidates[i]
            candidateStack.addArrangedSubview(candidateButton(
                pageOffset: 0,
                index: i,
                candidate: c,
                highlighted: i == selectedIndex,
                compact: true,
                width: nil,
                maxWidth: candidateMaxWidth(panelWidth: panelWidth)
            ))
        }

        if !BufferModel.shared.active {
            if !indices.isEmpty {
                candidateStack.addArrangedSubview(candidateSeparatorView())
            }
            candidateStack.addArrangedSubview(bufferActionButton(width: min(bufferActionWidth(), available)))
        }
    }

    private func renderExpandedMatrix() {
        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = Self.expandedRowSpacing

        let panelWidth = activePanelWidth()
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let pages = expandedPages.isEmpty ? [currentContext] : expandedPages
        let columnCount = max(1, currentContext.pageSize, pages.map { $0.candidates.count }.max() ?? 1)
        let separatorWidth = separatorRunWidth() * CGFloat(max(0, columnCount - 1))
        let cellWidth = max(38, floor((available - separatorWidth) / CGFloat(columnCount)))

        for (pageOffset, page) in pages.prefix(Self.expandedMaxRows).enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Self.candidateSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: available).isActive = true
            row.heightAnchor.constraint(equalToConstant: compactCandidateButtonHeight(
                for: CandidateWindowMetrics.current
            )).isActive = true

            for (index, candidate) in page.candidates.enumerated() {
                if index > 0 {
                    row.addArrangedSubview(candidateSeparatorView())
                }
                row.addArrangedSubview(candidateButton(
                    pageOffset: pageOffset,
                    index: index,
                    candidate: candidate,
                    highlighted: pageOffset == expandedSelectionPageOffset && index == selectedIndex,
                    compact: true,
                    width: cellWidth
                ))
            }
            candidateStack.addArrangedSubview(row)
        }
    }

    private func renderSingleCharacterSelectionRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing

        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return }

        for (index, char) in chars.enumerated() {
            if index > 0 {
                candidateStack.addArrangedSubview(candidateSeparatorView())
            }
            candidateStack.addArrangedSubview(candidateButton(
                pageOffset: 0,
                index: index,
                candidate: RimeCandidateModel(text: String(char), comment: "", label: ""),
                highlighted: index == characterSelectionIndex,
                compact: true,
                width: nil,
                tag: Self.characterSelectionTagBase + index
            ))
        }
    }

    private func candidateButton(
        pageOffset: Int,
        index: Int,
        candidate: RimeCandidateModel,
        highlighted: Bool,
        compact: Bool,
        width: CGFloat?,
        maxWidth: CGFloat? = nil,
        tag: Int? = nil
    ) -> NSButton {
        let button = CandidatePillButton()
        button.tag = tag ?? candidateTag(pageOffset: pageOffset, index: index)
        button.target = self
        button.action = #selector(candidateTapped(_:))
        button.attributedTitle = candidateTitle(candidate, highlighted: highlighted)
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0
        button.toolTip = candidate.comment.isEmpty
            ? candidate.text
            : "\(candidate.text)  \(candidate.comment)"

        let naturalWidth = ceil(measuredCandidateWidth(candidate, highlighted: highlighted, compact: compact))
        let cappedWidth = maxWidth.map { min(naturalWidth, $0) } ?? naturalWidth
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width ?? cappedWidth),
            button.heightAnchor.constraint(equalToConstant: compact
                ? compactCandidateButtonHeight(for: CandidateWindowMetrics.current)
                : 32),
        ])
        return button
    }

    private func candidateTitle(_ c: RimeCandidateModel, highlighted: Bool) -> NSAttributedString {
        let metrics = CandidateWindowMetrics.current
        let line = NSMutableAttributedString()
        let labelColor = highlighted ? RimeUI.selectedCandidateColor.withAlphaComponent(0.85) : RimeUI.textMuted
        let textColor = highlighted ? RimeUI.selectedCandidateColor : RimeUI.textPrimary
        let baseline = (metrics.candidateFontSize - metrics.labelFontSize) / 2

        if !c.label.isEmpty {
            line.append(NSAttributedString(
                string: "\(c.label) ",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.labelFontSize, weight: .semibold),
                             .foregroundColor: labelColor,
                             .baselineOffset: baseline]))
        }
        line.append(NSAttributedString(
            string: c.text,
            attributes: [.font: NSFont.systemFont(ofSize: metrics.candidateFontSize,
                                                  weight: highlighted ? .semibold : .regular),
                         .foregroundColor: textColor]))
        return line
    }

    private func bufferActionButton(width: CGFloat) -> NSButton {
        let button = BufferActionPillButton()
        button.tag = bufferActionTag
        button.target = self
        button.action = #selector(candidateTapped(_:))
        button.attributedTitle = candidateTitle(bufferActionCandidate(), highlighted: false)
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0
        button.toolTip = "开启缓冲区"
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: compactCandidateButtonHeight(
                for: CandidateWindowMetrics.current
            )),
        ])
        return button
    }

    private func candidateSeparatorView() -> NSView {
        let label = NSTextField(labelWithString: "|")
        label.font = .systemFont(ofSize: max(12, CandidateWindowMetrics.current.candidateFontSize - 1),
                                 weight: .regular)
        label.textColor = RimeUI.borderStrong
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.candidateSeparatorWidth).isActive = true
        return label
    }

    private func measuredCandidateWidth(_ c: RimeCandidateModel, highlighted: Bool, compact: Bool) -> CGFloat {
        candidateTitle(c, highlighted: highlighted).size().width
            + (compact ? Self.compactCandidateHorizontalPadding : 14)
    }

    private func activePanelWidth() -> CGFloat {
        panelWidth(caretRect: lastCaretRect)
    }

    private func candidateAvailableWidth(panelWidth: CGFloat) -> CGFloat {
        let sideControlsWidth: CGFloat = 1 + Self.actionButtonSize + Self.barSpacing * 2
        return max(80, panelWidth - Self.barHorizontalPadding * 2 - sideControlsWidth)
    }

    private func bufferActionCandidate() -> RimeCandidateModel {
        RimeCandidateModel(text: "🅔", comment: "开启缓冲区", label: "0")
    }

    private func bufferActionWidth() -> CGFloat {
        max(38, ceil(measuredCandidateWidth(bufferActionCandidate(), highlighted: false, compact: true)))
    }

    private func candidateMaxWidth(panelWidth: CGFloat) -> CGFloat {
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = BufferModel.shared.active
            ? 0
            : min(bufferActionWidth(), available) + separatorRunWidth()
        let remaining = available - bufferSpace
        return max(64, remaining)
    }

    private func candidatePages(panelWidth: CGFloat) -> [[Int]] {
        guard !currentContext.candidates.isEmpty else { return [] }

        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = BufferModel.shared.active
            ? 0
            : min(bufferActionWidth(), available) + separatorRunWidth()
        let remaining = available - bufferSpace
        let pageWidth = max(64, remaining)
        let maxItemWidth = max(64, pageWidth)

        var pages: [[Int]] = []
        var page: [Int] = []
        var usedWidth: CGFloat = 0

        for i in currentContext.candidates.indices {
            let natural = ceil(measuredCandidateWidth(currentContext.candidates[i],
                                                      highlighted: false,
                                                      compact: true))
            let width = min(natural, maxItemWidth)
            let nextWidth = page.isEmpty ? width : usedWidth + separatorRunWidth() + width
            if !page.isEmpty, nextWidth > pageWidth {
                pages.append(page)
                page = [i]
                usedWidth = width
            } else {
                page.append(i)
                usedWidth = nextWidth
            }
        }

        if !page.isEmpty { pages.append(page) }
        return pages
    }

    private func separatorRunWidth() -> CGFloat {
        Self.candidateSeparatorWidth + Self.candidateSpacing * 2
    }

    private func currentVisualCandidateIndices(panelWidth: CGFloat) -> [Int] {
        let pages = candidatePages(panelWidth: panelWidth)
        guard !pages.isEmpty else { return [] }
        return pages[clampVisualPage(visualPageIndex, pageCount: pages.count)]
    }

    private func pageIndex(containing candidateIndex: Int, panelWidth: CGFloat) -> Int {
        let pages = candidatePages(panelWidth: panelWidth)
        guard !pages.isEmpty else { return 0 }
        return pages.firstIndex { $0.contains(candidateIndex) } ?? 0
    }

    private func clampVisualPage(_ index: Int, panelWidth: CGFloat) -> Int {
        clampVisualPage(index, pageCount: candidatePages(panelWidth: panelWidth).count)
    }

    private func clampVisualPage(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    private func updateCandidateDocumentSize() {
        let metrics = CandidateWindowMetrics.current
        let fit = candidateStack.fittingSize
        let height = candidateAreaHeight(for: metrics)
        candidateStack.setFrameSize(NSSize(width: max(fit.width, candidateScroll.contentSize.width),
                                           height: height))
    }

    private func resetCandidateScroll() {
        candidateScroll.layoutSubtreeIfNeeded()
        candidateStack.layoutSubtreeIfNeeded()
        candidateScroll.contentView.scroll(to: .zero)
        candidateScroll.reflectScrolledClipView(candidateScroll.contentView)
    }

    private func applyAppearance() {
        preeditLabel.textColor = RimeUI.textPrimary
        strip.layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        strip.layer?.borderColor = RimeUI.borderStrong.cgColor
        settingsButton.contentTintColor = RimeUI.textSecondary
    }

    private func applyMetrics() {
        let metrics = CandidateWindowMetrics.current
        preeditLabel.font = .monospacedSystemFont(ofSize: max(12, metrics.preeditHeight - 5),
                                                  weight: .regular)
        preeditHeightConstraint.constant = metrics.preeditHeight
        stripHeightConstraint.constant = effectiveStripHeight(for: metrics)
        candidateHeightConstraint.constant = candidateAreaHeight(for: metrics)
        dividerHeightConstraint.constant = dividerHeight(for: metrics)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint.constant = padding
        barBottomConstraint.constant = -padding
    }

    private func dividerHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        min(effectiveStripHeight(for: metrics) - 8, max(20, metrics.compactStripHeight - 10))
    }

    private func barVerticalPadding(for metrics: CandidateWindowMetrics) -> CGFloat {
        let tallestChild = max(Self.actionButtonSize, min(metrics.compactCandidateHeight, metrics.compactStripHeight - 2))
        return max(1, floor((metrics.compactStripHeight - tallestChild) / 2))
    }

    private func compactCandidateButtonHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        let available = metrics.compactStripHeight - 2 * barVerticalPadding(for: metrics)
        return min(metrics.compactCandidateHeight, max(22, available))
    }

    private func candidateAreaHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        let rowHeight = compactCandidateButtonHeight(for: metrics)
        guard isExpanded, !isSingleCharacterSelectionActive else { return rowHeight }
        let rowCount = max(1, min(Self.expandedMaxRows, expandedPages.count))
        return CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * Self.expandedRowSpacing
    }

    private func effectiveStripHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        max(metrics.compactStripHeight, candidateAreaHeight(for: metrics) + 2 * barVerticalPadding(for: metrics))
    }

    private func contextSignature(_ ctx: RimeContextModel) -> String {
        let candidates = ctx.candidates.map { "\($0.label):\($0.text):\($0.comment)" }.joined(separator: "|")
        return "\(ctx.input)#\(ctx.preedit)#\(ctx.pageNo)#\(candidates)"
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private func candidateTag(pageOffset: Int, index: Int) -> Int {
        pageOffset * 1000 + index
    }

    private func candidateSelection(from tag: Int) -> CandidateSelection? {
        guard tag >= 0 else { return nil }
        return CandidateSelection(pageOffset: tag / 1000, index: tag % 1000)
    }

    @objc private func candidateTapped(_ sender: NSButton) {
        if sender.tag == bufferActionTag {
            performBufferAction()
            return
        }
        if isSingleCharacterSelectionActive, sender.tag >= Self.characterSelectionTagBase {
            let chars = Array(characterSelectionText)
            characterSelectionIndex = clamp(sender.tag - Self.characterSelectionTagBase,
                                            count: chars.count)
            renderCandidates()
            return
        }
        guard let selection = candidateSelection(from: sender.tag) else { return }
        if isExpanded {
            guard expandedPages.indices.contains(selection.pageOffset) else { return }
            expandedSelectionPageOffset = selection.pageOffset
            selectedIndex = clamp(selection.index,
                                  count: expandedPages[selection.pageOffset].candidates.count)
        } else {
            selectedIndex = clamp(selection.index, count: currentContext.candidates.count)
            visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        }
        onSelect?(CandidateSelection(pageOffset: selection.pageOffset, index: selectedIndex))
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
        layer?.cornerRadius = 0
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

private final class BufferActionPillButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 0
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
        image = RimeUI.symbol(symbolName, pointSize: title.isEmpty ? 15 : 14, weight: .semibold)
        image?.isTemplate = true
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        font = .systemFont(ofSize: 14, weight: .semibold)
        contentTintColor = RimeUI.textSecondary
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
