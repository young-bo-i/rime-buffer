import Cocoa
import InputMethodKit

// One librime instance per process (librime is global); SESSIONS are
// per-controller so composition never bleeds across fields. One shared
// candidate window (only one field composes at a time).
let rimeEngine = RimeEngine()
let candidateWindow = CandidateWindow()

@objc(RimeBufferController)
final class RimeBufferController: IMKInputController {

    /// The controller currently owning focus — menu commands and F4 preference
    /// persistence route through the live session here.
    static var active: RimeBufferController? {
        InputFocusCoordinator.shared.interactionTarget()?.controller
    }
    private static let duplicateBackspaceCommandWindow: CFTimeInterval = 0.05
    private static let duplicateEnterCommandWindow: CFTimeInterval = 0.05
    private static let duplicateArrowCommandWindow: CFTimeInterval = 0.05
    private static let bufferEnterHoldDelay: TimeInterval = 1.2
    private static let bufferEnterPollInterval: TimeInterval = 0.02
    /// Rime pages fetched per matrix batch — also the initial expand size, so
    /// the first ↓ costs the same as before and deeper rows load on demand.
    private static let expandedPageBatch = 3

    private var session: UInt64 = 0
    private var currentSchemaId = ""
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var focusToken: FocusToken?
    private var lastBufferBackspaceKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferBackspaceCommandHandledAt: CFAbsoluteTime = 0
    private var lastBufferEnterKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferEnterCommandHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowCommandHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowKeyDirection = 0
    private var lastBufferArrowCommandDirection = 0
    private var bufferEnterPending = false
    private var bufferEnterSuppressUntilPhysicalUp = false
    /// Physical polling can observe the release before IMK delivers `.keyUp`.
    /// Keep a separate latch so that late keyUp/command events never escape to
    /// the host field after the tap/hold action has already completed.
    private var bufferEnterAwaitingKeyUp = false
    private var bufferEnterClient: IMKTextInput?
    private var bufferEnterOwner: FocusToken?
    private var bufferEnterHardwareKeyCode: CGKeyCode = 36
    private var bufferEnterStartedAt: CFAbsoluteTime = 0
    private var bufferEnterPollTimer: Timer?
    private var candidateOptionSelecting = false
    private var candidateOptionClient: IMKTextInput?
    private let chordClientRoutingGate = ChordClientRoutingGate()
    private let composition = CompositionSession()
    private let chord = ChordController()
    private var chordDurationObserver: NSObjectProtocol?

    private var chordGated: Bool { currentSchemaId == "my_combo" }

    private func shouldUseBufferCommands(client: IMKTextInput?) -> Bool {
        guard BufferModel.shared.active,
              let client,
              let focusToken,
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else { return false }
        return !isOwnClient(client)
    }

    private func shouldCaptureCommit(from client: IMKTextInput,
                                     externalTarget: Bool? = nil) -> Bool {
        BufferModel.shared.enabled
            && (externalTarget ?? !isOwnClient(client))
    }

    private func isOwnClient(_ client: IMKTextInput) -> Bool {
        if let lease = currentLease(matching: client) {
            return !lease.isExternalTarget
        }
        return BufferWindowController.shared.isOwnClient(bundleID: bundleId(of: client))
    }

    private func mirrorDirectTextIfExternal(_ text: String,
                                            client: IMKTextInput,
                                            externalTarget: Bool? = nil) {
        guard externalTarget ?? !isOwnClient(client) else { return }
        RemoteTypingService.shared.send(text)
    }

    @discardableResult
    private func deliverDirectText(_ text: String,
                                   client: IMKTextInput,
                                   externalTarget: Bool? = nil) -> Bool {
        guard Delivery.insert(text, into: client) else {
            composition.clear(client: client)
            return false
        }
        composition.commitDidInsert()
        mirrorDirectTextIfExternal(text,
                                   client: client,
                                   externalTarget: externalTarget)
        return true
    }

    private func currentLease(matching client: IMKTextInput? = nil) -> FocusLease? {
        guard let focusToken,
              let lease = InputFocusCoordinator.shared.lease(for: focusToken),
              lease.controller === self else { return nil }
        if let client,
           ObjectIdentifier(client as AnyObject) != lease.clientIdentity {
            return nil
        }
        return lease
    }

    private func currentCallbackClient(_ sender: Any?) -> IMKTextInput? {
        guard let client = sender as? IMKTextInput,
              let focusToken,
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else { return nil }
        return client
    }

    /// Lifecycle callbacks are less regular than key callbacks: some hosts
    /// pass nil/non-client senders, while others reuse one IMK proxy across
    /// fields and deliver the old field's deactivate late. Resolve only the
    /// current lease. A reused proxy makes lifecycle attribution unsafe for the
    /// whole epoch; delivery stays suspended until an exact ordered event or
    /// activation establishes a new epoch.
    private func lifecycleLease(for sender: Any?, operation: String) -> FocusLease? {
        guard let lease = currentLease(), lease.client != nil else {
            IMELog.write("\(operation): no current focus lease")
            return nil
        }

        let explicitClient = sender as? IMKTextInput
        if let explicitClient,
           ObjectIdentifier(explicitClient as AnyObject) != lease.clientIdentity {
            IMELog.write("\(operation): stale explicit callback ignored")
            return nil
        }
        let implicitClient = self.client()
        let implicitIdentityMatches = implicitClient.map {
            ObjectIdentifier($0 as AnyObject) == lease.clientIdentity
        } ?? false
        guard FocusActivationRules.currentControllerClientMayApply(
            clientExists: implicitClient != nil,
            identityMatches: implicitIdentityMatches
        ) else {
            IMELog.write("\(operation): callback has no matching current controller client")
            suspendUntrustedFocusLease(
                lease,
                reason: "\(operation) current client unavailable or mismatched"
            )
            return nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        let leaseAge = max(0, now - lease.createdAtUptime)
        guard FocusActivationRules.lifecycleCallbackMayApply(
            now: now,
            suppressionUntil: lease.lifecycleSuppressionUntilUptime,
            leaseAge: leaseAge,
            senderIsExplicit: explicitClient != nil,
            clientIdentityWasReused: lease.clientIdentityWasReused
        ) else {
            IMELog.write("\(operation): lifecycle callback suppressed age=\(leaseAge)")
            suspendUntrustedFocusLease(lease,
                                       reason: "\(operation) lifecycle attribution")
            return nil
        }
        return lease
    }

    /// Revoke every client-bound asynchronous path before marking the lease
    /// untrusted. In particular a pending chord timer must resolve in Rime but
    /// must not drain a commit or clear marked text through a moved IMK proxy.
    private func suspendUntrustedFocusLease(_ lease: FocusLease, reason: String) {
        cancelFocusBoundGestures()
        chordClientRoutingGate.withIsolatedClientRouting {
            chord.flush()
        }
        InputFocusCoordinator.shared.suspendDelivery(token: lease.token, reason: reason)
    }

    private func publishCompositionActive(_ active: Bool) {
        guard let focusToken else { return }
        InputFocusCoordinator.shared.setCompositionActive(active, token: focusToken)
    }

    // MARK: Init / teardown

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        chord.onFlush = { [weak self] keys, client in
            self?.replayChordReleases(keys, client: client)
        }
        chord.duration = ChordSettings.duration
        // Settings ▸ 输入 can retune the chord window while this controller is
        // live; pick up the new value immediately instead of only on next focus.
        chordDurationObserver = NotificationCenter.default.addObserver(
            forName: .chordDurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.chord.duration = ChordSettings.duration
        }
        // NOTE: candidateWindow is shared; its onSelect is wired ONCE in
        // main.swift to route through `active` — wiring it here per-controller
        // would leave clicks bound to whichever controller initialized last.
    }

    deinit {
        resetBufferEnterGesture()
        resetCandidateOptionGesture()
        chord.invalidate()
        if let chordDurationObserver {
            NotificationCenter.default.removeObserver(chordDurationObserver)
        }
        if Thread.isMainThread, let focusToken {
            _ = InputFocusCoordinator.shared.deactivate(controller: self, token: focusToken)
            candidateWindow.hide(owner: focusToken)
        }
        if session != 0 { rimeEngine.destroySession(session) }
    }

    // MARK: Server lifecycle (focus in/out per client)

