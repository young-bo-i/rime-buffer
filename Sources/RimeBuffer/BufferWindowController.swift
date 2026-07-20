import Cocoa
import Carbon.HIToolbox
import QuartzCore

enum BufferCandidatePlacement: String, CaseIterable {
    case workbench
    case caret

    var title: String {
        switch self {
        case .workbench: return "显示在缓冲条下方"
        case .caret: return "跟随输入光标"
        }
    }
}

enum BufferWorkbenchLayoutMode: Equatable {
    case standard
    case translation
}

/// Pure frame math shared by runtime restoration and the CLI smoke test.
enum BufferWindowGeometry {
    static let standardMinimumWidth: CGFloat = 520
    static let standardMaximumWidth: CGFloat = 1100
    static let collapsedHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 78
    static let translationCollapsedHeight: CGFloat = 78
    static let translationExpandedHeight: CGFloat = 112
    static let standardMinimumHeight = collapsedHeight
    static let screenSafetyMargin: CGFloat = 8

    static func height(expanded: Bool,
                       mode: BufferWorkbenchLayoutMode = .standard) -> CGFloat {
        switch (mode, expanded) {
        case (.standard, false): return collapsedHeight
        case (.standard, true): return expandedHeight
        case (.translation, false): return translationCollapsedHeight
        case (.translation, true): return translationExpandedHeight
        }
    }

    static func clampedFrame(_ proposed: NSRect,
                             expanded: Bool = false,
                             mode: BufferWorkbenchLayoutMode = .standard,
                             visibleFrames: [NSRect],
                             fallback: NSRect) -> NSRect {
        let screens = visibleFrames.isEmpty ? [fallback] : visibleFrames
        let target = screens.max { lhs, rhs in
            intersectionArea(proposed, lhs) < intersectionArea(proposed, rhs)
        }.flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil } ?? fallback

