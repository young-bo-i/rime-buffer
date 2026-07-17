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

/// Pure frame math shared by runtime restoration and the CLI smoke test.
enum BufferWindowGeometry {
    static let standardMinimumWidth: CGFloat = 520
    static let standardMaximumWidth: CGFloat = 1100
    static let collapsedHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 78
    static let standardMinimumHeight = collapsedHeight
    static let screenSafetyMargin: CGFloat = 8

    static func height(expanded: Bool) -> CGFloat {
        expanded ? expandedHeight : collapsedHeight
    }

    static func clampedFrame(_ proposed: NSRect,
                             expanded: Bool = false,
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
        let height = min(height(expanded: expanded), safeTarget.height)
        var x = proposed.width == width ? proposed.minX : proposed.midX - width / 2
        // The 52pt predecessor and both current states preserve their bottom
        // edge, keeping the candidate panel stationary. Only the legacy 340pt
        // workbench migrates by preserving its old top edge.
        var y = proposed.height <= expandedHeight + 1
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

private final class BufferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BufferDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// The material clips to a continuous rounded rect while a separate inset
/// hairline remains fully inside the backing pixels. Keeping the stroke away
/// from the window boundary prevents the half-clipped fringe seen on Retina.
private final class BufferChromeView: NSVisualEffectView {
    private let strokeLayer = CAShapeLayer()
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
    private let utilityShelf = NSStackView()
    private let shelfDivider = NSView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let disclosureButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let sendButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let clearButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let captureButton = FirstMouseButton(title: "缓冲", target: nil, action: nil)
    private let pinButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let privacyButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let editButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let historyButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let moveButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private var selectedBlockID: UUID?
    private var privacyShielded = false
    private var hiddenForSession = false
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var adjustingFrame = false
    private var controlsExpanded = false
    private var observers: [NSObjectProtocol] = []
    private var secureInputPollTimer: Timer?
    private var lastSecureInputState = IsSecureEventInputEnabled()
    private lazy var historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

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
              !privacyShielded,
              !IsSecureEventInputEnabled(),
              !sessionProtectionActive else { return nil }
        return BufferWindowGeometry.candidateAnchor(for: panel.frame)
    }

    private override init() {
        let expanded = UserDefaults.standard.bool(forKey: Key.controlsExpanded)
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 760,
                                                height: BufferWindowGeometry.height(expanded: expanded)),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered,
                            defer: false)
        super.init()
        controlsExpanded = expanded
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

    func hideWithoutPausing() {
        BufferBlockEditor.shared.saveAndCloseForWorkbenchHide()
        UserDefaults.standard.set(false, forKey: Key.visible)
        panel.orderOut(nil)
        RimeBufferController.refreshActiveUI()
    }

    /// The optional external-app privacy purge must also remove plaintext from
    /// an editor that was left open while the user switched applications.
    func discardForPrivacyTransition() {
        BufferBlockEditor.shared.protectAndClose(reason: "external app switch")
        BufferModel.shared.discardForPrivacy()
    }

    /// Product default: close means resolve the current composition into the
    /// buffer, pause capture, keep content, then hide. Clear is a separate action.
    func closeAndPause() {
        if let target = InputFocusCoordinator.shared.owner,
           InputFocusCoordinator.shared.isCurrent(target.token),
           target.compositionActive {
            target.controller?.resolveCompositionForWorkbenchTransition(target: target)
        }
        BufferModel.shared.pauseCapturePreservingContent()
        hideWithoutPausing()
    }

