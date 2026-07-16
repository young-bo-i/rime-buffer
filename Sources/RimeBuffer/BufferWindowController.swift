import Cocoa
import Carbon.HIToolbox

enum BufferCandidatePlacement: String, CaseIterable {
    case workbench
    case caret

    var title: String {
        switch self {
        case .workbench: return "固定在缓冲窗口"
        case .caret: return "跟随输入光标"
        }
    }
}

/// Pure frame math shared by runtime restoration and the CLI smoke test.
enum BufferWindowGeometry {
    static let standardMinimumWidth: CGFloat = 520
    static let standardMinimumHeight: CGFloat = 340

    static func clampedFrame(_ proposed: NSRect,
                             visibleFrames: [NSRect],
                             fallback: NSRect) -> NSRect {
        let screens = visibleFrames.isEmpty ? [fallback] : visibleFrames
        let target = screens.max { lhs, rhs in
            intersectionArea(proposed, lhs) < intersectionArea(proposed, rhs)
        }.flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil } ?? fallback

        let minimumWidth = min(standardMinimumWidth, target.width)
        let minimumHeight = min(standardMinimumHeight, target.height)
        let width = min(max(proposed.width, minimumWidth), target.width)
        let height = min(max(proposed.height, minimumHeight), target.height)
        var x = proposed.minX
        var y = proposed.minY
        if proposed == .zero || intersectionArea(proposed, target) == 0 {
            x = target.midX - width / 2
            y = target.midY - height / 2
        }
        x = min(max(x, target.minX), max(target.minX, target.maxX - width))
        y = min(max(y, target.minY), max(target.minY, target.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
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

private final class FirstMousePopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BufferDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Stable, nonactivating workbench window. It owns presentation only; all text
/// delivery still flows through BufferDeliveryCoordinator -> Delivery.insert.
final class BufferWindowController: NSObject, NSWindowDelegate {
    static let shared = BufferWindowController()

    private enum Key {
        static let visible = "bufferWindow.visible.v1"
        static let frame = "bufferWindow.frame.v1"
        static let pinned = "bufferWindow.pinned.v1"
        static let placement = "bufferWindow.candidatePlacement.v1"
    }

    private let panel: BufferPanel
    private let visual = NSVisualEffectView()
    private let bufferRail = BufferInlineView()
    private let candidateView = CandidateProjectionView()
    private let previewText = NSTextView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let captureButton = FirstMouseButton(title: "缓冲", target: nil, action: nil)
    private let pinButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let privacyButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let editButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let moveButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let restoreButton = FirstMouseButton(title: "恢复所选记录", target: nil, action: nil)
    private let undoClearButton = FirstMouseButton(title: "撤销清空", target: nil, action: nil)
    private let historyLabel = NSTextField(labelWithString: "")
    private let historyPopUp = FirstMousePopUpButton()
    private var renderedHistoryIDs: [UUID]?
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var selectedBlockID: UUID?
    private var projection: CandidateProjection?
    private var privacyShielded = false
    private var hiddenForSession = false
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var adjustingFrame = false
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

    private override init() {
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered,
                            defer: false)
        super.init()
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
        projection = nil
        candidateView.update(nil)
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
    }

    func setFlushProgress(_ progress: Double?) {
        bufferRail.setFlushProgress(progress)
    }

    func updateCandidateProjection(_ projection: CandidateProjection?) {
        self.projection = projection
        refresh()
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        if let projection,
           InputFocusCoordinator.shared.interactionTarget(expected: projection.owner) == nil {
            self.projection = nil
            candidateView.update(nil)
        }
        captureButton.state = BufferModel.shared.enabled ? .on : .off
        pinButton.contentTintColor = pinned ? NSColor.controlAccentColor : RimeUI.textSecondary

        let availability = BufferDeliveryCoordinator.shared.availability()
        targetLabel.stringValue = availability.label
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
            : "\(model.blocks.count) 块 · \(model.stagedCharacterCount) 字 · 待发送 \(model.pendingDeliveryCount)"
        previewText.string = shouldShield
            ? "内容已隐藏"
            : (model.stagedText.isEmpty ? "暂无缓冲内容" : model.stagedText)
        previewText.textColor = model.stagedText.isEmpty || shouldShield
            ? RimeUI.textMuted
            : RimeUI.textPrimary
        candidateView.update(shouldShield ? nil : projection)
        candidateView.isHidden = shouldShield || projection == nil
        candidateHeightConstraint.constant = shouldShield ? 0 : candidateView.preferredHeight
        _ = bufferRail.refresh(preedit: shouldShield ? "" : (projection?.preedit ?? ""),
                               shielded: shouldShield)
        assert(!shouldShield || (bufferRail.isHidden && candidateView.isHidden),
               "privacy shield must leave every text-bearing rail hidden")

        editButton.isEnabled = !model.blocks.isEmpty && !shouldShield
        refreshHistoryControls(model: model, shielded: shouldShield)
        applyAppearance()
        panel.contentView?.layoutSubtreeIfNeeded()
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
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjustingFrame else { return }
        clampFrameToScreens()
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: BufferWindowGeometry.standardMinimumWidth,
                               height: BufferWindowGeometry.standardMinimumHeight)
        panel.maxSize = NSSize(width: 1100, height: 520)
        panel.delegate = self
        applyCollectionBehavior()

        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10
        visual.layer?.borderWidth = 1
        visual.layer?.masksToBounds = true
        panel.contentView = visual

        let title = NSTextField(labelWithString: "缓冲工作台")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = RimeUI.textMuted

        let drag = BufferDragHandleView()
        let dragLabels = NSStackView(views: [title, countLabel])
        dragLabels.orientation = .vertical
        dragLabels.alignment = .leading
        dragLabels.spacing = 1
        dragLabels.translatesAutoresizingMaskIntoConstraints = false
        drag.addSubview(dragLabels)
        NSLayoutConstraint.activate([
            dragLabels.leadingAnchor.constraint(equalTo: drag.leadingAnchor),
            dragLabels.trailingAnchor.constraint(equalTo: drag.trailingAnchor),
            dragLabels.centerYAnchor.constraint(equalTo: drag.centerYAnchor),
        ])
        drag.setContentHuggingPriority(.defaultLow, for: .horizontal)

        captureButton.setButtonType(.switch)
        captureButton.target = self
        captureButton.action = #selector(captureToggled)
        captureButton.font = .systemFont(ofSize: 11, weight: .medium)
        configureIconButton(pinButton, "pin", "常显于所有桌面与全屏空间", #selector(pinTapped))
        configureIconButton(privacyButton, "eye.slash", "临时隐藏缓冲内容", #selector(privacyTapped))
        configureIconButton(editButton, "pencil", "编辑选中的块", #selector(editTapped))
        configureIconButton(moveButton, "rectangle.on.rectangle", "移到鼠标所在屏幕", #selector(moveTapped))
        configureIconButton(closeButton, "xmark", "关闭并暂停缓冲（保留内容）", #selector(closeTapped))

        let header = NSStackView(views: [drag, targetLabel, captureButton,
                                         pinButton, privacyButton, editButton,
                                         moveButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.heightAnchor.constraint(equalToConstant: 30).isActive = true
        targetLabel.font = .systemFont(ofSize: 10)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        candidateView.onAction = { action, owner in
            candidateWindow.performProjectedAction(action, owner: owner)
        }
        candidateView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        candidateHeightConstraint = candidateView.heightAnchor.constraint(equalToConstant: 0)
        candidateHeightConstraint.priority = .defaultHigh
        candidateHeightConstraint.isActive = true

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.font = .systemFont(ofSize: 14)
        previewText.textContainerInset = NSSize(width: 8, height: 6)
        let previewScroll = NSScrollView()
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.documentView = previewText
        previewScroll.wantsLayer = true
        previewScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewScroll.layer?.cornerRadius = 6
        previewScroll.layer?.borderWidth = 1
        let previewMinimumHeight = previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        previewMinimumHeight.priority = .defaultHigh
        previewMinimumHeight.isActive = true

        bufferRail.onSelectionChange = { [weak self] id in
            self?.selectedBlockID = id
            self?.refresh()
        }
        bufferRail.onClear = { [weak self] in
            BufferModel.shared.clear()
            self?.selectedBlockID = nil
        }

        historyLabel.font = .systemFont(ofSize: 10)
        historyLabel.textColor = RimeUI.textMuted
        historyPopUp.controlSize = .small
        historyPopUp.bezelStyle = .inline
        historyPopUp.toolTip = "选择最近 50 条内存发送记录"
        historyPopUp.translatesAutoresizingMaskIntoConstraints = false
        historyPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        historyPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        let historyMinimumWidth = historyPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        historyMinimumWidth.priority = .defaultHigh
        historyMinimumWidth.isActive = true
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelectedDelivery)
        restoreButton.bezelStyle = .inline
        restoreButton.controlSize = .small
        undoClearButton.target = self
        undoClearButton.action = #selector(undoClear)
        undoClearButton.bezelStyle = .inline
        undoClearButton.controlSize = .small
        let footer = NSStackView(views: [historyLabel, historyPopUp, footerSpacer,
                                         restoreButton, undoClearButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let root = NSStackView(views: [header, candidateView, previewScroll, bufferRail, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        root.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            root.topAnchor.constraint(equalTo: visual.topAnchor),
            root.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            candidateView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            candidateView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bufferRail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bufferRail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        applyAppearance()
    }

    private func refreshHistoryControls(model: BufferModel, shielded: Bool) {
        let records = Array(model.sentHistory.reversed())
        let recordIDs = records.map(\.id)
        if recordIDs != renderedHistoryIDs {
            let selectedID = (historyPopUp.selectedItem?.representedObject as? String)
                .flatMap(UUID.init(uuidString:))
            historyPopUp.removeAllItems()
            for record in records {
                let time = historyTimeFormatter.string(from: record.sentAt)
                historyPopUp.addItem(
                    withTitle: "\(time) · \(record.targetName) · \(record.blocks.count) 块 · \(record.characterCount) 字"
                )
                historyPopUp.lastItem?.representedObject = record.id.uuidString
            }
            if records.isEmpty {
                historyPopUp.addItem(withTitle: "无发送记录")
            } else if let selectedID,
                      let index = recordIDs.firstIndex(of: selectedID) {
                historyPopUp.selectItem(at: index)
            }
            renderedHistoryIDs = recordIDs
        }

        historyLabel.stringValue = shielded
            ? "发送历史已隐藏"
            : "发送历史（内存 \(records.count)/50）"
        historyPopUp.isEnabled = !records.isEmpty && !shielded
        historyPopUp.isHidden = shielded
        restoreButton.isEnabled = !records.isEmpty && !shielded
        restoreButton.isHidden = shielded
        undoClearButton.isEnabled = model.canUndoClear && !shielded
        undoClearButton.isHidden = shielded
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

    private func applyAppearance() {
        visual.material = RimeUI.isNight ? .hudWindow : .popover
        visual.layer?.borderColor = RimeUI.borderStrong.cgColor
        previewText.enclosingScrollView?.layer?.borderColor = RimeUI.border.cgColor
        pinButton.contentTintColor = pinned ? NSColor.controlAccentColor : RimeUI.textSecondary
        privacyButton.contentTintColor = privacyShielded
            ? NSColor.controlAccentColor
            : RimeUI.textSecondary
        [editButton, moveButton, closeButton].forEach {
            $0.contentTintColor = RimeUI.textSecondary
        }
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
    }

    private func restoreFrame() {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let stored = UserDefaults.standard.string(forKey: Key.frame).map(NSRectFromString)
            ?? NSRect(x: fallback.midX - 340, y: fallback.midY - 170, width: 680, height: 340)
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
        let frame = BufferWindowGeometry.clampedFrame(proposed,
                                                      visibleFrames: visibleFrames,
                                                      fallback: fallback)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visibleFrame = visibleFrames.first { $0.contains(center) } ?? fallback
        syncMinimumSize(to: visibleFrame)
        adjustingFrame = true
        panel.setFrame(frame, display: display)
        adjustingFrame = false
    }

    private func syncMinimumSize(to visibleFrame: NSRect) {
        panel.minSize = NSSize(
            width: min(BufferWindowGeometry.standardMinimumWidth, visibleFrame.width),
            height: min(BufferWindowGeometry.standardMinimumHeight, visibleFrame.height)
        )
        panel.maxSize = NSSize(
            width: min(1100, visibleFrame.width),
            height: min(520, visibleFrame.height)
        )
    }

    private var sessionProtectionActive: Bool {
        sessionInactive || screenLocked || sleeping
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Key.frame)
    }

    // MARK: - Actions

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

    @objc private func restoreSelectedDelivery() {
        guard let raw = historyPopUp.selectedItem?.representedObject as? String,
              let recordID = UUID(uuidString: raw) else { return }
        _ = BufferModel.shared.restoreDelivery(recordID: recordID)
    }

    @objc private func undoClear() {
        _ = BufferModel.shared.undoLastClear()
    }
}

private final class CandidateProjectionView: NSView {
    private let preedit = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private var actions: [CandidateProjectionAction] = []
    private var owner: FocusToken?
    var onAction: ((CandidateProjectionAction, FocusToken) -> Void)?
    private(set) var preferredHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 4
        preedit.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preedit.textColor = RimeUI.textSecondary
        let root = NSStackView(views: [preedit, rows])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ projection: CandidateProjection?) {
        actions.removeAll()
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let projection else {
            owner = nil
            preedit.stringValue = ""
            preferredHeight = 0
            isHidden = true
            return
        }
        owner = projection.owner
        preedit.stringValue = projection.preedit
        preedit.isHidden = projection.preedit.isEmpty
        for rowItems in projection.rows.prefix(3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillProportionally
            row.spacing = 4
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for item in rowItems {
                let button = FirstMouseButton(title: "\(item.label) \(item.text)",
                                              target: self,
                                              action: #selector(tapped(_:)))
                button.tag = actions.count
                actions.append(item.action)
                button.isBordered = false
                button.focusRingType = .none
                button.cell?.lineBreakMode = .byTruncatingTail
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.font = .systemFont(ofSize: 13,
                                          weight: item.highlighted ? .semibold : .regular)
                button.contentTintColor = item.highlighted ? RimeUI.candidateBackgroundColor : RimeUI.textPrimary
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                button.layer?.backgroundColor = item.highlighted
                    ? RimeUI.selectedCandidateColor.cgColor
                    : NSColor.clear.cgColor
                button.toolTip = item.comment.isEmpty ? item.text : "\(item.text) · \(item.comment)"
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
        let rowCount = min(3, projection.rows.count)
        preferredHeight = CGFloat(rowCount) * 29
            + CGFloat(max(0, rowCount - 1)) * 4
            + (projection.preedit.isEmpty ? 10 : 31)
        isHidden = false
        layer?.borderColor = RimeUI.border.cgColor
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.withAlphaComponent(0.72).cgColor
    }

    @objc private func tapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag), let owner else { return }
        onAction?(actions[sender.tag], owner)
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