        let horizontalMargin = min(screenSafetyMargin, max(0, (target.width - 1) / 2))
        let verticalMargin = min(screenSafetyMargin, max(0, (target.height - 1) / 2))
        let safeTarget = target.insetBy(dx: horizontalMargin, dy: verticalMargin)
        let minimumWidth = min(standardMinimumWidth, safeTarget.width)
        let maximumWidth = min(standardMaximumWidth, safeTarget.width)
        let width = min(max(proposed.width, minimumWidth), maximumWidth)
        let height = min(height(expanded: expanded, mode: mode), safeTarget.height)
        var x = proposed.width == width ? proposed.minX : proposed.midX - width / 2
        // The 52pt predecessor and both current states preserve their bottom
        // edge, keeping the candidate panel stationary. Only the legacy 340pt
        // workbench migrates by preserving its old top edge.
        var y = proposed.height <= translationExpandedHeight + 1
            ? proposed.minY
            : proposed.maxY - height
        if proposed == .zero || intersectionArea(proposed, target) == 0 {
            x = safeTarget.midX - width / 2
            y = safeTarget.midY - height / 2
        }
        x = min(max(x, safeTarget.minX), max(safeTarget.minX, safeTarget.maxX - width))
        y = min(max(y, safeTarget.minY), max(safeTarget.minY, safeTarget.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func candidateAnchor(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 8,
               y: frame.minY,
               width: max(4, frame.width - 16),
               height: frame.height)
    }

    static func pixelAligned(_ frame: NSRect, scale: CGFloat) -> NSRect {
        guard scale > 0 else { return frame }
        func aligned(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        return NSRect(x: aligned(frame.minX),
                      y: aligned(frame.minY),
                      width: aligned(frame.width),
                      height: aligned(frame.height))
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}

/// `NSWindow.isVisible` means ordered, not necessarily visible on the active
/// macOS Space. Candidate routing and menu actions need the latter meaning or
/// an unpinned workbench left on another Space can swallow the caret panel.
enum BufferWindowVisibilityRules {
    static func isVisibleOnActiveSpace(isOrdered: Bool,
                                       isOnActiveSpace: Bool) -> Bool {
        isOrdered && isOnActiveSpace
    }
}

enum BufferWorkbenchControl: String, Equatable {
    case dragHandle
    case disclosure
    case bufferRail
    case send
    case status
    case pluginActions
    case refresh
    case close
}

enum BufferMainControlRow: Equatable {
    case source
    case target
}

enum BufferWorkbenchCursorKind: Equatable {
    case pointingHand

    var cursor: NSCursor {
        switch self {
        case .pointingHand: return .pointingHand
        }
    }
}

enum BufferWorkbenchMetrics {
    static let controlSize: CGFloat = 22
    static let mainSpacing: CGFloat = 3
    static let shelfSpacing: CGFloat = 4
    static let mainHorizontalInset: CGFloat = 5
    static let shelfHorizontalInset: CGFloat = 6
    static let translationVerticalInset: CGFloat = 5
    static let translationRailSpacing: CGFloat = 4

    static func railHeight(for mode: BufferWorkbenchLayoutMode) -> CGFloat {
        mode == .translation
            ? BufferInlineView.translationPreferredHeight
            : BufferInlineView.standardPreferredHeight
    }

    static func mainBarHeight(for mode: BufferWorkbenchLayoutMode) -> CGFloat {
        mode == .translation ? 74 : 40
    }

    /// Translation renders two equal rails inside a 5pt vertical inset with a
    /// 4pt separator. Main controls use the same centers so their hit targets,
    /// not just their artwork, line up with the source and target rows.
    static func mainControlYOffset(row: BufferMainControlRow,
                                   mode: BufferWorkbenchLayoutMode) -> CGFloat {
        guard mode == .translation else { return 0 }
        let offset = (
            BufferInlineView.translationPreferredHeight
                - translationVerticalInset * 2
                + translationRailSpacing
        ) / 4
        // NSStackView lays this main bar out in a flipped view coordinate
        // system: the visually upper source row has the negative constant.
        return row == .source ? -offset : offset
    }
}

/// Shared by the live stack construction and the pure layout smoke test.
enum BufferWorkbenchLayout {
    static let mainBar: [BufferWorkbenchControl] = [
        .dragHandle, .disclosure, .bufferRail, .send,
    ]
    static let expandedShelf: [BufferWorkbenchControl] = [
        .status, .pluginActions, .refresh, .close,
    ]
    static let dragControls: Set<BufferWorkbenchControl> = [.dragHandle]
    static let dragCursor = BufferWorkbenchCursorKind.pointingHand
    static let windowBackgroundDraggable = false
}

enum BufferWorkbenchStatusText {
    static func text(for availability: BufferDeliveryCoordinator.Availability,
                     secureInput: Bool,
                     pluginFailure: String? = nil,
                     canGenerateWithoutFocus: Bool = false) -> String {
        if secureInput { return "安全输入，内容已隐藏" }
        if let pluginFailure = normalized(pluginFailure) { return pluginFailure }
        switch availability {
        case .ready:
            return "可发送"
        case let .blocked(reason):
            switch reason {
            case .noFocusedField:
                return canGenerateWithoutFocus
                    ? "可生成 · 发送前点选输入框"
                    : "等待输入框"
            case .composing: return "正在组字"
            case .secureInput: return "安全输入，内容已隐藏"
            case .nothingPending: return "等待内容"
            case .targetChanged: return "焦点已变化"
            case .deliveryRejected: return "发送失败"
            case .validatingPluginTarget: return "正在确认目标"
            case .stalePluginResult: return "插件结果已过期"
            case .pluginTargetChanged: return "评论目标已变化"
            case .pluginUnavailable: return "插件暂不可用"
            case .pluginResultIncomplete: return "插件正在生成"
            case .contentChanged: return "内容已变化"
            }
        }
    }

    static func help(for availability: BufferDeliveryCoordinator.Availability,
                     secureInput: Bool,
                     pluginFailure: String? = nil,
                     canGenerateWithoutFocus: Bool = false) -> String {
        if secureInput { return "安全输入已开启，缓冲内容已隐藏且不能发送" }
        if let pluginFailure = normalized(pluginFailure) {
            if pluginFailure.contains("未保存") {
                return "后台插件结果未进入收信箱；请清理收信箱后重新生成"
            }
            return "插件生成没有完成，请重新生成"
        }
        switch availability {
        case .ready:
            return "当前输入框可以接收缓冲内容"
        case let .blocked(reason):
            if reason == .noFocusedField, canGenerateWithoutFocus {
                return "可以先生成内容；发送前请点选要接收文字的外部输入框"
            }
            return reason.message
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private final class BufferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BufferDragHandleView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: BufferWorkbenchLayout.dragCursor.cursor)
    }
}

private final class FirstMousePopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// `NSMenuItem.representedObject` cannot distinguish a missing value from an
/// object whose raw identifier happens to match another plugin domain. Keep
/// the complete namespaced key in one small reference box instead of relying
/// on menu indices or integer tags.
private final class BufferPluginMenuIdentity: NSObject {
    let key: PluginKey?

    init(_ key: PluginKey?) {
        self.key = key
    }
}

private final class BufferMainControlSlot: NSView {
    private let row: BufferMainControlRow
    private var heightConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!

    init(control: NSView, row: BufferMainControlRow) {
        self.row = row
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        let height = heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.railHeight(for: .standard)
        )
        let centerY = control.centerYAnchor.constraint(equalTo: centerYAnchor)
        heightConstraint = height
        centerYConstraint = centerY
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            height,
            control.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(for mode: BufferWorkbenchLayoutMode) {
        heightConstraint.constant = BufferWorkbenchMetrics.railHeight(for: mode)
        centerYConstraint.constant = BufferWorkbenchMetrics.mainControlYOffset(row: row,
                                                                                mode: mode)
    }
}

/// Keeps an action bound to its declarative identity instead of to a mutable
/// array index. Status polling may update titles/enabled state every second;
/// the button itself must remain in place while that happens.
private final class BufferPluginActionButton: FirstMouseButton {
    var pluginKey: ActionPluginKey?
}

/// The material clips to a continuous rounded rect while a separate inset
/// hairline remains fully inside the backing pixels. Keeping the stroke away
/// from the window boundary prevents the half-clipped fringe seen on Retina.
private final class BufferChromeView: NSVisualEffectView {
    private let fillLayer = CALayer()
    private let strokeLayer = CAShapeLayer()
    var fillColor: NSColor = .windowBackgroundColor {
        didSet { fillLayer.backgroundColor = fillColor.cgColor }
    }
    var strokeColor: NSColor = .separatorColor {
        didSet { strokeLayer.strokeColor = strokeColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fillLayer.backgroundColor = fillColor.cgColor
        layer?.addSublayer(fillLayer)
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = strokeColor.cgColor
        strokeLayer.zPosition = 100
        layer?.addSublayer(strokeLayer)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(scale, 1)
        strokeLayer.contentsScale = scale
        fillLayer.contentsScale = scale
        fillLayer.frame = bounds
        strokeLayer.frame = bounds
        strokeLayer.lineWidth = lineWidth
        strokeLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: max(0, 9 - lineWidth / 2),
            cornerHeight: max(0, 9 - lineWidth / 2),
            transform: nil
        )
    }
}

/// Stable, nonactivating workbench window. It owns presentation only; all text
/// delivery still flows through BufferDeliveryCoordinator -> Delivery.insert.
final class BufferWindowController: NSObject, NSWindowDelegate {
    static let shared = BufferWindowController()

    private enum Key {
        static let visible = "bufferWindow.visible.v1"
        static let frame = "bufferWindow.frame.v2"
        static let legacyFrame = "bufferWindow.frame.v1"
        static let pinned = "bufferWindow.pinned.v1"
        static let placement = "bufferWindow.candidatePlacement.v1"
        static let controlsExpanded = "bufferWindow.controlsExpanded.v1"
    }

    private let panel: BufferPanel
    private let outerContainer = NSView()
    private let visual = BufferChromeView()
    private let bufferRail = BufferInlineView()
    private lazy var translationBridgeView = AppleTranslationWorkspace.shared.makeBridgeView()
    private let utilityShelf = NSStackView()
    private let shelfDivider = NSView()
    private let dragHandle = BufferDragHandleView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pluginActionsControl = NSStackView()
    private let pluginSelector = FirstMousePopUpButton()
    private let pluginLoadingIndicator = NSProgressIndicator()
    private let pluginButtonRow = NSStackView()
    private let translationSourcePopup = FirstMousePopUpButton()
    private let translationTargetPopup = FirstMousePopUpButton()
    private let translationSwapButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let aiGenerateButton = FirstMouseButton(title: "生成", target: nil, action: nil)
    private let disclosureButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let sendButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let refreshButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private lazy var dragHandleSlot = BufferMainControlSlot(control: dragHandle, row: .source)
    private lazy var disclosureSlot = BufferMainControlSlot(control: disclosureButton, row: .source)
    private lazy var sendSlot = BufferMainControlSlot(control: sendButton, row: .target)
    private var hiddenForSession = false
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var adjustingFrame = false
    private var controlsExpanded = false
    private var layoutMode: BufferWorkbenchLayoutMode = .standard
    private var mainBarHeightConstraint: NSLayoutConstraint?
    private var bufferRailHeightConstraint: NSLayoutConstraint?
    private var observers: [NSObjectProtocol] = []
    private var secureInputPollTimer: Timer?
    private var pluginStatusPollTimer: Timer?
    private var pluginSelectorRefreshScheduled = false
    private var lastSecureInputState = IsSecureEventInputEnabled()
    private var renderedPluginKeys: [ActionPluginPresentationKey] = []
    private var pluginActionButtons: [ActionPluginPresentationKey: BufferPluginActionButton] = [:]
    private var renderingTranslationControls = false
    private var renderingAIControls = false
    private var renderedTranslationLanguages: [TranslationLanguageOption] = []

    var isVisible: Bool {
        BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace
        )
    }
    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Key.pinned) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pinned)
            applyCollectionBehavior()
            refresh()
        }
    }
    var candidatePlacement: BufferCandidatePlacement {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.placement)
            return raw.flatMap(BufferCandidatePlacement.init(rawValue:)) ?? .workbench
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.placement)
            RimeBufferController.refreshActiveUI()
            refresh()
        }
    }
    var shouldProjectCandidates: Bool {
        isVisible && !hiddenForSession && candidatePlacement == .workbench
    }
    var candidateAnchorRect: NSRect? {
        guard shouldProjectCandidates,
              !IsSecureEventInputEnabled(),
              !sessionProtectionActive else { return nil }
        return BufferWindowGeometry.candidateAnchor(for: panel.frame)
    }

    private override init() {
        let expanded = UserDefaults.standard.bool(forKey: Key.controlsExpanded)
        let initialLayoutMode: BufferWorkbenchLayoutMode =
            (AppleTranslationWorkspace.shared.isSelected || AITextWorkspaceRouter.isSelected)
                ? .translation
                : .standard
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 760,
                                                height: BufferWindowGeometry.height(
                                                    expanded: expanded,
                                                    mode: initialLayoutMode
                                                )),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered,
                            defer: false)
        super.init()
        controlsExpanded = expanded
        layoutMode = initialLayoutMode
        buildWindow()
        restoreFrame()
        installObservers()
    }

    func showOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: Key.visible) == nil
            ? BufferModel.shared.enabled
            : defaults.bool(forKey: Key.visible)
        if visible { show() }
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Key.visible)
        guard !sessionProtectionActive else {
            hiddenForSession = true
            return
        }
        hiddenForSession = false
        ActionPluginHost.shared.refreshStatuses(force: true)
        clampFrameToScreens()
        refresh()
        // Re-ordering is required for an unpinned panel that is still ordered
        // on another Space. `.moveToActiveSpace` applies when it is ordered
        // again; simply calling orderFront on the old ordered window may leave
        // it attached to the old Space.
        if panel.isVisible, !panel.isOnActiveSpace, !pinned {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
        RimeBufferController.refreshActiveUI()
    }

    /// Explicit user-facing open actions resume capture after a previous
    /// close-and-pause. Passive restoration still uses `show()` so it does not
    /// silently change the persisted buffer mode.
    func openAndResume() {
        BufferModel.shared.enabled = true
        show()
    }

    func hideWithoutPausing() {
        UserDefaults.standard.set(false, forKey: Key.visible)
        panel.orderOut(nil)
        RimeBufferController.refreshActiveUI()
    }

    /// The optional external-app privacy purge clears staged plaintext and all
    /// plugin state before a different application can become the target.
    func discardForPrivacyTransition() {
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        BufferModel.shared.discardForPrivacy()
    }

    /// Product default: close means resolve the current composition into the
    /// buffer, pause capture, keep staged blocks, settle transient state, then hide.
    func closeAndPause() {
        if let target = InputFocusCoordinator.shared.owner,
           InputFocusCoordinator.shared.isCurrent(target.token),
           target.compositionActive {
            target.controller?.resolveCompositionForWorkbenchTransition(target: target)
        }
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        AITextWorkspaceRouter.reset()
        BufferModel.shared.pauseCapturePreservingContent()
        hideWithoutPausing()
    }

    func toggleVisibility() {
        isVisible ? closeAndPause() : openAndResume()
    }

    func moveToCurrentScreen() {
        let point = NSEvent.mouseLocation
        let target = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = panel.frame
        frame.origin = NSPoint(x: target.midX - frame.width / 2,
                               y: target.midY - frame.height / 2)
        applyClampedFrame(frame,
                          visibleFrames: [target],
                          fallback: target,
                          display: true)
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    func setEnterHoldProgress(_ progress: Double?) {
        bufferRail.setEnterHoldProgress(progress)
    }

    /// Dev-only visual regression hook used by `panel-render`. Rendering the
    /// real controller prevents the preview and shipped workbench from drifting
    /// into two unrelated designs again.
    @discardableResult
    func renderForPreview(to path: String,
                          expanded: Bool = false,
                          scale: CGFloat = 2,
                          translationSnapshot: TranslationRailSnapshot? = nil) -> Bool {
        controlsExpanded = expanded
        applyExpandedPresentation()
        let previewMode: BufferWorkbenchLayoutMode = translationSnapshot == nil
            ? ((AppleTranslationWorkspace.shared.isSelected || AITextWorkspaceRouter.isSelected)
                ? .translation
                : .standard)
            : .translation
        syncLayoutMode(previewMode)
        adjustingFrame = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 760,
                              height: BufferWindowGeometry.height(expanded: expanded,
                                                                  mode: previewMode)),
                       display: false)
        adjustingFrame = false
        if let translationSnapshot {
            statusLabel.stringValue = "译文可发送"
            _ = bufferRail.renderTranslationForPreview(translationSnapshot)
            applyAppearance()
        } else {
            refresh()
        }
        guard let contentView = panel.contentView else { return false }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        let renderScale = max(1, scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * renderScale).rounded()),
            pixelsHigh: Int((bounds.height * renderScale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let availability = BufferDeliveryCoordinator.shared.availability()
        let secureInputEnabled = IsSecureEventInputEnabled()
        pluginSelector.isEnabled = !secureInputEnabled
        AppleTranslationWorkspace.shared.setProtected(
            secureInputEnabled || sessionProtectionActive
        )
        AITextWorkspaceRouter.setProtected(
            secureInputEnabled || sessionProtectionActive
        )
        let translationSelected = AppleTranslationWorkspace.shared.isSelected
        let aiTextSelected = AITextWorkspaceRouter.isSelected
        let derivedWorkspaceSelected = translationSelected || aiTextSelected
        syncLayoutMode(derivedWorkspaceSelected ? .translation : .standard)
        let pluginFailure = derivedWorkspaceSelected
            ? nil
            : ActionPluginHost.shared.workbenchFailureMessage
        let canGenerateWithoutFocus = !derivedWorkspaceSelected
            && ActionPluginHost.shared.presentations.contains {
                !$0.requiresFocus && $0.canInvoke
            }
        lastSecureInputState = secureInputEnabled
        if !secureInputEnabled, translationSelected {
            statusLabel.stringValue = AppleTranslationWorkspace.shared.statusText
        } else if !secureInputEnabled, let aiStatus = AITextWorkspaceRouter.statusText {
            statusLabel.stringValue = aiStatus
        } else {
            statusLabel.stringValue = BufferWorkbenchStatusText.text(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
            )
        }
        statusLabel.toolTip = !secureInputEnabled && derivedWorkspaceSelected
            ? statusLabel.stringValue
            : BufferWorkbenchStatusText.help(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
            )
        statusLabel.textColor = RimeUI.textSecondary

        _ = bufferRail.refresh(shielded: secureInputEnabled)
        assert(!secureInputEnabled || bufferRail.isHidden,
               "secure input must leave the text-bearing rail hidden")
        sendButton.isEnabled = availability.canSend
            && !secureInputEnabled
        sendButton.toolTip = availability.canSend ? "发送全部缓冲块" : availability.label
        refreshButton.isEnabled = BufferPluginSelectionStore.shared.activeKey != nil
            && !secureInputEnabled
        refreshButton.toolTip = refreshButton.isEnabled
            ? "刷新或重置当前插件（保留缓冲正文）"
            : "当前没有可刷新的缓冲插件"
        refreshPluginActions()
        applyAppearance()
    }

    /// Every ETInput-owned text field is an internal UI surface, not a draft
    /// source or a remote-mirroring target.
    func isOwnClient(bundleID: String) -> Bool {
        let own = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
        return bundleID == own
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame else { return }
        if let visibleFrame = panel.screen?.visibleFrame {
            syncMinimumSize(to: visibleFrame)
            if panel.frame.width > visibleFrame.width
                || panel.frame.height > visibleFrame.height {
                clampFrameToScreens()
                return
            }
        }
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjustingFrame else { return }
        clampFrameToScreens()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard !adjustingFrame else { return }
        let aligned = BufferWindowGeometry.pixelAligned(
            panel.frame,
            scale: panel.backingScaleFactor
        )
        if aligned != panel.frame {
            adjustingFrame = true
            panel.setFrame(aligned, display: true)
            adjustingFrame = false
        }
        visual.needsLayout = true
        bufferRail.needsLayout = true
        panel.invalidateShadow()
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = BufferWorkbenchLayout.windowBackgroundDraggable
        panel.minSize = NSSize(width: BufferWindowGeometry.standardMinimumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: controlsExpanded,
                                   mode: layoutMode
                               ))
        panel.maxSize = NSSize(width: BufferWindowGeometry.standardMaximumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: controlsExpanded,
                                   mode: layoutMode
                               ))
        panel.delegate = self
        applyCollectionBehavior()

        outerContainer.wantsLayer = true
        outerContainer.layer?.backgroundColor = NSColor.clear.cgColor
        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.translatesAutoresizingMaskIntoConstraints = false
        outerContainer.addSubview(visual)
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor, constant: 2),
            visual.trailingAnchor.constraint(equalTo: outerContainer.trailingAnchor, constant: -2),
            visual.topAnchor.constraint(equalTo: outerContainer.topAnchor, constant: 2),
            visual.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor, constant: -2),
        ])
        panel.contentView = outerContainer

        outerContainer.addSubview(translationBridgeView)
        NSLayoutConstraint.activate([
            translationBridgeView.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor,
                                                            constant: 3),
            translationBridgeView.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor,
                                                           constant: -3),
            translationBridgeView.widthAnchor.constraint(equalToConstant: 1),
            translationBridgeView.heightAnchor.constraint(equalToConstant: 1),
        ])

        dragHandle.image = RimeUI.symbol("line.3.horizontal", pointSize: 12, weight: .semibold)
        dragHandle.image?.isTemplate = true
        dragHandle.imageScaling = .scaleProportionallyDown
        dragHandle.toolTip = "拖动缓冲工作台"
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.setContentHuggingPriority(.required, for: .horizontal)
        dragHandle.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            dragHandle.heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
        ])

        configureIconButton(disclosureButton,
                            controlsExpanded ? "chevron.down" : "chevron.up",
                            controlsExpanded ? "收起功能" : "向上展开功能",
                            #selector(disclosureTapped))
        configureIconButton(sendButton, "paperplane.fill", "发送全部缓冲块", #selector(sendTapped))
        configureIconButton(refreshButton,
                            "arrow.clockwise",
                            "刷新或重置当前插件（保留缓冲正文）",
                            #selector(refreshPluginTapped))
        configureIconButton(closeButton, "xmark", "关闭并暂停缓冲（保留内容）", #selector(closeTapped))

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.userInterfaceLayoutDirection = .leftToRight
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pluginSelector.controlSize = .mini
        pluginSelector.font = .systemFont(ofSize: 10, weight: .semibold)
        pluginSelector.target = self
        pluginSelector.action = #selector(bufferPluginSelectionChanged)
        pluginSelector.toolTip = "切换缓冲插件"
        pluginSelector.translatesAutoresizingMaskIntoConstraints = false
        let pluginSelectorMinimumWidth = pluginSelector.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 64
        )
        pluginSelectorMinimumWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            pluginSelectorMinimumWidth,
            pluginSelector.widthAnchor.constraint(lessThanOrEqualToConstant: 108),
        ])
        pluginSelector.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        pluginSelector.setContentCompressionResistancePriority(.defaultLow,
                                                               for: .horizontal)

        pluginButtonRow.orientation = .horizontal
        pluginButtonRow.alignment = .centerY
        pluginButtonRow.distribution = .fill
        pluginButtonRow.spacing = 2
        pluginButtonRow.detachesHiddenViews = false
        pluginButtonRow.userInterfaceLayoutDirection = .leftToRight
        pluginButtonRow.setContentHuggingPriority(.required, for: .horizontal)
        pluginButtonRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        for popup in [translationSourcePopup, translationTargetPopup] {
            popup.controlSize = .mini
            popup.font = .systemFont(ofSize: 10)
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }
        translationSourcePopup.target = self
        translationSourcePopup.action = #selector(translationSourceChanged)
        translationTargetPopup.target = self
        translationTargetPopup.action = #selector(translationTargetChanged)
        translationSwapButton.image = RimeUI.symbol("arrow.left.arrow.right",
                                                   pointSize: 9,
                                                   weight: .semibold)
        translationSwapButton.image?.isTemplate = true
        translationSwapButton.imagePosition = .imageOnly
        translationSwapButton.isBordered = false
        translationSwapButton.focusRingType = .none
        translationSwapButton.toolTip = "交换源语言和目标语言"
        translationSwapButton.target = self
        translationSwapButton.action = #selector(translationSwapTapped)
        translationSwapButton.translatesAutoresizingMaskIntoConstraints = false
        translationSwapButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        translationSwapButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        aiGenerateButton.image = RimeUI.symbol("sparkles", pointSize: 10, weight: .semibold)
        aiGenerateButton.image?.isTemplate = true
        aiGenerateButton.imagePosition = .imageLeading
        aiGenerateButton.font = .systemFont(ofSize: 10, weight: .medium)
        aiGenerateButton.isBordered = false
        aiGenerateButton.focusRingType = .none
        aiGenerateButton.controlSize = .small
        aiGenerateButton.target = self
        aiGenerateButton.action = #selector(aiGenerateTapped)
        aiGenerateButton.setContentHuggingPriority(.required, for: .horizontal)
        aiGenerateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        pluginLoadingIndicator.style = .spinning
        pluginLoadingIndicator.controlSize = .small
        pluginLoadingIndicator.isDisplayedWhenStopped = false
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        pluginLoadingIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pluginLoadingIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
        pluginLoadingIndicator.setContentHuggingPriority(.required, for: .horizontal)
        pluginLoadingIndicator.setContentCompressionResistancePriority(.required,
                                                                       for: .horizontal)

        // This is one persistent region, not a transient list of buttons. The
        // plugin selector stays at its leading edge while status updates only
        // mutate the existing action controls in place.
        pluginActionsControl.orientation = .horizontal
        pluginActionsControl.alignment = .centerY
        pluginActionsControl.distribution = .fill
        pluginActionsControl.spacing = 4
        pluginActionsControl.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 3)
        pluginActionsControl.detachesHiddenViews = false
        pluginActionsControl.userInterfaceLayoutDirection = .leftToRight
        pluginActionsControl.wantsLayer = true
        pluginActionsControl.layer?.cornerRadius = 6
        pluginActionsControl.addArrangedSubview(pluginSelector)
        pluginActionsControl.addArrangedSubview(pluginLoadingIndicator)
        pluginActionsControl.addArrangedSubview(pluginButtonRow)
        pluginActionsControl.setContentHuggingPriority(.required, for: .horizontal)
        pluginActionsControl.setContentCompressionResistancePriority(.defaultHigh,
                                                                     for: .horizontal)

        utilityShelf.orientation = .horizontal
        utilityShelf.alignment = .centerY
        utilityShelf.distribution = .fill
        utilityShelf.spacing = BufferWorkbenchMetrics.shelfSpacing
        utilityShelf.detachesHiddenViews = false
        utilityShelf.userInterfaceLayoutDirection = .leftToRight
        utilityShelf.edgeInsets = NSEdgeInsets(
            top: 4,
            left: BufferWorkbenchMetrics.shelfHorizontalInset,
            bottom: 4,
            right: BufferWorkbenchMetrics.shelfHorizontalInset
        )
        BufferWorkbenchLayout.expandedShelf.forEach { control in
            utilityShelf.addArrangedSubview(view(for: control))
        }

        shelfDivider.wantsLayer = true
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor

        let mainBar = NSStackView(
            views: BufferWorkbenchLayout.mainBar.map { view(for: $0) }
        )
        mainBar.orientation = .horizontal
        mainBar.alignment = .centerY
        mainBar.distribution = .fill
        mainBar.spacing = BufferWorkbenchMetrics.mainSpacing
        mainBar.detachesHiddenViews = false
        mainBar.userInterfaceLayoutDirection = .leftToRight
        mainBar.edgeInsets = NSEdgeInsets(
            top: 3,
            left: BufferWorkbenchMetrics.mainHorizontalInset,
            bottom: 3,
            right: BufferWorkbenchMetrics.mainHorizontalInset
        )

        let root = NSStackView(views: [utilityShelf, shelfDivider, mainBar])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(root)
        let mainBarHeight = mainBar.heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.mainBarHeight(for: layoutMode)
        )
        let railHeight = bufferRail.heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.railHeight(for: layoutMode)
        )
        mainBarHeightConstraint = mainBarHeight
        bufferRailHeightConstraint = railHeight
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            root.topAnchor.constraint(equalTo: visual.topAnchor),
            root.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            utilityShelf.heightAnchor.constraint(equalToConstant: 33),
            shelfDivider.heightAnchor.constraint(equalToConstant: 1),
            mainBarHeight,
            bufferRail.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            railHeight,
        ])
        updateMainControlAlignment(for: layoutMode)
        applyExpandedPresentation()
        applyAppearance()
        rebuildPluginSelector()
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     _ symbol: String,
                                     _ toolTip: String,
                                     _ action: Selector) {
        button.image = RimeUI.symbol(symbol, pointSize: 11, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
    }

    private func view(for control: BufferWorkbenchControl) -> NSView {
        switch control {
        case .dragHandle: return dragHandleSlot
        case .disclosure: return disclosureSlot
        case .bufferRail: return bufferRail
        case .send: return sendSlot
        case .status: return statusLabel
        case .pluginActions: return pluginActionsControl
        case .refresh: return refreshButton
        case .close: return closeButton
        }
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        visual.material = RimeUI.isNight ? .hudWindow : .popover
        visual.fillColor = RimeUI.workbenchChrome
        visual.strokeColor = RimeUI.borderStrong
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        dragHandle.contentTintColor = RimeUI.textSecondary
        pluginActionsControl.layer?.backgroundColor = RimeUI.surface2.cgColor
        pluginActionsControl.layer?.borderColor = RimeUI.border.cgColor
        pluginActionsControl.layer?.borderWidth = 1 / max(panel.backingScaleFactor, 1)
        [refreshButton, closeButton, sendButton, disclosureButton].forEach {
            $0.contentTintColor = RimeUI.textSecondary
        }
        translationSwapButton.contentTintColor = RimeUI.textSecondary
        aiGenerateButton.contentTintColor = aiGenerateButton.isEnabled
            ? RimeUI.accentBlue
            : RimeUI.textSecondary
        pluginActionButtons.values.forEach {
            $0.contentTintColor = $0.isEnabled ? RimeUI.accentBlue : RimeUI.textSecondary
        }
    }

    private func refreshPluginActions() {
        if AppleTranslationWorkspace.shared.isSelected {
            refreshTranslationControls()
            return
        }
        if AITextWorkspaceRouter.isSelected {
            refreshAITextControls()
            return
        }
        if renderingTranslationControls {
            renderingTranslationControls = false
            renderedTranslationLanguages.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
        }
        if renderingAIControls {
            renderingAIControls = false
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
        }
        let presentations = ActionPluginHost.shared.presentations
        let waitingForFirstContent = presentations.contains(where: \.waitingForFirstContent)
        pluginLoadingIndicator.isHidden = !waitingForFirstContent
        if waitingForFirstContent {
            pluginLoadingIndicator.startAnimation(nil)
        } else {
            pluginLoadingIndicator.stopAnimation(nil)
        }
        let pluginNames = presentations.reduce(into: [String]()) { names, presentation in
            guard !names.contains(presentation.pluginName) else { return }
            names.append(presentation.pluginName)
        }
        pluginSelector.toolTip = pluginNames.isEmpty
            ? "切换缓冲插件"
            : "当前插件：\(pluginNames.joined(separator: "、"))"

        let keys = presentations.map(\.presentationKey)
        if keys != renderedPluginKeys {
            renderedPluginKeys = keys
            let previousButtons = pluginActionButtons
            var nextButtons: [ActionPluginPresentationKey: BufferPluginActionButton] = [:]
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for presentation in presentations {
                let button = previousButtons[presentation.presentationKey]
                    ?? BufferPluginActionButton(title: "",
                                                target: self,
                                                action: #selector(pluginActionTapped(_:)))
                button.pluginKey = presentation.key
                nextButtons[presentation.presentationKey] = button
                pluginButtonRow.addArrangedSubview(button)
            }
            pluginActionButtons = nextButtons
        }

        for presentation in presentations {
            guard let button = pluginActionButtons[presentation.presentationKey] else { continue }
            // The presentation key stays stable while status switches the
            // contextual wire action underneath this one visible control.
            button.pluginKey = presentation.key
            button.title = presentation.running ? "生成中…" : presentation.title
            button.image = RimeUI.symbol(presentation.running ? "hourglass" : presentation.symbol,
                                         pointSize: 10,
                                         weight: .semibold)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.isBordered = false
            button.focusRingType = .none
            button.controlSize = .small
            button.isEnabled = presentation.canInvoke
            var help = "\(presentation.pluginName) · \(presentation.label)"
            if let summary = presentation.targetSummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                help += "\n\(summary)"
            }
            if !presentation.available { help += "\n等待插件提供投放目标" }
            button.toolTip = help
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    private func refreshTranslationControls() {
        let workspace = AppleTranslationWorkspace.shared
        pluginSelector.toolTip = "当前插件：苹果本地翻译"
        let loading = workspace.phase == .waiting || workspace.phase == .translating
        pluginLoadingIndicator.isHidden = !loading
        loading ? pluginLoadingIndicator.startAnimation(nil)
                : pluginLoadingIndicator.stopAnimation(nil)

        if !renderingTranslationControls {
            renderingTranslationControls = true
            renderingAIControls = false
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            pluginButtonRow.addArrangedSubview(translationSourcePopup)
            pluginButtonRow.addArrangedSubview(translationSwapButton)
            pluginButtonRow.addArrangedSubview(translationTargetPopup)
        }

        if renderedTranslationLanguages != workspace.languageOptions {
            renderedTranslationLanguages = workspace.languageOptions
            translationSourcePopup.removeAllItems()
            translationTargetPopup.removeAllItems()
            for option in workspace.languageOptions {
                translationSourcePopup.addItem(withTitle: option.title)
                translationSourcePopup.lastItem?.representedObject = option.identifier
                translationTargetPopup.addItem(withTitle: option.title)
                translationTargetPopup.lastItem?.representedObject = option.identifier
            }
        }
        selectPopup(translationSourcePopup,
                    representedValue: workspace.sourceLanguageID)
        selectPopup(translationTargetPopup,
                    representedValue: workspace.targetLanguageID)
        translationSwapButton.isEnabled = workspace.canSwapLanguages
    }

    private func refreshAITextControls() {
        guard let workspace = AITextWorkspaceRouter.selectedWorkspace else { return }
        pluginSelector.toolTip = "当前插件：\(workspace.kind.displayName)"
        let loading = workspace.phase == .running
        // The target rail owns the animated first-content indicator. Keep the
        // shelf compact and avoid showing the same spinner twice.
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.stopAnimation(nil)

        if !renderingAIControls {
            renderingAIControls = true
            renderingTranslationControls = false
            renderedTranslationLanguages.removeAll()
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            pluginButtonRow.addArrangedSubview(aiGenerateButton)
        }
        aiGenerateButton.title = loading ? "生成中…" : "生成"
        aiGenerateButton.image = RimeUI.symbol(loading ? "hourglass" : "sparkles",
                                               pointSize: 10,
                                               weight: .semibold)
        aiGenerateButton.image?.isTemplate = true
        aiGenerateButton.isEnabled = workspace.canGenerate && !IsSecureEventInputEnabled()
        aiGenerateButton.toolTip = aiGenerateButton.isEnabled
            ? "用 \(workspace.kind.displayName) 处理当前全部缓冲内容"
            : workspace.statusText
    }

    private func selectPopup(_ popup: NSPopUpButton, representedValue: String) {
        guard let index = (0..<popup.numberOfItems).first(where: {
            guard let itemValue = popup.item(at: $0)?.representedObject as? String else {
                return false
            }
            return TranslationLanguageIdentity.matches(itemValue,
                                                       expected: representedValue)
        }) else { return }
        popup.selectItem(at: index)
    }

    private func applyExpandedPresentation() {
        utilityShelf.isHidden = !controlsExpanded
        shelfDivider.isHidden = !controlsExpanded
        disclosureButton.image = RimeUI.symbol(
            controlsExpanded ? "chevron.down" : "chevron.up",
            pointSize: 12,
            weight: .semibold
        )
        disclosureButton.image?.isTemplate = true
        disclosureButton.toolTip = controlsExpanded ? "收起功能" : "向上展开功能"
    }

    private func syncLayoutMode(_ nextMode: BufferWorkbenchLayoutMode) {
        updateMainControlAlignment(for: nextMode)
        guard layoutMode != nextMode else { return }
        layoutMode = nextMode
        mainBarHeightConstraint?.constant = BufferWorkbenchMetrics.mainBarHeight(for: nextMode)
        bufferRailHeightConstraint?.constant = BufferWorkbenchMetrics.railHeight(for: nextMode)
        var proposed = panel.frame
        proposed.size.height = BufferWindowGeometry.height(expanded: controlsExpanded,
                                                           mode: nextMode)
        let fallback = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(proposed,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: panel.isVisible)
        visual.needsLayout = true
        bufferRail.needsLayout = true
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    private func updateMainControlAlignment(for mode: BufferWorkbenchLayoutMode) {
        dragHandleSlot.update(for: mode)
        disclosureSlot.update(for: mode)
        sendSlot.update(for: mode)
    }

    private func applyCollectionBehavior() {
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace]
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.clampFrameToScreens()
            candidateWindow.syncWorkbenchAnchor(self?.candidateAnchorRect)
        })
        observers.append(center.addObserver(forName: .rimeAppearanceDidChange,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .appleTranslationWorkspaceDidChange,
            object: AppleTranslationWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .aiTextPluginWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePluginSelectorRefresh()
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .pluginRegistryDidChange,
            object: PluginRegistry.shared,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePluginSelectorRefresh()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refresh()
            RimeBufferController.refreshActiveUI()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sessionInactive = true
            self?.protectForSession(reason: "session resigned")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sessionInactive = false
            self?.restoreAfterSessionProtection()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.protectForSession(reason: "system sleep")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.restoreAfterSessionProtection()
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = true
            self?.protectForSession(reason: "screen locked")
        })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = false
            self?.restoreAfterSessionProtection()
        })
        secureInputPollTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self,
                  self.panel.isVisible else { return }
            let current = IsSecureEventInputEnabled()
            guard current != self.lastSecureInputState else { return }
            self.lastSecureInputState = current
            if current {
                ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            }
            self.refresh()
            RimeBufferController.refreshActiveUI()
        }
        if let secureInputPollTimer {
            RunLoop.main.add(secureInputPollTimer, forMode: .common)
        }
        pluginStatusPollTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  self.isVisible,
                  !self.hiddenForSession,
                  !AppleTranslationWorkspace.shared.isSelected,
                  !AITextWorkspaceRouter.isSelected else { return }
            ActionPluginHost.shared.refreshStatuses()
        }
        if let pluginStatusPollTimer {
            RunLoop.main.add(pluginStatusPollTimer, forMode: .common)
        }
    }

    private func protectForSession(reason: String) {
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        AppleTranslationWorkspace.shared.setProtected(true)
        AITextWorkspaceRouter.setProtected(true)
        if let lease = InputFocusCoordinator.shared.invalidateAll(reason: reason) {
            lease.controller?.finalizeProtectedSession(lease, reason: reason)
            candidateWindow.hide(owner: lease.token)
        } else {
            candidateWindow.hideAll()
        }
        if panel.isVisible || UserDefaults.standard.bool(forKey: Key.visible) {
            hiddenForSession = true
            panel.orderOut(nil)
        }
    }

    private func restoreAfterSessionProtection() {
        AppleTranslationWorkspace.shared.setProtected(sessionProtectionActive)
        AITextWorkspaceRouter.setProtected(sessionProtectionActive)
        guard hiddenForSession,
              !sessionProtectionActive,
              UserDefaults.standard.bool(forKey: Key.visible) else { return }
        hiddenForSession = false
        refresh()
        panel.orderFrontRegardless()
        RimeBufferController.refreshActiveUI()
    }

    private func restoreFrame() {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Key.frame).map(NSRectFromString)
            ?? defaults.string(forKey: Key.legacyFrame).map(NSRectFromString)
            ?? NSRect(x: fallback.midX - 340,
                      y: fallback.midY - BufferWindowGeometry.collapsedHeight / 2,
                      width: 680,
                      height: BufferWindowGeometry.collapsedHeight)
        applyClampedFrame(stored,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: false)
    }

    private func clampFrameToScreens() {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(panel.frame,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: true)
        saveFrame()
    }

    private func applyClampedFrame(_ proposed: NSRect,
                                   visibleFrames: [NSRect],
                                   fallback: NSRect,
                                   display: Bool) {
        let clamped = BufferWindowGeometry.clampedFrame(
            proposed,
            expanded: controlsExpanded,
            mode: layoutMode,
            visibleFrames: visibleFrames,
            fallback: fallback
        )
        let frame = BufferWindowGeometry.pixelAligned(
            clamped,
            scale: panel.backingScaleFactor
        )
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visibleFrame = visibleFrames.first { $0.contains(center) } ?? fallback
        syncMinimumSize(to: visibleFrame)
        adjustingFrame = true
        panel.setFrame(frame, display: display)
        adjustingFrame = false
        visual.needsLayout = true
        panel.invalidateShadow()
    }

    private func syncMinimumSize(to visibleFrame: NSRect) {
        let usableWidth = max(1, visibleFrame.width - BufferWindowGeometry.screenSafetyMargin * 2)
        let targetHeight = min(BufferWindowGeometry.height(expanded: controlsExpanded,
                                                            mode: layoutMode),
                               visibleFrame.height)
        panel.minSize = NSSize(
            width: min(BufferWindowGeometry.standardMinimumWidth, usableWidth),
            height: targetHeight
        )
        panel.maxSize = NSSize(
            width: min(BufferWindowGeometry.standardMaximumWidth, usableWidth),
            height: targetHeight
        )
    }

    private var sessionProtectionActive: Bool {
        sessionInactive || screenLocked || sleeping
    }

    private func saveFrame() {
        var canonical = panel.frame
        canonical.size.height = BufferWindowGeometry.collapsedHeight
        UserDefaults.standard.set(NSStringFromRect(canonical), forKey: Key.frame)
    }

    // MARK: - Actions

    private func schedulePluginSelectorRefresh() {
        guard !pluginSelectorRefreshScheduled else { return }
        pluginSelectorRefreshScheduled = true
        // Registry and selection notifications can be emitted synchronously
        // from this popup's own action. Rebuilding on the next main-loop turn
        // avoids removing an NSMenuItem while AppKit is still dispatching it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pluginSelectorRefreshScheduled = false
            self.rebuildPluginSelector()
            self.refresh()
        }
    }

    private func rebuildPluginSelector() {
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        let activeKey = BufferPluginSelectionStore.shared.activeKey
        pluginSelector.removeAllItems()
        pluginSelector.addItem(withTitle: "无插件")
        pluginSelector.lastItem?.representedObject = BufferPluginMenuIdentity(nil)
        for plugin in plugins {
            pluginSelector.addItem(withTitle: plugin.descriptor.name)
            pluginSelector.lastItem?.representedObject = BufferPluginMenuIdentity(
                plugin.descriptor.key
            )
        }
        let selectedIndex = (0..<pluginSelector.numberOfItems).first { index in
            guard let identity = pluginSelector.item(at: index)?.representedObject
                    as? BufferPluginMenuIdentity else { return false }
            return identity.key == activeKey
        } ?? 0
        pluginSelector.selectItem(at: selectedIndex)
    }

    @objc private func bufferPluginSelectionChanged() {
        guard !IsSecureEventInputEnabled(),
              let identity = pluginSelector.selectedItem?.representedObject
                as? BufferPluginMenuIdentity else {
            schedulePluginSelectorRefresh()
            return
        }
        do {
            if let key = identity.key {
                try PluginRegistry.shared.setBufferPluginActive(true, for: key)
            } else {
                BufferPluginSelectionStore.shared.clear()
            }
        } catch {
            NSSound.beep()
            IMELog.write("workbench plugin switch failed")
        }
        schedulePluginSelectorRefresh()
    }

    @objc private func disclosureTapped() {
        controlsExpanded.toggle()
        UserDefaults.standard.set(controlsExpanded, forKey: Key.controlsExpanded)
        applyExpandedPresentation()
        var proposed = panel.frame
        proposed.size.height = BufferWindowGeometry.height(expanded: controlsExpanded,
                                                            mode: layoutMode)
        let fallback = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(proposed,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: true)
        saveFrame()
        refresh()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    @objc private func sendTapped() {
        _ = BufferDeliveryCoordinator.shared.sendAll(resolveCompositionIfNeeded: true)
        // Delivery.insert atomically replaces the idle marked guard. Restore it
        // for the still-current external lease before the next Return.
        RimeBufferController.refreshActiveUI()
    }

    @objc private func closeTapped() { closeAndPause() }

    @objc private func refreshPluginTapped() {
        guard BufferPluginSelectionStore.shared.activeKey != nil,
              !IsSecureEventInputEnabled() else { return }
        if AppleTranslationWorkspace.shared.isSelected {
            AppleTranslationWorkspace.shared.resetAndRefresh()
        } else if AITextWorkspaceRouter.isSelected {
            _ = AITextWorkspaceRouter.resetAndRefresh()
        } else {
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            ActionPluginHost.shared.refreshStatuses(force: true)
        }
        let kind = AppleTranslationWorkspace.shared.isSelected
            ? "translation"
            : (AITextWorkspaceRouter.isSelected ? "ai-text" : "action")
        IMELog.write("buffer plugin refresh requested kind=\(kind)")
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func pluginActionTapped(_ sender: NSButton) {
        guard let key = (sender as? BufferPluginActionButton)?.pluginKey else { return }
        ActionPluginHost.shared.invoke(key)
    }

    @objc private func aiGenerateTapped() {
        guard !IsSecureEventInputEnabled() else { return }
        if !AITextWorkspaceRouter.generate() { NSSound.beep() }
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func translationSourceChanged() {
        guard let value = translationSourcePopup.selectedItem?.representedObject as? String else {
            return
        }
        AppleTranslationWorkspace.shared.setSourceLanguage(value)
    }

    @objc private func translationTargetChanged() {
        guard let value = translationTargetPopup.selectedItem?.representedObject as? String else {
            return
        }
        AppleTranslationWorkspace.shared.setTargetLanguage(value)
    }

    @objc private func translationSwapTapped() {
        if !AppleTranslationWorkspace.shared.swapLanguages() { NSSound.beep() }
    }

}