    override func activateServer(_ sender: Any!) {
        // Seed from real hardware state — clearing to [] would desync the
        // flagsChanged delta stream whenever a modifier (esp. Caps Lock) is
        // held or locked across a focus change.
        lastModifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let activeClient: IMKTextInput? = (sender as? IMKTextInput) ?? self.client()
        if let activeClient {
            guard adoptActivationFocus(client: activeClient) else {
                IMELog.write("activate: stale client callback rejected bundle=\(bundleId(of: activeClient))")
                return
            }
            // Match Squirrel's keyboard-layout policy. `last` deliberately
            // leaves the client's physical layout untouched; forcing ABC here
            // perturbs TextInputUI's per-document state (notably in WeChat).
            let keyboard = Self.resolveKeyboardLayoutOverride()
            if let layout = keyboard.layout {
                activeClient.overrideKeyboard(withKeyboardNamed: layout)
            }
            IMELog.write("activate: client=\(bundleId(of: activeClient)) keyboard=\(keyboard.layout ?? "last") source=\(keyboard.source)")
        } else if InputFocusCoordinator.shared.owner != nil {
            IMELog.write("activate: missing current client; suspending global focus lease")
            suspendGlobalFocusLeaseIfPresent(reason: "activate missing client")
        }
        guard rimeEngine.start() else {
            StatusMenu.shared.setHealthy(false)
            IMELog.write("activate: engine down — raw passthrough mode")
            return
        }
        StatusMenu.shared.setHealthy(true)
        ensureSessionReady(applyPreference: true)
        BufferWindowController.shared.refresh()
        MarineBridge.shared.checkForFocusedIntent()
    }

    /// Post-start initialization, shared by activateServer AND the key paths —
    /// an engine that recovers mid-session must still get the configured chord
    /// duration and schema gating before its first processKey.
    @discardableResult
    private func ensureSessionReady(applyPreference: Bool = false) -> Bool {
        guard rimeEngine.isHealthy else { return false }
        var fresh = false
        if session == 0 {
            session = rimeEngine.createSession()
            fresh = session != 0
        }
        guard session != 0 else { return false }

        chord.duration = ChordSettings.duration

        if applyPreference || fresh {
            applyStoredPreferenceIfNeeded()
            // A reused controller may still cache my_combo after another
            // controller changed the global preference to melt_eng. Refresh
            // before the first key so chord gating follows the actual schema.
            refreshSchema()
        } else if currentSchemaId.isEmpty {
            refreshSchema()
        }
        return true
    }