    func toggleVisibility() {
        isVisible ? closeAndPause() : show()
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
                          scale: CGFloat = 2) -> Bool {
        controlsExpanded = expanded
        applyExpandedPresentation()
        adjustingFrame = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 760,
                              height: BufferWindowGeometry.height(expanded: expanded)),
                       display: false)
        adjustingFrame = false
        refresh()
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
        captureButton.state = BufferModel.shared.enabled ? .on : .off
        pinButton.contentTintColor = pinned ? NSColor.controlAccentColor : RimeUI.textSecondary

        let availability = BufferDeliveryCoordinator.shared.availability()
        targetLabel.stringValue = compactTargetLabel(availability)
        targetLabel.toolTip = availability.label
        targetLabel.textColor = availability.canSend ? RimeUI.textSecondary : RimeUI.textMuted

        let model = BufferModel.shared
        let secureInputEnabled = IsSecureEventInputEnabled()
        lastSecureInputState = secureInputEnabled
        let shouldShield = privacyShielded || secureInputEnabled
        if shouldShield, BufferBlockEditor.shared.isVisible {
            BufferBlockEditor.shared.protectAndClose(
                reason: secureInputEnabled ? "secure input" : "privacy shield"
            )
        }
        countLabel.stringValue = shouldShield
            ? "内容已隐藏"
            : "\(model.blocks.count) 块 · \(model.stagedCharacterCount) 字"
        _ = bufferRail.refresh(shielded: shouldShield)
        assert(!shouldShield || bufferRail.isHidden,
               "privacy shield must leave the text-bearing rail hidden")

        editButton.isEnabled = !model.blocks.isEmpty && !shouldShield
        historyButton.isEnabled = (!model.sentHistory.isEmpty || model.canUndoClear) && !shouldShield
        sendButton.isEnabled = model.pendingDeliveryCount > 0
            && availability.canSend
            && !shouldShield
        sendButton.toolTip = availability.canSend ? "发送全部缓冲块" : availability.label
        clearButton.isEnabled = (!model.blocks.isEmpty || model.loadingMessage != nil)
            && !shouldShield
        applyAppearance()
    }

    /// Every ETInput-owned text field is an internal UI surface, not a draft
    /// source or a remote-mirroring target. This remains true after the block
    /// editor closes so a delayed IMK commit cannot feed back into the buffer.
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
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: BufferWindowGeometry.standardMinimumWidth,
                               height: BufferWindowGeometry.height(expanded: controlsExpanded))
        panel.maxSize = NSSize(width: BufferWindowGeometry.standardMaximumWidth,
                               height: BufferWindowGeometry.height(expanded: controlsExpanded))
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

        let title = NSTextField(labelWithString: "缓冲")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        countLabel.textColor = RimeUI.textMuted

        let drag = BufferDragHandleView()
        let dragLabels = NSStackView(views: [title, countLabel])
        dragLabels.orientation = .horizontal
        dragLabels.alignment = .centerY
        dragLabels.spacing = 5
        dragLabels.translatesAutoresizingMaskIntoConstraints = false
        drag.addSubview(dragLabels)
        NSLayoutConstraint.activate([
            dragLabels.leadingAnchor.constraint(equalTo: drag.leadingAnchor),
            dragLabels.trailingAnchor.constraint(equalTo: drag.trailingAnchor),
            dragLabels.centerYAnchor.constraint(equalTo: drag.centerYAnchor),
        ])
        drag.setContentHuggingPriority(.required, for: .horizontal)
        drag.toolTip = "拖动缓冲条"

        configureIconButton(disclosureButton,
                            controlsExpanded ? "chevron.down" : "chevron.up",
                            controlsExpanded ? "收起功能" : "向上展开功能",
                            #selector(disclosureTapped))
        configureIconButton(sendButton, "paperplane.fill", "发送全部缓冲块", #selector(sendTapped))
        configureIconButton(clearButton, "trash", "清空缓冲区", #selector(clearTapped))
        configureIconButton(captureButton, "tray.full", "启用或暂停缓冲捕获", #selector(captureToggled))
        captureButton.setButtonType(.toggle)
        configureIconButton(pinButton, "pin", "常显于所有桌面与全屏空间", #selector(pinTapped))
        configureIconButton(privacyButton, "eye.slash", "临时隐藏缓冲内容", #selector(privacyTapped))
        configureIconButton(editButton, "pencil", "编辑选中的块", #selector(editTapped))
        configureIconButton(historyButton, "clock.arrow.circlepath", "发送历史与撤销清空", #selector(historyTapped))
        configureIconButton(moveButton, "rectangle.on.rectangle", "移到鼠标所在屏幕", #selector(moveTapped))
        configureIconButton(closeButton, "xmark", "关闭并暂停缓冲（保留内容）", #selector(closeTapped))

        targetLabel.font = .systemFont(ofSize: 10)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bufferRail.onSelectionChange = { [weak self] id in
            self?.selectedBlockID = id
            self?.refresh()
        }

        utilityShelf.orientation = .horizontal
        utilityShelf.alignment = .centerY
        utilityShelf.spacing = 5
        utilityShelf.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 8)
        [targetLabel, sendButton, clearButton, captureButton, pinButton,
         privacyButton, editButton, historyButton, moveButton, closeButton].forEach {
            utilityShelf.addArrangedSubview($0)
        }

        shelfDivider.wantsLayer = true
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor

        let mainBar = NSStackView(views: [drag, bufferRail, disclosureButton])
        mainBar.orientation = .horizontal
        mainBar.alignment = .centerY
        mainBar.spacing = 6
        mainBar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 7)

        let root = NSStackView(views: [utilityShelf, shelfDivider, mainBar])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            root.topAnchor.constraint(equalTo: visual.topAnchor),
            root.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            utilityShelf.heightAnchor.constraint(equalToConstant: 33),
            shelfDivider.heightAnchor.constraint(equalToConstant: 1),
            mainBar.heightAnchor.constraint(equalToConstant: 40),
            bufferRail.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            bufferRail.heightAnchor.constraint(equalToConstant: bufferRail.preferredHeight),
        ])
        applyExpandedPresentation()
        applyAppearance()
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     _ symbol: String,
                                     _ toolTip: String,
                                     _ action: Selector) {
        button.image = RimeUI.symbol(symbol, pointSize: 12, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
    }

    private func compactTargetLabel(_ availability: BufferDeliveryCoordinator.Availability) -> String {
        switch availability {
        case let .ready(appName, _):
            return "→ \(appName)"
        case let .blocked(reason):
            switch reason {
            case .noFocusedField: return "未聚焦"
            case .composing: return "组字中"
            case .secureInput: return "安全输入"
            case .nothingPending: return "等待内容"
            case .targetChanged: return "焦点变化"
            case .deliveryRejected: return "发送失败"
            }
        }
    }

    private func applyAppearance() {
        visual.material = RimeUI.isNight ? .hudWindow : .popover
        visual.strokeColor = RimeUI.borderStrong
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        captureButton.contentTintColor = BufferModel.shared.enabled
            ? NSColor.controlAccentColor
            : RimeUI.textMuted
        pinButton.contentTintColor = pinned ? NSColor.controlAccentColor : RimeUI.textSecondary
        privacyButton.contentTintColor = privacyShielded
            ? NSColor.controlAccentColor
            : RimeUI.textSecondary
        [editButton, historyButton, moveButton, closeButton,
         sendButton, clearButton, disclosureButton].forEach {
            $0.contentTintColor = RimeUI.textSecondary
        }
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
                  self.panel.isVisible || BufferBlockEditor.shared.isVisible else { return }
            let current = IsSecureEventInputEnabled()
            guard current != self.lastSecureInputState else { return }
            self.lastSecureInputState = current
            self.refresh()
            RimeBufferController.refreshActiveUI()
        }
        if let secureInputPollTimer {
            RunLoop.main.add(secureInputPollTimer, forMode: .common)
        }
    }

    private func protectForSession(reason: String) {
        BufferBlockEditor.shared.protectAndClose(reason: reason)
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
        let targetHeight = min(BufferWindowGeometry.height(expanded: controlsExpanded),
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

    @objc private func disclosureTapped() {
        controlsExpanded.toggle()
        UserDefaults.standard.set(controlsExpanded, forKey: Key.controlsExpanded)
        applyExpandedPresentation()
        var proposed = panel.frame
        proposed.size.height = BufferWindowGeometry.height(expanded: controlsExpanded)
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
    }

    @objc private func clearTapped() {
        BufferModel.shared.clear()
        selectedBlockID = nil
    }

    @objc private func captureToggled() {
        BufferModel.shared.enabled = captureButton.state == .on
        if BufferModel.shared.enabled { show() }
        RimeBufferController.refreshActiveUI()
    }

    @objc private func pinTapped() { pinned.toggle() }
    @objc private func privacyTapped() {
        privacyShielded.toggle()
        if privacyShielded {
            BufferBlockEditor.shared.protectAndClose(reason: "privacy shield")
        }
        refresh()
        RimeBufferController.refreshActiveUI()
    }
    @objc private func moveTapped() { moveToCurrentScreen() }
    @objc private func closeTapped() { closeAndPause() }

    @objc private func editTapped() {
        guard !privacyShielded,
              !hiddenForSession,
              !IsSecureEventInputEnabled() else { return }
        let model = BufferModel.shared
        let block = selectedBlockID.flatMap { id in model.blocks.first { $0.id == id } }
            ?? model.blocks.last
        guard let block else { return }
        show()
        BufferBlockEditor.shared.show(block: block)
    }

    @objc private func historyTapped() {
        guard !privacyShielded,
              !hiddenForSession,
              !IsSecureEventInputEnabled() else { return }
        let model = BufferModel.shared
        let menu = NSMenu(title: "缓冲历史")
        if model.canUndoClear {
            let undo = NSMenuItem(title: "撤销上次清空", action: #selector(undoClear), keyEquivalent: "")
            undo.target = self
            menu.addItem(undo)
        }
        if model.canUndoClear, !model.sentHistory.isEmpty {
            menu.addItem(.separator())
        }
        for record in model.sentHistory.reversed() {
            let time = historyTimeFormatter.string(from: record.sentAt)
            let item = NSMenuItem(
                title: "恢复 \(time) · \(record.targetName) · \(record.blocks.count) 块 · \(record.characterCount) 字",
                action: #selector(restoreDeliveryRecord(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = record.id.uuidString
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "暂无发送历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: historyButton.bounds.minY - 4),
                   in: historyButton)
    }

    @objc private func restoreDeliveryRecord(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let recordID = UUID(uuidString: raw) else { return }
        _ = BufferModel.shared.restoreDelivery(recordID: recordID)
    }

    @objc private func undoClear() {
        _ = BufferModel.shared.undoLastClear()
    }
}

/// Explicit key-window editor for one block. It is intentionally separate from
/// the passive panel: entering it invalidates the external target, and the IME
/// bypasses buffer capture for this app until editing finishes.
private final class BufferBlockEditor: NSObject, NSWindowDelegate {
    static let shared = BufferBlockEditor()

    private var window: NSWindow?
    private let textView = NSTextView()
    private let detail = NSTextField(labelWithString: "")
    private var blockID: UUID?
    private weak var previousApplication: NSRunningApplication?
    private var closingProgrammatically = false

    var isVisible: Bool { window?.isVisible == true }

    func show(block: BufferModel.Block) {
        if let target = InputFocusCoordinator.shared.owner,
           InputFocusCoordinator.shared.isCurrent(target.token),
           target.compositionActive {
            target.controller?.resolveCompositionForWorkbenchTransition(target: target)
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        blockID = block.id
        buildIfNeeded()
        textView.string = block.text
        detail.stringValue = "来源：\(block.origin.tag) · 保留块边界与创建时间"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func buildIfNeeded() {
        guard window == nil else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered,
                           defer: false)
        win.title = "编辑缓冲块"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 220)
        win.delegate = self

        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [detail, spacer, cancel, save])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor

        let root = NSStackView(views: [scroll, footer])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = NSView()
        win.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        win.center()
        window = win
    }

    @objc private func saveTapped() {
        finalizeTextInput()
        let value = textView.string
        if let blockID {
            _ = BufferModel.shared.updateBlock(id: blockID, text: value)
        }
        closeEditor(finalizeInput: false)
    }

    @objc private func cancelTapped() { closeEditor() }

    /// Closing the whole workbench promises to preserve content. Treat the
    /// editor's current value as an explicit save before hiding, while secure
    /// input keeps the stricter privacy path that never tries to finalize text.
    func saveAndCloseForWorkbenchHide() {
        guard window?.isVisible == true else { return }
        guard !IsSecureEventInputEnabled() else {
            protectAndClose(reason: "secure workbench hide")
            return
        }
        finalizeTextInput()
        let value = textView.string
        if let blockID {
            _ = BufferModel.shared.updateBlock(id: blockID, text: value)
        }
        closeEditor(finalizeInput: false)
    }

    private func finalizeTextInput() {
        if let owner = InputFocusCoordinator.shared.owner,
           !owner.isExternalTarget,
           InputFocusCoordinator.shared.isCurrent(owner.token) {
            owner.controller?.forceCommit()
        }
        textView.unmarkText()
        window?.makeFirstResponder(nil)
    }

    private func closeEditor(finalizeInput: Bool = true) {
        if finalizeInput { finalizeTextInput() }
        closingProgrammatically = true
        window?.orderOut(nil)
        finishEditing()
        closingProgrammatically = false
    }

    /// A privacy transition closes the key editor without saving, restoring the
    /// previous app, or leaving plaintext in its hidden controls. If the editor
    /// owns the current IMK lease, revoke it before unmarking so no late commit
    /// can route back through a stale destination.
    func protectAndClose(reason: String) {
        guard window?.isVisible == true else { return }
        closingProgrammatically = true
        window?.orderOut(nil)

        if let owner = InputFocusCoordinator.shared.owner,
           !owner.isExternalTarget,
           InputFocusCoordinator.shared.isCurrent(owner.token),
           let lease = InputFocusCoordinator.shared.invalidateAll(reason: "editor \(reason)") {
            lease.controller?.finalizeProtectedSession(lease, reason: "editor \(reason)")
            candidateWindow.hide(owner: lease.token)
        }

        textView.unmarkText()
        window?.makeFirstResponder(nil)
        textView.string = ""
        detail.stringValue = ""
        finishEditing(restorePreviousApplication: false, refreshWorkbench: false)
        closingProgrammatically = false
    }

    func windowWillClose(_ notification: Notification) {
        if !closingProgrammatically {
            finalizeTextInput()
            finishEditing()
        }
    }

    private func finishEditing(restorePreviousApplication: Bool = true,
                               refreshWorkbench: Bool = true) {
        blockID = nil
        textView.string = ""
        detail.stringValue = ""
        if refreshWorkbench {
            BufferWindowController.shared.refresh()
        }
        if restorePreviousApplication, let previousApplication {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
            if frontmost?.processIdentifier == ownProcessIdentifier {
                previousApplication.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApplication = nil
    }
}
