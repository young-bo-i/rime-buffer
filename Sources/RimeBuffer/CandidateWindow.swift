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
        case .compactStripHeight: return 40
        case .compactCandidateHeight: return 30
        case .preeditHeight: return 22
        case .candidateFontSize: return 16
        case .labelFontSize: return 11
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .baseWidth: return 360...900
        case .compactStripHeight: return 40...64
        case .compactCandidateHeight: return 26...44
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
}

/// In-process candidate window. Candidates are shown as width-bounded pages in
/// a compact strip; the first item is always the local "0 Buffer" action.
final class CandidateWindow {
    private let panel: NSPanel
    private let root = NSStackView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let candidateScroll = NSScrollView()
    private let candidateStack = NSStackView()
    private let pageButton = CandidateActionButton(symbolName: "chevron.down", title: "")
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
    private var bufferOnly = false
    private var lastCaretRect = NSRect.zero
    private var lastBundleId = ""
    private var bufferFlushProgress: Double?

    var onSelect: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
    var onSettings: (() -> Void)?

    var hasCandidates: Bool { panel.isVisible && !currentContext.candidates.isEmpty }
    var isShowingInlineBuffer: Bool { panel.isVisible && !inlineBuffer.isHidden }
    var isVisible: Bool { panel.isVisible }
    var rawInputForCommit: String { currentContext.input }
    var selectedCandidateIndex: Int? {
        guard hasCandidates else { return nil }
        return clamp(selectedIndex, count: currentContext.candidates.count)
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
        candidateHeightConstraint = candidateScroll.heightAnchor.constraint(equalToConstant: metrics.compactCandidateHeight)
        candidateHeightConstraint.isActive = true

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        dividerHeightConstraint = divider.heightAnchor.constraint(equalToConstant: dividerHeight(for: metrics))
        dividerHeightConstraint.isActive = true

        pageButton.target = self
        pageButton.action = #selector(pageDownTapped)
        pageButton.toolTip = "下一页"
        pageButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        pageButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "打开设置"
        settingsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let barRow = NSStackView(views: [candidateScroll, divider, pageButton, settingsButton])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = 7
        barRow.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(barRow)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint = barRow.topAnchor.constraint(equalTo: strip.topAnchor, constant: padding)
        barBottomConstraint = barRow.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -padding)
        NSLayoutConstraint.activate([
            barRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 7),
            barRow.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -7),
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
        }

        let bufferOwnsPreedit = BufferModel.shared.enabled
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
        layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId)
        panel.orderFrontRegardless()
    }

    func setBufferFlushProgress(_ progress: Double?) {
        bufferFlushProgress = progress
        inlineBuffer.setFlushProgress(progress)
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        guard !currentContext.candidates.isEmpty else { return false }
        selectedIndex = clamp(selectedIndex + delta, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        resetCandidateScroll()
        return true
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
        guard !BufferModel.shared.enabled else {
            IMELog.write("candidate buffer action ignored; already enabled")
            renderCandidates()
            refreshBuffer()
            return
        }
        BufferModel.shared.enabled = true
        IMELog.write("candidate buffer action -> \(BufferModel.shared.enabled)")
        renderCandidates()
        refreshBuffer()
    }

    // MARK: Positioning

    private func layoutPanel(caretRect: NSRect, bundleId: String) {
        let metrics = CandidateWindowMetrics.current
        let width = panelWidth(caretRect: caretRect)
        let bufferHeight = inlineBuffer.isHidden ? 0 : inlineBuffer.preferredHeight + root.spacing
        let stripHeight = strip.isHidden ? 0 : metrics.compactStripHeight
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
        pageButton.isEnabled = !currentContext.candidates.isEmpty
        candidateScroll.isHidden = false
        pageButton.image = RimeUI.symbol("chevron.down",
                                         pointSize: 17,
                                         weight: .semibold)
        pageButton.toolTip = "下一页"

        renderCompactRow()
        applyAppearance()
        updateCandidateDocumentSize()
    }

    private func refreshInlineBuffer() {
        let bufferPreedit = BufferModel.shared.enabled
            ? (currentContext.preedit.isEmpty ? currentContext.input : currentContext.preedit)
            : ""
        let visible = inlineBuffer.refresh(preedit: bufferPreedit)
        inlineBuffer.setFlushProgress(bufferFlushProgress)
        inlineBufferHeightConstraint.constant = visible ? inlineBuffer.preferredHeight : 0
    }

    private func renderCompactRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = 6

        let panelWidth = activePanelWidth()
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        for i in currentVisualCandidateIndices(panelWidth: panelWidth) {
            let c = currentContext.candidates[i]
            candidateStack.addArrangedSubview(candidateButton(
                index: i,
                candidate: c,
                highlighted: i == selectedIndex,
                compact: true,
                width: nil,
                maxWidth: candidateMaxWidth(panelWidth: panelWidth)
            ))
        }

        if !BufferModel.shared.enabled {
            candidateStack.addArrangedSubview(bufferActionButton(width: min(bufferActionWidth(), available)))
        }
    }

    private func candidateButton(
        index: Int,
        candidate: RimeCandidateModel,
        highlighted: Bool,
        compact: Bool,
        width: CGFloat?,
        maxWidth: CGFloat? = nil
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
        let labelColor = highlighted ? NSColor.white.withAlphaComponent(0.86) : RimeUI.textMuted
        let textColor = highlighted ? NSColor.white : RimeUI.textSecondary
        let baseline = (metrics.candidateFontSize - metrics.labelFontSize) / 2

        line.append(NSAttributedString(
            string: "\(c.label.isEmpty ? "" : c.label) ",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.labelFontSize, weight: .semibold),
                         .foregroundColor: labelColor,
                         .baselineOffset: baseline]))
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
        button.toolTip = "开启缓冲区"
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: compactCandidateButtonHeight(
                for: CandidateWindowMetrics.current
            )),
        ])
        return button
    }

    private func measuredCandidateWidth(_ c: RimeCandidateModel, highlighted: Bool, compact: Bool) -> CGFloat {
        candidateTitle(c, highlighted: highlighted).size().width + (compact ? 20 : 14)
    }

    private func activePanelWidth() -> CGFloat {
        panelWidth(caretRect: lastCaretRect)
    }

    private func candidateAvailableWidth(panelWidth: CGFloat) -> CGFloat {
        let sideControlsWidth: CGFloat = 1 + 32 + 32 + 7 * 3
        return max(80, panelWidth - 14 - sideControlsWidth)
    }

    private func bufferActionCandidate() -> RimeCandidateModel {
        RimeCandidateModel(text: "B", comment: "开启缓冲区", label: "0")
    }

    private func bufferActionWidth() -> CGFloat {
        max(44, ceil(measuredCandidateWidth(bufferActionCandidate(), highlighted: false, compact: true)))
    }

    private func candidateMaxWidth(panelWidth: CGFloat) -> CGFloat {
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = BufferModel.shared.enabled
            ? 0
            : min(bufferActionWidth(), available) + candidateStack.spacing
        let remaining = available - bufferSpace
        return max(64, remaining)
    }

    private func candidatePages(panelWidth: CGFloat) -> [[Int]] {
        guard !currentContext.candidates.isEmpty else { return [] }

        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = BufferModel.shared.enabled
            ? 0
            : min(bufferActionWidth(), available) + candidateStack.spacing
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
            let nextWidth = page.isEmpty ? width : usedWidth + candidateStack.spacing + width
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
        let height = compactCandidateButtonHeight(for: metrics)
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
        pageButton.contentTintColor = RimeUI.textSecondary
        settingsButton.contentTintColor = RimeUI.textSecondary
    }

    private func applyMetrics() {
        let metrics = CandidateWindowMetrics.current
        preeditLabel.font = .monospacedSystemFont(ofSize: max(12, metrics.preeditHeight - 5),
                                                  weight: .regular)
        preeditHeightConstraint.constant = metrics.preeditHeight
        stripHeightConstraint.constant = metrics.compactStripHeight
        candidateHeightConstraint.constant = compactCandidateButtonHeight(for: metrics)
        dividerHeightConstraint.constant = dividerHeight(for: metrics)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint.constant = padding
        barBottomConstraint.constant = -padding
    }

    private func dividerHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        min(30, max(24, metrics.compactStripHeight - 12))
    }

    private func barVerticalPadding(for metrics: CandidateWindowMetrics) -> CGFloat {
        let tallestChild = max(32, min(metrics.compactCandidateHeight, metrics.compactStripHeight - 2))
        return max(1, floor((metrics.compactStripHeight - tallestChild) / 2))
    }

    private func compactCandidateButtonHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        let available = metrics.compactStripHeight - 2 * barVerticalPadding(for: metrics)
        return min(metrics.compactCandidateHeight, max(24, available))
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
        if sender.tag == bufferActionTag {
            performBufferAction()
            return
        }
        selectedIndex = clamp(sender.tag, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        onSelect?(selectedIndex)
    }

    @objc private func pageDownTapped() {
        if !movePage(delta: 1) {
            onPage?(1)
        }
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

private final class BufferActionPillButton: NSButton {
    private let dashedBorder = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = false
        cell?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        dashedBorder.fillColor = NSColor.clear.cgColor
        dashedBorder.strokeColor = RimeUI.border.withAlphaComponent(0.55).cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [3, 2]
        layer?.addSublayer(dashedBorder)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dashedBorder.frame = bounds
        dashedBorder.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 9,
            cornerHeight: 9,
            transform: nil
        )
    }

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