    /// Resolve Squirrel's `keyboard_layout` setting without requiring a
    /// deployed `build/squirrel.yaml`. `last`/missing means no override;
    /// `default` is ABC; an explicit TIS layout id is passed through.
    private static func resolveKeyboardLayoutOverride() -> (layout: String?, source: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let userDirectory = environment["RIMEBUFFER_USER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        let squirrelDirectory = home.appendingPathComponent("Library/Rime", isDirectory: true)
        let candidates = [
            userDirectory.appendingPathComponent("build/squirrel.yaml"),
            userDirectory.appendingPathComponent("squirrel.custom.yaml"),
            userDirectory.appendingPathComponent("squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("build/squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.custom.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.yaml"),
        ]

        var visited: Set<String> = []
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted,
                  let configured = keyboardLayout(in: url) else { continue }
            switch configured {
            case "", "last":
                return (nil, path)
            case "default":
                return ("com.apple.keylayout.ABC", path)
            default:
                return (configured, path)
            }
        }
        return (nil, "fallback:last")
    }

    private static func keyboardLayout(in url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in contents.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(separator: "#", maxSplits: 1,
                                            omittingEmptySubsequences: false).first ?? ""
            let parts = uncommented.split(separator: ":", maxSplits: 1,
                                          omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "keyboard_layout" else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    @discardableResult
    private func adoptActivationFocus(client: IMKTextInput) -> Bool {
        guard currentControllerClientMatches(client) else {
            suspendGlobalFocusLeaseIfPresent(reason: "activation current client mismatch")
            return false
        }
        // NSEvent timestamps and systemUptime share the system-boot clock. A
        // small grace window admits a key already generated during activation
        // while still rejecting older callbacks queued for the prior field.
        let eventFloor = NSApp.currentEvent?.timestamp
            ?? max(0, ProcessInfo.processInfo.systemUptime
                - FocusActivationRules.provisionalConfirmationWindow)
        guard let activation = InputFocusCoordinator.shared.beginActivation(
            controller: self,
            client: client,
            eventFloor: eventFloor
        ) else { return false }
        applyFocusActivation(activation, client: client)
        return true
    }

    @discardableResult
    private func adoptEventFocus(client: IMKTextInput, eventTimestamp: TimeInterval) -> Bool {
        guard currentControllerClientMatches(client) else {
            suspendGlobalFocusLeaseIfPresent(reason: "event current client mismatch")
            return false
        }
        guard let activation = InputFocusCoordinator.shared.noteEvent(
            controller: self,
            client: client,
            eventTimestamp: eventTimestamp
        ) else { return false }
        applyFocusActivation(activation, client: client)
        return true
    }

    private func currentControllerClientMatches(_ proposed: IMKTextInput) -> Bool {
        let implicitClient = self.client()
        return FocusActivationRules.currentControllerClientMayApply(
            clientExists: implicitClient != nil,
            identityMatches: implicitClient.map {
                ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(proposed as AnyObject)
            } ?? false
        )
    }

    private func suspendGlobalFocusLeaseIfPresent(reason: String) {
        guard let lease = InputFocusCoordinator.shared.owner else { return }
        if let ownerController = lease.controller {
            ownerController.suspendUntrustedFocusLease(lease, reason: reason)
        } else {
            InputFocusCoordinator.shared.suspendDelivery(token: lease.token, reason: reason)
        }
    }

    private func applyFocusActivation(_ activation: InputFocusCoordinator.Activation,
                                      client: IMKTextInput) {
        // Resolve the displaced session before exposing the new token. If the
        // same proxy is reused, a pending chord flush can otherwise publish the
        // old session's candidates under the new owner.
        if let displaced = activation.displaced {
            displaced.controller?.finalizeDisplacedFocus(displaced)
        }
        focusToken = activation.token
    }

    /// Resolve a lease that was replaced by a newer focus epoch. Candidate hide
    /// and composition-state writes are owner-checked, so a delayed cleanup can
    /// never erase the new controller's presentation.
    func finalizeDisplacedFocus(_ lease: FocusLease) {
        guard lease.controller === self else { return }
        cancelFocusBoundGestures()
        let replacement = InputFocusCoordinator.shared.owner
        let reusedProxy = replacement?.token != lease.token
            && replacement?.clientIdentity == lease.clientIdentity
        let displacedClient = lease.client
        if reusedProxy || lease.deliverySuspended || displacedClient == nil {
            abandonCompositionWithoutClient(
                lease,
                reason: reusedProxy
                    ? "reused client proxy"
                    : (displacedClient == nil ? "expired client" : "untrusted lifecycle")
            )
        } else {
            resolveComposition(client: displacedClient,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget,
                               isolateChordClientRouting: true)
        }
        if focusToken == lease.token {
            focusToken = nil
        }
    }

    /// Lock, sleep and privacy protection revoke the destination before any
    /// cleanup. Never call the old client from this path: recover the current
    /// Rime result to the enabled buffer, or discard it when capture is off.
    func finalizeProtectedSession(_ lease: FocusLease, reason: String) {
        guard lease.controller === self else { return }
        cancelFocusBoundGestures()
        abandonCompositionWithoutClient(lease, reason: reason)
        if focusToken == lease.token {
            focusToken = nil
        }
    }

    /// Once an application-level IMK proxy has moved to another field, sending
    /// the old session through that proxy would target the new field. Resolve
    /// entirely inside librime instead: preserve the result in the buffer when
    /// capture was enabled, otherwise discard the unconfirmed composition.
    private func abandonCompositionWithoutClient(_ lease: FocusLease, reason: String) {
        guard session != 0 else {
            composition.markCleared()
            candidateWindow.hide(owner: lease.token)
            return
        }

        chordClientRoutingGate.withIsolatedClientRouting {
            chord.flush()
        }
        let rawInput = rimeEngine.getContext(session: session).input
        _ = rimeEngine.commitComposition(session: session)
        let commit = rimeEngine.takeCommit(session: session)
        let recovered = (commit?.isEmpty == false ? commit : nil)
            ?? (rawInput.isEmpty ? nil : rawInput)
        if BufferModel.shared.enabled,
           lease.isExternalTarget,
           let recovered {
            BufferModel.shared.append(recovered)
            IMELog.write("focus \(reason); recovered composition to buffer \(IMELog.redact(recovered))")
        } else if let recovered {
            IMELog.write("focus \(reason); discarded unsafe composition \(IMELog.redact(recovered))")
        }
        rimeEngine.clearComposition(session: session)
        composition.markCleared()
        InputFocusCoordinator.shared.setCompositionActive(false, token: lease.token)
        candidateWindow.hide(owner: lease.token)
        BufferWindowController.shared.refresh()
    }

    override func deactivateServer(_ sender: Any!) {
        guard let lease = lifecycleLease(for: sender, operation: "deactivate"),
              let client = lease.client else {
            return
        }
        cancelFocusBoundGestures()
        if lease.deliverySuspended {
            abandonCompositionWithoutClient(lease, reason: "deactivate after lifecycle suspension")
        } else {
            resolveComposition(client: client,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget)
        }
        _ = InputFocusCoordinator.shared.deactivate(controller: self, token: lease.token)
        if focusToken == lease.token { focusToken = nil }
    }

    override func commitComposition(_ sender: Any!) {
        guard let lease = lifecycleLease(for: sender, operation: "commitComposition"),
              let client = lease.client else {
            return
        }
        if lease.deliverySuspended {
            abandonCompositionWithoutClient(lease, reason: "commit after lifecycle suspension")
        } else {
            resolveComposition(client: client,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget)
        }
    }

    /// Safety net for paths that bypass IMK's callbacks (hostile apps on
    /// Cmd-Tab, status-menu restart, schema switch): resolve any in-flight
    /// chord + composition into the field NOW.
    func forceCommit() {
        guard let lease = currentLease(), let client = lease.client else {
            IMELog.write("forceCommit ignored; no current focus lease")
            return
        }
        guard InputFocusCoordinator.shared.interactionTarget(expected: lease.token) === lease,
              focusToken == lease.token else {
            suspendUntrustedFocusLease(lease, reason: "force commit target validation")
            abandonCompositionWithoutClient(lease, reason: "force commit on untrusted target")
            return
        }
        resolveComposition(client: client,
                           owner: lease.token,
                           externalTarget: lease.isExternalTarget)
    }

    /// Commit-on-blur: flush the chord, commit what Rime holds, close the
    /// marked-text session. Safe to call redundantly.
    private func resolveComposition(client: IMKTextInput?,
                                    owner: FocusToken?,
                                    externalTarget: Bool? = nil,
                                    isolateChordClientRouting: Bool = false) {
        resetCandidateOptionGesture()
        if isolateChordClientRouting {
            chordClientRoutingGate.withIsolatedClientRouting {
                chord.flush()
            }
        } else {
            chord.flush()
        }
        guard session != 0 else { return }
        if let client {
            _ = rimeEngine.commitComposition(session: session)
            drainCommit(client, externalTarget: externalTarget)
            composition.clear(client: client)
        } else {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
        }
        if let owner {
            InputFocusCoordinator.shared.setCompositionActive(false, token: owner)
            candidateWindow.hide(owner: owner)
        }
    }

    /// Called only by BufferDeliveryCoordinator for the exact live lease.
    func resolveCompositionForBufferDelivery(target: FocusLease) {
        guard target.controller === self,
              InputFocusCoordinator.shared.liveTarget(expected: target.token) === target,
              focusToken == target.token else { return }
        resolveComposition(client: target.client,
                           owner: target.token,
                           externalTarget: target.isExternalTarget)
    }

    /// Closing the workbench or opening its editor must also settle a suspended
    /// lease, but an untrusted proxy cannot receive text. Recover into the
    /// buffer when possible and otherwise discard the unresolved session.
    func resolveCompositionForWorkbenchTransition(target: FocusLease) {
        guard target.controller === self,
              InputFocusCoordinator.shared.isCurrent(target.token, controller: self),
              focusToken == target.token else { return }
        guard InputFocusCoordinator.shared.interactionTarget(expected: target.token) === target else {
            suspendUntrustedFocusLease(target, reason: "workbench transition target validation")
            abandonCompositionWithoutClient(target, reason: "workbench transition on untrusted target")
            return
        }
        resolveComposition(client: target.client,
                           owner: target.token,
                           externalTarget: target.isExternalTarget)
    }

    // MARK: Key routing

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        guard adoptEventFocus(client: client, eventTimestamp: event.timestamp) else {
            IMELog.write("handle: stale event rejected bundle=\(bundleId(of: client))")
            return false
        }
        switch event.type {
        case .flagsChanged: return handleFlags(event, client: client)
        case .keyDown:      return handleKeyDown(event, client: client)
        case .keyUp:        return handleKeyUp(event, client: client)
        default:            return false
        }
    }

    private func handleKeyUp(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard let keycode = keysym(for: event) else { return false }
        return handleBufferEnterKeyUp(keycode, client: client)
    }

    private func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
        KeyFrequencyStore.shared.record(keyCode: event.keyCode)

        // Cmd belongs to the app, always (macOS Rime configs never bind Super).
        // In my_combo every letter is a chording key, so without this early-out
        // chord_composer would eat Cmd+C/Cmd+V outright. Resolve any live
        // composition first so the shortcut acts on committed text.
        if event.modifierFlags.contains(.command) {
            if composition.composing || chord.hasPending { forceCommit() }
            return false
        }
        if let shiftedText = shiftedDirectText(for: event) {
            if rimeEngine.start(), ensureSessionReady() {
                return insertDirectText(shiftedText, client: client, source: "shift")
            }
            return insertDirectText(shiftedText, client: client, source: "shift fallback")
        }

        let routedKeycode = keysym(for: event)
        let routedMask = RimeKey.modifierMask(from: event.modifierFlags)
        // Buffer mode owns the complete Return gesture. Intercept it before the
        // engine-health fallback, otherwise a transient engine failure inserts
        // a raw newline into the host field. Preserve the existing behavior
        // where Return first commits any live raw composition into the buffer.
        if routedKeycode == RimeKey.return,
           shouldUseBufferCommands(client: client)
                || bufferEnterPending
                || bufferEnterSuppressUntilPhysicalUp
                || bufferEnterAwaitingKeyUp {
            if shouldUseBufferCommands(client: client),
               routedMask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0,
               rimeEngine.start(), ensureSessionReady(),
               commitRawInput(client: client) {
                return true
            }
            return handleBufferEnter(RimeKey.return,
                                     client: client,
                                     hardwareKeyCode: event.keyCode)
        }
        // Engine down → raw fallback so the user can still type latin.
        guard rimeEngine.start(), ensureSessionReady() else {
            if consumeLeakedCodexBufferControlText(event, client: client, path: "engine down") {
                return true
            }
            return rawFallback(event, client: client)
        }
        guard let keycode = routedKeycode else {
            chord.flush()   // the app will insert this key NOW; a pending chord must land first
            if consumeLeakedCodexBufferControlText(event, client: client, path: "unmapped key") {
                return true
            }
            return false
        }
        let mask = routedMask
        if handleBufferBackspace(keycode, mask: mask, client: client) {
            return true
        }
        if handleBufferEscape(keycode, mask: mask, client: client) {
            return true
        }
        if keycode == RimeKey.return,
           mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0,
           commitRawInput(client: client) {
            return true
        }
        if candidateOptionSelecting {
            if mask == 0 {
                _ = handleCandidateKey(keycode, client: client)
            } else {
                _ = handleCandidateOptionSelectionKey(keycode, client: client)
            }
            return true
        }
        if mask == 0 {
            if handleCandidateKey(keycode, client: client) {
                return true
            }
            if keycode == RimeKey.return, commitRawInput(client: client) {
                return true
            }
        }
        if handleBufferHorizontalArrow(keycode, mask: mask, client: client, source: "key") {
            return true
        }
        let handled = processRimeKey(keycode, mask: mask, client: client)
        if !handled,
           consumeLeakedCodexBufferControlText(event, client: client, path: "Rime unhandled") {
            return true
        }
        return handled
    }

    private func handleBufferEscape(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        guard keycode == RimeKey.escape,
              shouldUseBufferCommands(client: client),
              mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0 else {
            return false
        }

        return exitBufferMode(client: client, source: "escape key")
    }

    private func handleBufferEnter(_ keycode: Int32,
                                   client: IMKTextInput,
                                   hardwareKeyCode: UInt16) -> Bool {
        guard keycode == RimeKey.return else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferEnterCommandHandledAt < Self.duplicateEnterCommandWindow {
            IMELog.write("buffer enter key consumed after command")
            lastBufferEnterKeyHandledAt = now
            return true
        }

        if bufferEnterAwaitingKeyUp,
           !bufferEnterPending,
           !bufferEnterSuppressUntilPhysicalUp {
            // Some IMK clients never deliver keyUp after our physical-release
            // poll. A subsequent keyDown is therefore a fresh press, not a
            // repeat of the completed gesture.
            IMELog.write("buffer enter new keyDown replaced missing late keyUp")
            bufferEnterAwaitingKeyUp = false
        }

        if bufferEnterPending || bufferEnterSuppressUntilPhysicalUp {
            IMELog.write("buffer enter keyDown consumed during active gesture")
            lastBufferEnterKeyHandledAt = now
            return true
        }

        guard shouldUseBufferCommands(client: client) else { return false }
        lastBufferEnterKeyHandledAt = now
        beginBufferEnterGesture(client: client, hardwareKeyCode: hardwareKeyCode)
        return true
    }

    private func handleBufferEnterKeyUp(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard keycode == RimeKey.return else { return false }
        guard bufferEnterPending
                || bufferEnterSuppressUntilPhysicalUp
                || bufferEnterAwaitingKeyUp
                || shouldUseBufferCommands(client: client) else { return false }

        lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
        if bufferEnterPending {
            IMELog.write("buffer enter keyUp tap")
            _ = performBufferEnter(client: bufferEnterClient ?? client, source: "key tap")
            resetBufferEnterGesture()
            return true
        }

        if bufferEnterSuppressUntilPhysicalUp {
            IMELog.write("buffer enter keyUp after hold")
            resetBufferEnterGesture()
            return true
        }

        if bufferEnterAwaitingKeyUp {
            IMELog.write("buffer enter late keyUp consumed after physical release poll")
            resetBufferEnterGesture()
            return true
        }
        IMELog.write("buffer enter keyUp consumed while buffer active")
        return true
    }

    private func handleBufferBackspace(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        guard keycode == RimeKey.backspace,
              shouldUseBufferCommands(client: client),
              mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0 else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferBackspaceCommandHandledAt < Self.duplicateBackspaceCommandWindow {
            IMELog.write("buffer backspace key consumed after command")
            lastBufferBackspaceKeyHandledAt = now
            return true
        }

        lastBufferBackspaceKeyHandledAt = now
        return performBufferBackspace(client: client, source: "key")
    }

    private func handleBufferHorizontalArrow(_ keycode: Int32,
                                             mask: Int32,
                                             client: IMKTextInput,
                                             source: String) -> Bool {
        let direction: Int
        switch keycode {
        case RimeKey.left: direction = -1
        case RimeKey.right: direction = 1
        default: return false
        }
        guard shouldUseBufferCommands(client: client),
              mask & (RimeKey.shiftMask | RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0,
              canMoveBufferInsertionPoint() else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferArrowCommandHandledAt < Self.duplicateArrowCommandWindow,
           lastBufferArrowCommandDirection == direction {
            IMELog.write("buffer arrow \(source) consumed after command direction=\(direction)")
            lastBufferArrowKeyHandledAt = now
            lastBufferArrowKeyDirection = direction
            return true
        }

        lastBufferArrowKeyHandledAt = now
        lastBufferArrowKeyDirection = direction
        _ = BufferModel.shared.moveInsertionPoint(delta: direction)
        updateUI(client: client)
        return true
    }

    override func didCommand(by selector: Selector!, client sender: Any!) -> Bool {
        guard let selector else { return false }
        let callbackClient = currentCallbackClient(sender)
        if sender is IMKTextInput, callbackClient == nil {
            IMELog.write("command rejected; current client mismatch selector=\(NSStringFromSelector(selector))")
            suspendGlobalFocusLeaseIfPresent(reason: "command current client mismatch")
            if let focusToken { candidateWindow.hide(owner: focusToken) }
            return false
        }
        if let keycode = candidateCommandKey(for: selector),
           candidateWindow.hasCandidates {
            guard let client = callbackClient else {
                IMELog.write("candidate command ignored; stale callback selector=\(NSStringFromSelector(selector))")
                return false
            }
            return handleCandidateKey(keycode, client: client)
        }
        if isInsertNewlineSelector(selector) {
            let now = CFAbsoluteTimeGetCurrent()
            if bufferEnterPending
                || bufferEnterSuppressUntilPhysicalUp
                || bufferEnterAwaitingKeyUp
                || now - lastBufferEnterKeyHandledAt < Self.duplicateEnterCommandWindow {
                if bufferEnterAwaitingKeyUp,
                   !bufferEnterPending,
                   !bufferEnterSuppressUntilPhysicalUp {
                    // Command-only clients can omit the physical keyUp forever.
                    // Consume this duplicate command for the completed press,
                    // then let the next command represent a fresh Enter.
                    bufferEnterAwaitingKeyUp = false
                }
                IMELog.write("buffer enter command consumed after key selector=\(NSStringFromSelector(selector))")
                lastBufferEnterCommandHandledAt = now
                return true
            }

            let client = callbackClient
            guard shouldUseBufferCommands(client: client) else { return false }
            lastBufferEnterCommandHandledAt = now
            if let client, commitRawInput(client: client) {
                IMELog.write("buffer enter command committed raw input before flush selector=\(NSStringFromSelector(selector))")
                return true
            }
            return performBufferEnter(client: client, source: "command:\(NSStringFromSelector(selector))")
        }
        if let direction = horizontalMoveDirection(for: selector) {
            let client = callbackClient
            guard shouldUseBufferCommands(client: client) else { return false }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastBufferArrowKeyHandledAt < Self.duplicateArrowCommandWindow,
               lastBufferArrowKeyDirection == direction {
                IMELog.write("buffer arrow command consumed after key selector=\(NSStringFromSelector(selector)) direction=\(direction)")
                lastBufferArrowCommandHandledAt = now
                lastBufferArrowCommandDirection = direction
                return true
            }

            guard canMoveBufferInsertionPoint() else { return false }
            lastBufferArrowCommandHandledAt = now
            lastBufferArrowCommandDirection = direction
            _ = BufferModel.shared.moveInsertionPoint(delta: direction)
            if let client {
                updateUI(client: client)
            } else {
                BufferWindowController.shared.refresh()
            }
            return true
        }
        let commandClient = callbackClient
        guard shouldUseBufferCommands(client: commandClient) else {
            return false
        }
        if isCancelOperationSelector(selector) {
            return exitBufferMode(client: commandClient,
                                  source: "command:\(NSStringFromSelector(selector))")
        }
        guard isDeleteBackwardSelector(selector) else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferBackspaceKeyHandledAt < Self.duplicateBackspaceCommandWindow {
            IMELog.write("buffer backspace command consumed after key selector=\(NSStringFromSelector(selector))")
            lastBufferBackspaceCommandHandledAt = now
            return true
        }

        guard let client = commandClient else { return false }

        lastBufferBackspaceCommandHandledAt = now
        return performBufferBackspace(client: client, source: "command:\(NSStringFromSelector(selector))")
    }

    private func isDeleteBackwardSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))
    }

    private func isCancelOperationSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.cancelOperation(_:))
    }

    private func isInsertNewlineSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(NSResponder.insertParagraphSeparator(_:))
    }

    private func horizontalMoveDirection(for selector: Selector) -> Int? {
        if selector == #selector(NSResponder.moveLeft(_:)) {
            return -1
        }
        if selector == #selector(NSResponder.moveRight(_:)) {
            return 1
        }
        return nil
    }

    private func candidateCommandKey(for selector: Selector) -> Int32? {
        if selector == #selector(NSResponder.moveLeft(_:)) {
            return RimeKey.left
        }
        if selector == #selector(NSResponder.moveRight(_:)) {
            return RimeKey.right
        }
        if selector == #selector(NSResponder.moveUp(_:)) {
            return RimeKey.up
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            return RimeKey.down
        }
        return nil
    }

    private func canMoveBufferInsertionPoint() -> Bool {
        guard !chord.hasPending, !composition.composing else { return false }
        guard session != 0 else { return true }
        let ctx = rimeEngine.getContext(session: session)
        return !ctx.active && ctx.input.isEmpty && ctx.preedit.isEmpty
    }

    private func exitBufferMode(client: IMKTextInput?, source: String) -> Bool {
        resolveComposition(client: client, owner: focusToken)
        BufferModel.shared.pauseCapturePreservingContent()
        BufferWindowController.shared.hideWithoutPausing()
        IMELog.write("buffer mode paused by \(source); content preserved")
        if let client {
            updateUI(client: client)
        } else {
            BufferWindowController.shared.refresh()
        }
        return true
    }

    private func cancelFocusBoundGestures() {
        let mustConsumeLateKeyUp = bufferEnterAwaitingKeyUp
            || bufferEnterPending
            || bufferEnterSuppressUntilPhysicalUp
        resetBufferEnterGesture(preserveKeyUpSuppression: mustConsumeLateKeyUp)
        if mustConsumeLateKeyUp {
            bufferEnterSuppressUntilPhysicalUp = true
            scheduleBufferEnterPoll()
        }
        resetCandidateOptionGesture()
    }

    private func resetBufferEnterGesture(preserveKeyUpSuppression: Bool = false) {
        bufferEnterPending = false
        bufferEnterSuppressUntilPhysicalUp = false
        if !preserveKeyUpSuppression {
            bufferEnterAwaitingKeyUp = false
        }
        bufferEnterClient = nil
        bufferEnterOwner = nil
        bufferEnterPollTimer?.invalidate()
        bufferEnterPollTimer = nil
        candidateWindow.setBufferFlushProgress(nil)
    }

    private func beginBufferEnterGesture(client: IMKTextInput, hardwareKeyCode: UInt16) {
        guard let lease = currentLease(matching: client) else { return }
        bufferEnterPending = true
        bufferEnterSuppressUntilPhysicalUp = false
        bufferEnterAwaitingKeyUp = true
        bufferEnterClient = client
        bufferEnterOwner = lease.token
        bufferEnterHardwareKeyCode = CGKeyCode(hardwareKeyCode)
        bufferEnterStartedAt = CFAbsoluteTimeGetCurrent()
        candidateWindow.setBufferFlushProgress(0)
        IMELog.write("buffer enter pending; polling physical key state keyCode=\(hardwareKeyCode)")
        scheduleBufferEnterPoll()
    }

    private func scheduleBufferEnterPoll() {
        bufferEnterPollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.bufferEnterPollInterval, repeats: false) { [weak self] _ in
            self?.pollBufferEnterGesture()
        }
        bufferEnterPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollBufferEnterGesture() {
        if bufferEnterSuppressUntilPhysicalUp, bufferEnterOwner == nil {
            if isBufferEnterPhysicallyDown() {
                scheduleBufferEnterPoll()
            } else {
                IMELog.write("buffer enter old-focus key released")
                resetBufferEnterGesture(preserveKeyUpSuppression: true)
            }
            return
        }
        guard let bufferEnterOwner,
              focusToken == bufferEnterOwner,
              InputFocusCoordinator.shared.isCurrent(bufferEnterOwner, controller: self) else {
            resetBufferEnterGesture(preserveKeyUpSuppression: bufferEnterAwaitingKeyUp)
            return
        }
        if bufferEnterSuppressUntilPhysicalUp {
            if isBufferEnterPhysicallyDown() {
                scheduleBufferEnterPoll()
            } else {
                IMELog.write("buffer enter physical key released after hold")
                resetBufferEnterGesture(preserveKeyUpSuppression: true)
            }
            return
        }

        guard bufferEnterPending else { return }
        guard shouldUseBufferCommands(client: bufferEnterClient) else {
            resetBufferEnterGesture()
            return
        }

        if !isBufferEnterPhysicallyDown() {
            IMELog.write("buffer enter physical release detected; tap")
            lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
            _ = performBufferEnter(client: bufferEnterClient, source: "key tap")
            resetBufferEnterGesture(preserveKeyUpSuppression: true)
            return
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - bufferEnterStartedAt
        let progress = min(max(elapsed / Self.bufferEnterHoldDelay, 0), 1)
        candidateWindow.setBufferFlushProgress(progress)
        if elapsed >= Self.bufferEnterHoldDelay {
            IMELog.write("buffer enter hold reached \(Self.bufferEnterHoldDelay)s; send all")
            lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
            bufferEnterPending = false
            bufferEnterSuppressUntilPhysicalUp = true
            candidateWindow.setBufferFlushProgress(1)
            _ = performBufferEnterAll(client: bufferEnterClient, source: "key hold")
            scheduleBufferEnterPoll()
            return
        }

        scheduleBufferEnterPoll()
    }

    private func isBufferEnterPhysicallyDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: bufferEnterHardwareKeyCode)
    }

    @discardableResult
    private func beginCandidateOptionSelection(client: IMKTextInput) -> Bool {
        if candidateOptionSelecting { return true }
        if chord.hasPending {
            IMELog.write("candidate option resolving pending chord before local action")
            chord.flush()
        }
        guard candidateWindow.hasCandidates,
              let candidateText = candidateWindow.selectedCandidateText,
              candidateWindow.beginSingleCharacterSelection(candidateText: candidateText) else {
            return false
        }
        candidateOptionSelecting = true
        candidateOptionClient = client
        IMELog.write("candidate option selection started text=\(IMELog.redact(candidateText))")
        return true
    }

    private func resetCandidateOptionGesture() {
        candidateOptionSelecting = false
        candidateOptionClient = nil
        candidateWindow.cancelSingleCharacterSelection()
    }

    private func finishCandidateOptionSelection(client: IMKTextInput?, source: String) {
        guard candidateOptionSelecting else { return }
        let proposedClient = client ?? candidateOptionClient
        let resolvedClient = proposedClient.flatMap {
            currentCallbackClient($0)
        }
        guard resolvedClient != nil else {
            IMELog.write("candidate option release ignored; focus changed")
            resetCandidateOptionGesture()
            return
        }
        IMELog.write("candidate option released by \(source); commit selected character")
        _ = commitSelectedSingleCharacter(client: resolvedClient, source: source)
        resetCandidateOptionGesture()
    }

    private func handleCandidateOptionSelectionKey(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard candidateOptionSelecting || candidateWindow.isSingleCharacterSelectionActive else { return false }
        switch keycode {
        case RimeKey.left:
            return candidateWindow.moveSingleCharacterSelection(delta: -1)
        case RimeKey.right:
            return candidateWindow.moveSingleCharacterSelection(delta: 1)
        case RimeKey.space, RimeKey.return:
            finishCandidateOptionSelection(client: client, source: "candidate key")
            return true
        case RimeKey.escape:
            resetCandidateOptionGesture()
            return true
        default:
            return true
        }
    }

    @discardableResult
    private func commitCandidateSpaceTap(client: IMKTextInput?, source: String) -> Bool {
        let resolvedClient = client.flatMap {
            currentCallbackClient($0)
        }
        guard let resolvedClient else {
            IMELog.write("candidate space ignored; focus changed")
            return true
        }
        guard let selection = candidateWindow.selectedCandidateSelection else {
            return processRimeKey(RimeKey.space, mask: 0, client: resolvedClient)
        }
        IMELog.write("candidate space \(source); commit pageOffset=\(selection.pageOffset) index=\(selection.index)")
        selectCandidate(selection)
        return true
    }

    @discardableResult
    private func commitSelectedSingleCharacter(client: IMKTextInput?, source: String) -> Bool {
        let resolvedClient = client.flatMap {
            currentCallbackClient($0)
        }
        guard let resolvedClient else {
            IMELog.write("candidate single-character ignored; focus changed")
            return true
        }
        guard let text = candidateWindow.selectedSingleCharacterText, !text.isEmpty else {
            return commitCandidateSpaceTap(client: resolvedClient, source: "\(source) fallback")
        }

        if session != 0 {
            rimeEngine.clearComposition(session: session)
        }

        if shouldCaptureCommit(from: resolvedClient) {
            BufferModel.shared.append(text)
            composition.clear(client: resolvedClient)
            IMELog.write("candidate single-character \(IMELog.redact(text)) -> buffer by \(source) (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(text, client: resolvedClient)
            IMELog.write("candidate single-character \(IMELog.redact(text)) inserted=\(inserted) target=\(bundleId(of: resolvedClient)) by \(source)")
        }

        if let focusToken {
            InputFocusCoordinator.shared.setCompositionActive(false, token: focusToken)
        }
        updateUI(client: resolvedClient)
        return true
    }

    private func performBufferEnter(client: IMKTextInput?, source: String) -> Bool {
        guard let resolvedClient = client,
              currentCallbackClient(resolvedClient) != nil else {
            IMELog.write("buffer enter \(source) ignored; focus changed")
            return true
        }

        if rimeEngine.start(),
           ensureSessionReady(),
           session != 0 {
            let ctx = rimeEngine.getContext(session: session)
            if chord.hasPending || composition.composing || ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                resolveComposition(client: resolvedClient, owner: focusToken)
            }
        } else if session != 0 {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
        }

        publishCompositionActive(false)
        let originalPending = BufferModel.shared.pendingDeliveryCount
        let result = BufferDeliveryCoordinator.shared.sendNext(resolveCompositionIfNeeded: false)
        IMELog.write("buffer enter \(source) consumed; send next=\(result.sentCount) pending=\(originalPending)->\(BufferModel.shared.pendingDeliveryCount) active=\(BufferModel.shared.active)")

        updateUI(client: resolvedClient)
        return true
    }

    private func performBufferEnterAll(client: IMKTextInput?, source: String) -> Bool {
        guard let resolvedClient = client,
              currentCallbackClient(resolvedClient) != nil else {
            IMELog.write("buffer enter all \(source) ignored; focus changed")
            return true
        }

        if rimeEngine.start(),
           ensureSessionReady(),
           session != 0 {
            let ctx = rimeEngine.getContext(session: session)
            if chord.hasPending || composition.composing || ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                resolveComposition(client: resolvedClient, owner: focusToken)
            }
        } else if session != 0 {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
        }

        publishCompositionActive(false)
        let originalPending = BufferModel.shared.pendingDeliveryCount
        let result = BufferDeliveryCoordinator.shared.sendAll(resolveCompositionIfNeeded: false)
        IMELog.write("buffer enter \(source) consumed; send all=\(result.sentCount) pending=\(originalPending)->\(BufferModel.shared.pendingDeliveryCount) active=\(BufferModel.shared.active)")

        updateUI(client: resolvedClient)
        return true
    }

    private func performBufferBackspace(client: IMKTextInput, source: String) -> Bool {
        guard rimeEngine.start(), ensureSessionReady(), session != 0 else {
            if !BufferModel.shared.removeLastBlock() {
                IMELog.write("buffer backspace \(source) consumed; engine unavailable/no blocks")
            }
            publishCompositionActive(false)
            BufferWindowController.shared.refresh()
            return true
        }

        if chord.hasPending || composition.composing {
            _ = processRimeKey(RimeKey.backspace, mask: 0, client: client)
            return true
        }

        let ctx = rimeEngine.getContext(session: session)
        if ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
            _ = processRimeKey(RimeKey.backspace, mask: 0, client: client)
            return true
        }

        if !BufferModel.shared.removeLastBlock() {
            IMELog.write("buffer backspace \(source) consumed; no blocks")
        }
        publishCompositionActive(false)
        updateUI(client: client)
        return true
    }

    private func shiftedDirectText(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              flags.intersection([.control, .option, .command]).isEmpty,
              let text = event.characters,
              !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return nil
        }
        return text
    }

    private func insertDirectText(_ text: String, client: IMKTextInput, source: String) -> Bool {
        if rimeEngine.isHealthy, session != 0 {
            let ctx = rimeEngine.getContext(session: session)
            if chord.hasPending || composition.composing || ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                resolveComposition(client: client, owner: focusToken)
            }
        }

        if shouldCaptureCommit(from: client) {
            BufferModel.shared.append(text)
            composition.clear(client: client)
            IMELog.write("\(source) text \(IMELog.redact(text)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(text, client: client)
            IMELog.write("\(source) text \(IMELog.redact(text)) inserted=\(inserted) target=\(bundleId(of: client))")
        }
        publishCompositionActive(false)
        BufferWindowController.shared.refresh()
        if session != 0 {
            updateUI(client: client)
        } else if let focusToken {
            candidateWindow.hide(owner: focusToken)
        }
        return true
    }

    /// keyDown → Rime keysym: letters/punct/F-keys via the virtual-key table,
    /// then editing/navigation keys, then any typed ASCII character.
    private func keysym(for event: NSEvent) -> Int32? {
        if let k = RimeKey.fromVirtualKeyCode(event.keyCode) { return k }
        switch event.keyCode {
        case 36, 76: return RimeKey.return
        case 48:     return RimeKey.tab
        case 49:     return RimeKey.space
        case 50:
            // grave/backtick. Ctrl+grave & Ctrl+Shift+grave are the user's
            // switcher hotkeys (Rime matches keysym `grave`); a plain Shift+`
            // must stay asciitilde so ～ punctuation keeps working.
            if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.control) {
                return 0x7e
            }
            return 0x60
        case 51:     return RimeKey.backspace
        case 53:     return RimeKey.escape
        case 117:    return RimeKey.deleteForward
        case 115:    return RimeKey.home
        case 119:    return RimeKey.end
        case 116:    return RimeKey.pageUp
        case 121:    return RimeKey.pageDown
        case 123:    return RimeKey.left
        case 124:    return RimeKey.right
        case 125:    return RimeKey.down
        case 126:    return RimeKey.up
        default:
            if let scalar = event.characters?.unicodeScalars.first {
                return RimeKey.fromScalar(scalar)
            }
            return nil
        }
    }

    /// Single unified path for every key. Modifier-held keys are fed to Rime
    /// FIRST (the user's config binds e.g. Control+Shift+3 → ascii_punct);
    /// unhandled ones fall through to the app (Cmd-C etc. keep working).
    private func processRimeKey(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        let isPress = mask & RimeKey.releaseMask == 0
        // A chord key is a PLAIN press of a chording letter — anything carrying
        // Ctrl/Opt/Cmd is a shortcut/binding, never chord material.
        let isChordKey = chordGated && isPress && RimeKey.isChordingKey(keycode)
            && mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0
        // Prototype semantics: a PRESS of a non-chord key resolves the pending
        // chord before processing; release events never pre-flush.
        if isPress, !isChordKey { chord.flush() }

        let t0 = CFAbsoluteTimeGetCurrent()
        let handled = rimeEngine.processKey(keycode, mask: mask, session: session)
        watchdog("processKey k=\(keycode) m=\(mask)", since: t0)

        if handled {
            if isChordKey {
                chord.noteHandledChordKey(keycode, mask: mask, client: client)
            } else {
                chord.flush()   // prototype flushed after any handled non-chord event
            }
        }
        drainCommit(client)
        updateUI(client: client)
        return handled
    }

    private func handleFlags(_ event: NSEvent, client: IMKTextInput) -> Bool {
        let modifiers = event.modifierFlags
        let changes = lastModifiers.symmetricDifference(modifiers)
        if !changes.isEmpty {
            KeyFrequencyStore.shared.recordModifierPress(keyCode: event.keyCode, flags: modifiers)
        }

        guard rimeEngine.start(), ensureSessionReady() else {
            lastModifiers = event.modifierFlags
            return false
        }
        guard !changes.isEmpty else {
            lastModifiers = modifiers
            return false
        }

        if changes.contains(.option) {
            if modifiers.contains(.option) {
                if beginCandidateOptionSelection(client: client) {
                    lastModifiers = modifiers
                    return true
                }
            } else if candidateOptionSelecting {
                finishCandidateOptionSelection(client: client, source: "option release")
                lastModifiers = modifiers
                return true
            }
        }
        if candidateOptionSelecting {
            lastModifiers = modifiers
            return true
        }

        var keyCode = event.keyCode
        if RimeKey.fromVirtualKeyCode(keyCode) == nil,
           let inferred = RimeKey.changedModifierKeyCode(from: changes) {
            keyCode = inferred
        }
        guard let keycode = RimeKey.fromVirtualKeyCode(keyCode) else {
            lastModifiers = modifiers
            return false
        }

        // Byte-identical to the proven prototype: press/release stream with
        // Caps sent as mask^lockMask (ascii_composer switch keys — Shift_L:
        // commit_code, good_old_caps_lock — depend on this exact ordering).
        let rimeMask = RimeKey.modifierMask(from: modifiers)
        var handled = false
        if changes.contains(.capsLock) {
            handled = processRimeKey(keycode, mask: rimeMask ^ RimeKey.lockMask, client: client) || handled
        } else {
            let watched: [NSEvent.ModifierFlags] = [.shift, .control, .option, .command]
            for flag in watched where changes.contains(flag) {
                let pressed = modifiers.contains(flag)
                let mask = pressed ? rimeMask : (rimeMask | RimeKey.releaseMask)
                handled = processRimeKey(keycode, mask: mask, client: client) || handled
            }
        }
        lastModifiers = modifiers
        return handled
    }

    /// Engine-down path: printable keys and Return still insert (never drop a
    /// printable character); non-textual keys pass to the app.
    private func rawFallback(_ event: NSEvent, client: IMKTextInput) -> Bool {
        StatusMenu.shared.setHealthy(false)
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .control]).isEmpty {
            return insertDirectText("\n", client: client, source: "engine fallback")
        }
        if let chars = event.characters, !chars.isEmpty,
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            return insertDirectText(chars, client: client, source: "engine fallback")
        }
        return false
    }

    /// Codex currently inserts U+001E/U+001F when their Control-key events are
    /// returned unhandled. In buffer mode those bytes are never buffer content
    /// and must not leak into the editor. Keep this host-specific so terminal
    /// Control+^ / Control+_ semantics remain untouched.
    private func consumeLeakedCodexBufferControlText(
        _ event: NSEvent,
        client: IMKTextInput,
        path: String
    ) -> Bool {
        guard let characters = event.characters,
              !characters.isEmpty else { return false }
        let scalars = characters.unicodeScalars.map(\.value)
        guard Self.shouldConsumeCodexBufferControlText(
            scalars,
            bundleId: bundleId(of: client),
            bufferActive: shouldUseBufferCommands(client: client)
        ) else { return false }

        let renderedScalars = scalars
            .map { String(format: "U+%04X", $0) }
            .joined(separator: ",")
        let ignoringModifiers = event.charactersIgnoringModifiers?.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: ",") ?? ""
        IMELog.write("buffer swallowed Codex control text path=\(path) keyCode=\(event.keyCode) scalars=\(renderedScalars) ignoring=\(ignoringModifiers) flags=\(event.modifierFlags.rawValue)")
        return true
    }

    static func shouldConsumeCodexBufferControlText(
        _ scalars: [UInt32],
        bundleId: String,
        bufferActive: Bool
    ) -> Bool {
        bufferActive
            && bundleId == "com.openai.codex"
            && !scalars.isEmpty
            && scalars.allSatisfy { $0 == 0x1e || $0 == 0x1f }
    }

    // MARK: Chord replay

    private func replayChordReleases(_ keys: [(keycode: Int32, mask: Int32)],
                                     client: (any IMKTextInput)?) {
        guard session != 0 else { return }
        var handledCount = 0
        for key in keys {
            if rimeEngine.processKey(key.keycode,
                                     mask: key.mask | RimeKey.releaseMask,
                                     session: session) {
                handledCount += 1
            }
        }
        if !chordClientRoutingGate.allowsClientRouting {
            IMELog.write("chord replay isolated from reused client proxy keys=\(keys.count) handled=\(handledCount)")
            return
        }
        guard let client,
              let focusToken,
              let target = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              target.controller === self,
              target.clientIdentity == ObjectIdentifier(client as AnyObject) else {
            IMELog.write("chord replay blocked; current client no longer matches pending chord")
            if let lease = currentLease() {
                suspendUntrustedFocusLease(lease, reason: "asynchronous chord target validation")
                abandonCompositionWithoutClient(lease,
                                                reason: "asynchronous chord target changed")
            } else {
                rimeEngine.clearComposition(session: session)
                composition.markCleared()
            }
            return
        }
        // Match Squirrel's batch boundary: all synthesized releases must reach
        // chord_composer before the resulting commit is observed by the buffer.
        drainCommit(client, externalTarget: target.isExternalTarget)
        updateUI(client: client)
        if keys.count > 1 {
            IMELog.write("chord replay keys=\(keys.count) handled=\(handledCount) duration=\(chord.duration)")
        }
    }

    // MARK: Candidate selection (mouse; routed here via `active` from main.swift)

    private func handleCandidateKey(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard candidateWindow.hasCandidates else { return false }
        if candidateOptionSelecting || candidateWindow.isSingleCharacterSelectionActive {
            return handleCandidateOptionSelectionKey(keycode, client: client)
        }
        let isLocalCandidateAction: Bool
        switch keycode {
        case RimeKey.left, RimeKey.right, RimeKey.down, RimeKey.up,
             RimeKey.return, RimeKey.space, 0x30:
            isLocalCandidateAction = true
        case 0x31...0x39:
            isLocalCandidateAction = candidateWindow.isExpanded
        default:
            isLocalCandidateAction = false
        }
        if isLocalCandidateAction, chord.hasPending {
            IMELog.write("candidate key \(keycode) resolving pending chord before local action")
            chord.flush()
            guard candidateWindow.hasCandidates else { return false }
        }
        switch keycode {
        case RimeKey.left:
            return candidateWindow.moveSelection(delta: -1)
        case RimeKey.right:
            return candidateWindow.moveSelection(delta: 1)
        case RimeKey.down:
            if candidateWindow.isExpanded {
                extendExpandedPagesIfNeeded()
                return candidateWindow.moveExpandedSelection(rowDelta: 1)
            }
            let pages = previewCandidatePages(maxCount: Self.expandedPageBatch)
            if pages.count > 1 {
                IMELog.write("candidate matrix expanded rows=\(pages.count)")
                return candidateWindow.expand(with: pages)
            }
            return pageCandidates(delta: 1, client: client)
        case RimeKey.up:
            if candidateWindow.isExpanded {
                return candidateWindow.moveExpandedSelection(rowDelta: -1)
            }
            return pageCandidates(delta: -1, client: client)
        case RimeKey.return:
            return commitRawInput(client: client)
        case RimeKey.space:
            guard let selection = candidateWindow.selectedCandidateSelection else { return false }
            selectCandidate(selection)
            return true
        case 0x30:
            guard !BufferModel.shared.active else { return true }
            let selection = candidateWindow.selectedCandidateSelection
            let candidateText = candidateWindow.selectedCandidateText ?? ""
            let originalBlockCount = BufferModel.shared.blocks.count
            IMELog.write("buffer zero begin text=\(IMELog.redact(candidateText)) pageOffset=\(selection?.pageOffset ?? -1) index=\(selection?.index ?? -1)")
            candidateWindow.performBufferAction()
            guard let selection else {
                IMELog.write("buffer zero enabled without candidate selection")
                return true
            }
            let selected = selectCandidate(selection)
            let finalBlockCount = BufferModel.shared.blocks.count
            if selected, finalBlockCount > originalBlockCount {
                IMELog.write("buffer zero committed text=\(IMELog.redact(candidateText)) blocks=\(originalBlockCount)->\(finalBlockCount)")
            } else if selected {
                IMELog.write("buffer zero selected but no commit text=\(IMELog.redact(candidateText))")
            } else {
                IMELog.write("buffer zero failed text=\(IMELog.redact(candidateText)) buffer remains enabled")
            }
            return true
        case 0x31...0x39 where candidateWindow.isExpanded:
            let visibleIndex = Int(keycode - 0x31)
            guard let selection = candidateWindow.expandedSelection(atVisibleIndex: visibleIndex) else {
                IMELog.write("candidate matrix digit \(visibleIndex + 1) ignored; candidate is hidden")
                return true
            }
            selectCandidate(selection)
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func pageCandidates(delta: Int, client: IMKTextInput) -> Bool {
        guard candidateWindow.hasCandidates else { return false }
        if candidateWindow.movePage(delta: delta) { return true }
        let keycode = delta < 0 ? RimeKey.pageUp : RimeKey.pageDown
        _ = processRimeKey(keycode, mask: 0, client: client)
        return true
    }

    @discardableResult
    func selectCandidate(_ selection: CandidateSelection) -> Bool {
        guard let focusToken else {
            IMELog.write("candidate select failed stage=no-focus-token")
            return false
        }
        return selectCandidate(selection, owner: focusToken)
    }

    @discardableResult
    func selectCandidate(_ selection: CandidateSelection, owner: FocusToken) -> Bool {
        guard session != 0,
              focusToken == owner,
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: owner),
              lease.controller === self,
              let client = lease.client else {
            IMELog.write("candidate select failed stage=session-or-owner pageOffset=\(selection.pageOffset) index=\(selection.index)")
            return false
        }
        let moved = moveRimeCandidatePage(delta: selection.pageOffset)
        guard moved == selection.pageOffset else {
            _ = moveRimeCandidatePage(delta: -moved)
            updateUI(client: client)
            IMELog.write("candidate select failed stage=page-move requested=\(selection.pageOffset) moved=\(moved)")
            return false
        }
        guard rimeEngine.selectCandidate(onPage: selection.index, session: session) else {
            _ = moveRimeCandidatePage(delta: -moved)
            updateUI(client: client)
            IMELog.write("candidate select failed stage=select pageOffset=\(selection.pageOffset) index=\(selection.index)")
            return false
        }
        if drainCommit(client) == nil {
            IMELog.write("candidate selected without commit pageOffset=\(selection.pageOffset) index=\(selection.index)")
        }
        updateUI(client: client)
        return true
    }

    /// The matrix shows three rows but must reach every candidate, so pull the
    /// next batch of Rime pages once the selection lands on the fetched tail.
    /// Pages are re-read from the anchor (cheap: the session never leaves page
    /// 0), which keeps `expandedPages` index == anchor-relative page offset.
    private func extendExpandedPagesIfNeeded() {
        guard candidateWindow.isExpanded,
              !candidateWindow.expandedTailIsLastPage else { return }
        let loaded = candidateWindow.expandedPageCount
        guard candidateWindow.expandedSelectionPage >= loaded - 1 else { return }
        let pages = previewCandidatePages(maxCount: loaded + Self.expandedPageBatch)
        candidateWindow.extendExpandedPages(with: pages)
    }

    private func previewCandidatePages(maxCount: Int) -> [RimeContextModel] {
        guard session != 0, maxCount > 0 else { return [] }
        let current = rimeEngine.getContext(session: session)
        guard !current.candidates.isEmpty else { return [] }

        var pages = [current]
        var moved = 0
        var last = current
        while pages.count < maxCount, !last.isLastPage {
            let before = rimeEngine.getContext(session: session)
            guard rimeEngine.processKey(RimeKey.pageDown, mask: 0, session: session) else { break }
            let next = rimeEngine.getContext(session: session)
            guard !sameCandidatePage(before, next) else { break }
            moved += 1
            guard !next.candidates.isEmpty else { break }
            pages.append(next)
            last = next
        }
        if moved > 0 {
            _ = moveRimeCandidatePage(delta: -moved)
        }
        return pages
    }

    @discardableResult
    private func moveRimeCandidatePage(delta: Int) -> Int {
        guard session != 0, delta != 0 else { return 0 }
        let direction = delta > 0 ? 1 : -1
        let keycode = direction > 0 ? RimeKey.pageDown : RimeKey.pageUp
        var moved = 0
        for _ in 0..<abs(delta) {
            let before = rimeEngine.getContext(session: session)
            guard rimeEngine.processKey(keycode, mask: 0, session: session) else { break }
            let after = rimeEngine.getContext(session: session)
            guard !sameCandidatePage(before, after) else { break }
            moved += direction
        }
        return moved
    }

    private func sameCandidatePage(_ lhs: RimeContextModel, _ rhs: RimeContextModel) -> Bool {
        lhs.pageNo == rhs.pageNo && candidatePageSignature(lhs) == candidatePageSignature(rhs)
    }

    private func candidatePageSignature(_ ctx: RimeContextModel) -> String {
        ctx.candidates.map { "\($0.label):\($0.text):\($0.comment)" }.joined(separator: "|")
    }

    private func commitRawInput(client: IMKTextInput) -> Bool {
        guard session != 0 else { return false }

        var ctx = rimeEngine.getContext(session: session)
        var raw = ctx.input
        if raw.isEmpty, candidateWindow.isVisible {
            raw = candidateWindow.rawInputForCommit
        }
        if chord.hasPending {
            chord.flush()
            ctx = rimeEngine.getContext(session: session)
            raw = ctx.input
            if raw.isEmpty, candidateWindow.isVisible {
                raw = candidateWindow.rawInputForCommit
            }
        }
        guard !raw.isEmpty else { return false }

        rimeEngine.clearComposition(session: session)
        if shouldCaptureCommit(from: client) {
            BufferModel.shared.append(raw)
            composition.clear(client: client)
            IMELog.write("raw input \(IMELog.redact(raw)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(raw, client: client)
            IMELog.write("raw input \(IMELog.redact(raw)) inserted=\(inserted) target=\(bundleId(of: client))")
        }
        publishCompositionActive(false)
        updateUI(client: client)
        return true
    }

    // MARK: Commit drain + UI

    /// The single routing point (§5.9): buffer-OFF → straight to the field;
    /// buffer-ON → the commit becomes a staged block and the inline preedit is
    /// cleared from the field (nothing lands until the buffer flushes).
    @discardableResult
    private func drainCommit(_ client: IMKTextInput,
                             externalTarget: Bool? = nil) -> String? {
        guard let commit = rimeEngine.takeCommit(session: session) else { return nil }
        if shouldCaptureCommit(from: client, externalTarget: externalTarget) {
            BufferModel.shared.append(commit)
            composition.clear(client: client)
            IMELog.write("commit \(IMELog.redact(commit)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(commit,
                                             client: client,
                                             externalTarget: externalTarget)
            IMELog.write("commit \(IMELog.redact(commit)) inserted=\(inserted) target=\(bundleId(of: client))")
        }
        return commit
    }

    /// Token-aware destination used only by BufferDeliveryCoordinator.
    func deliverBufferedBlock(_ text: String, origin: Origin, target: FocusLease) -> Bool {
        guard target.controller === self,
              focusToken == target.token,
              InputFocusCoordinator.shared.liveTarget(expected: target.token) === target,
              let client = target.client,
              ObjectIdentifier(client as AnyObject) == target.clientIdentity else {
            IMELog.write("buffer send blocked; stale target token=\(target.token)")
            return false
        }
        guard Delivery.insert(text, into: client) else {
            return false
        }
        composition.commitDidInsert()
        // Echo guard: a block that arrived FROM a paired Mac is never mirrored
        // back, or the two Macs bounce it forever. Everything else mirrors.
        if origin.allowsRemoteMirror {
            RemoteTypingService.shared.send(text)   // no-op if remote typing off
        }
        return true
    }

    /// Insert text RECEIVED from a paired Mac into the currently focused field.
    /// Returns false when there's no live client to insert into (caller falls
    /// back to the clipboard). Goes straight through Delivery.insert so received
    /// text is never re-broadcast back to the sender (no echo loop). Main thread.
    static func insertRemoteText(_ text: String) -> Bool {
        guard let target = InputFocusCoordinator.shared.liveTarget(),
              !target.compositionActive,
              let controller = target.controller else {
            return false
        }
        return controller.deliverRemoteText(text, target: target)
    }

    /// Token-aware remote insert. Remote text is never allowed to replace an
    /// active marked-text session; the caller falls back to the clipboard.
    private func deliverRemoteText(_ text: String, target: FocusLease) -> Bool {
        guard target.controller === self,
              focusToken == target.token,
              !target.compositionActive,
              InputFocusCoordinator.shared.liveTarget(expected: target.token) === target,
              let client = target.client,
              ObjectIdentifier(client as AnyObject) == target.clientIdentity,
              Delivery.insert(text, into: client) else { return false }
        composition.commitDidInsert()
        return true
    }

    static func refreshActiveUI() {
        if let owner = InputFocusCoordinator.shared.interactionTarget(),
           let controller = owner.controller,
           let client = owner.client,
           InputFocusCoordinator.shared.isCurrent(owner.token, controller: controller) {
            controller.updateUI(client: client)
        } else {
            BufferWindowController.shared.refresh()
        }
    }

    private func updateUI(client: IMKTextInput) {
        guard session != 0, let focusToken else { return }
        guard let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else {
            IMELog.write("updateUI ignored; client no longer owns token=\(focusToken)")
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let status = rimeEngine.getStatus(session: session)
        let ctx = rimeEngine.getContext(session: session)
        watchdog("getContext", since: t0)

        // A schema switch made INSIDE Rime (F4 switcher) must feel as global
        // as a menu switch: persist it so other controllers adopt it on focus.
        if !currentSchemaId.isEmpty, status.schemaId != currentSchemaId, !status.schemaId.isEmpty {
            UserDefaults.standard.set(status.schemaId, forKey: "preferredSchema")
            IMELog.write("schema switched in-Rime -> \(status.schemaId)")
        }
        currentSchemaId = status.schemaId
        StatusMenu.shared.update(schemaId: status.schemaId, schemaName: status.schemaName)

        let bid = bundleId(of: client)
        let mode = CompositionSession.mode(for: bid)
        let bufferEnabled = shouldCaptureCommit(from: client)
        if bufferEnabled {
            composition.updateBufferGuard(preedit: ctx.preedit, client: client)
        } else {
            composition.update(preedit: ctx.preedit, cursorPosUTF8: ctx.cursorPos,
                               client: client, mode: mode)
        }
        publishCompositionActive(chord.hasPending || composition.composing
            || ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty)

        let showPreeditInPanel = bufferEnabled || mode == .placeholder
        let wantsPanel = !ctx.candidates.isEmpty
            || (showPreeditInPanel && (!ctx.preedit.isEmpty || !ctx.input.isEmpty))
        if wantsPanel {
            candidateWindow.update(ctx,
                                   caretRect: caretRect(for: client),
                                   bundleId: bid,
                                   showPreedit: showPreeditInPanel,
                                   owner: focusToken,
                                   presentation: BufferWindowController.shared.shouldProjectCandidates
                                       ? .workbench
                                       : .caret)
        } else {
            candidateWindow.hide(owner: focusToken)
        }
        BufferWindowController.shared.refresh()
    }

    private func refreshSchema() {
        guard session != 0 else { return }
        let status = rimeEngine.getStatus(session: session)
        currentSchemaId = status.schemaId
        StatusMenu.shared.update(schemaId: status.schemaId, schemaName: status.schemaName)
    }

    /// Caret rect in screen coords. Reliable while a marked-text session is
    /// active (§4.2); the candidate window validates + caches per bundleId.
    private func caretRect(for client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    private func bundleId(of client: IMKTextInput) -> String {
        client.bundleIdentifier() ?? "unknown"
    }

    private func watchdog(_ what: String, since t0: CFAbsoluteTime) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms > 250 {
            IMELog.write("WATCHDOG \(what) took \(ms)ms schema=\(currentSchemaId)")
        }
    }

    // MARK: System input-source menu / stored F4 schema preference

    override func menu() -> NSMenu! {
        StatusMenu.shared.makeInputSourceMenu(target: self)
    }

    // InputMethodKit routes commands from the system text-input menu back to
    // the active controller. Keep these selectors on the controller (as the
    // framework expects) and forward the work to the shared menu coordinator.
    @objc func openSettingsFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openSettings()
    }

    @objc func toggleBufferWindowFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.toggleBufferWindow()
    }

    @objc func toggleBufferPinnedFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.toggleBufferPinned()
    }

    @objc func moveBufferWindowFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.moveBufferWindowToCurrentScreen()
    }

    @objc func openInboundTrayFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openInboundTray()
    }

    @objc func checkUpdateFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.checkUpdate()
    }

    @objc func openLogFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openLog()
    }

    @objc func deployAndRestartFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.deployAndRestart()
    }

    @objc func reinstallFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.reinstallInputMethod()
    }

    @objc func restartFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.restart()
    }

    private func applyStoredPreferenceIfNeeded() {
        guard session != 0,
              let pref = UserDefaults.standard.string(forKey: "preferredSchema"),
              !pref.isEmpty else { return }
        // Only switch if the preferred schema is actually deployed. A stale or
        // removed preference (e.g. a custom 并击 schema not bundled in this build)
        // would otherwise put the session on an empty schema with no candidates.
        let available = rimeEngine.schemaList().map(\.id)
        guard available.isEmpty || available.contains(pref) else {
            IMELog.write("preferredSchema \(pref) not deployed; keeping current schema")
            return
        }
        let current = rimeEngine.getStatus(session: session).schemaId
        if current != pref {
            _ = rimeEngine.selectSchema(pref, session: session)
        }
    }
}
