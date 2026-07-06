import Cocoa
import InputMethodKit

// One librime instance per process (librime is global); SESSIONS are
// per-controller so composition never bleeds across fields. One shared
// candidate window (only one field composes at a time).
let rimeEngine = RimeEngine()
let candidateWindow = CandidateWindow()

@objc(RimeBufferController)
final class RimeBufferController: IMKInputController {

    /// The controller currently owning focus — StatusMenu routes schema
    /// switches here so they apply to the live session immediately.
    private(set) static weak var active: RimeBufferController?
    private static weak var recent: RimeBufferController?
    private static var chordDurationCache: TimeInterval?
    private static let duplicateBackspaceCommandWindow: CFTimeInterval = 0.05

    private var session: UInt64 = 0
    private var currentSchemaId = ""
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var lastClient: IMKTextInput?
    private var lastBufferBackspaceKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferBackspaceCommandHandledAt: CFAbsoluteTime = 0
    private let composition = CompositionSession()
    private let chord = ChordController()

    private var chordGated: Bool { currentSchemaId == "my_combo" }

    // MARK: Init / teardown

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        chord.onFlush = { [weak self] keys, client in
            self?.replayChordReleases(keys, client: client)
        }
        // NOTE: candidateWindow is shared; its onSelect is wired ONCE in
        // main.swift to route through `active` — wiring it here per-controller
        // would leave clicks bound to whichever controller initialized last.
    }

    deinit {
        chord.invalidate()
        if session != 0 { rimeEngine.destroySession(session) }
    }

    // MARK: Server lifecycle (focus in/out per client)

    override func activateServer(_ sender: Any!) {
        // Seed from real hardware state — clearing to [] would desync the
        // flagsChanged delta stream whenever a modifier (esp. Caps Lock) is
        // held or locked across a focus change.
        lastModifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Self.active = self
        Self.recent = self
        let activeClient: IMKTextInput? = (sender as? IMKTextInput) ?? self.client()
        if let activeClient {
            lastClient = activeClient
        }
        guard rimeEngine.start() else {
            StatusMenu.shared.setHealthy(false)
            IMELog.write("activate: engine down — raw passthrough mode")
            return
        }
        StatusMenu.shared.setHealthy(true)
        ensureSessionReady(applyPreference: true)
        if let activeClient, BufferModel.shared.shouldDisplay {
            candidateWindow.showBufferOnly(caretRect: caretRect(for: activeClient),
                                           bundleId: bundleId(of: activeClient))
        }
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

        if Self.chordDurationCache == nil,
           let d = rimeEngine.configDouble("squirrel", "chord_duration") {
            Self.chordDurationCache = d       // cache only a SUCCESSFUL read
            IMELog.write("chord_duration=\(d)")
        }
        chord.duration = Self.chordDurationCache ?? 0.10

        if applyPreference || fresh { applyStoredPreferenceIfNeeded() }
        if currentSchemaId.isEmpty { refreshSchema() }
        return true
    }

    override func deactivateServer(_ sender: Any!) {
        // IMK sometimes passes a nil/non-client sender here — fall back to
        // client() (Squirrel-proven) so live marked text never strands.
        resolveComposition(client: (sender as? IMKTextInput) ?? (self.client() as IMKTextInput?))
        Self.recent = self
        if Self.active === self { Self.active = nil }
    }

    override func commitComposition(_ sender: Any!) {
        resolveComposition(client: (sender as? IMKTextInput) ?? (self.client() as IMKTextInput?))
    }

    /// Safety net for paths that bypass IMK's callbacks (hostile apps on
    /// Cmd-Tab, status-menu restart, schema switch): resolve any in-flight
    /// chord + composition into the field NOW.
    func forceCommit() {
        resolveComposition(client: self.client() as IMKTextInput?)
    }

    /// Commit-on-blur: flush the chord, commit what Rime holds, close the
    /// marked-text session. Safe to call redundantly.
    private func resolveComposition(client: IMKTextInput?) {
        chord.flush()
        guard session != 0 else { return }
        if let client {
            _ = rimeEngine.commitComposition(session: session)
            drainCommit(client)
            composition.clear(client: client)
        } else {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
        }
        BufferModel.shared.compositionActive = false   // composition is resolved
        candidateWindow.hide()
    }

    // MARK: Key routing

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        Self.active = self
        Self.recent = self
        lastClient = client
        switch event.type {
        case .flagsChanged: return handleFlags(event, client: client)
        case .keyDown:      return handleKeyDown(event, client: client)
        default:            return false
        }
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
        // Engine down → raw fallback so the user can still type latin.
        guard rimeEngine.start(), ensureSessionReady() else {
            return rawFallback(event, client: client)
        }
        guard let keycode = keysym(for: event) else {
            chord.flush()   // the app will insert this key NOW; a pending chord must land first
            return false
        }
        let mask = RimeKey.modifierMask(from: event.modifierFlags)
        if handleBufferBackspace(keycode, mask: mask, client: client) {
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
        return processRimeKey(keycode, mask: mask, client: client)
    }

    private func handleBufferBackspace(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        guard keycode == RimeKey.backspace,
              BufferModel.shared.enabled,
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

    override func didCommand(by selector: Selector!, client sender: Any!) -> Bool {
        guard let selector else { return false }
        guard isDeleteBackwardSelector(selector),
              BufferModel.shared.enabled else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferBackspaceKeyHandledAt < Self.duplicateBackspaceCommandWindow {
            IMELog.write("buffer backspace command consumed after key selector=\(NSStringFromSelector(selector))")
            lastBufferBackspaceCommandHandledAt = now
            return true
        }

        guard let client = (sender as? IMKTextInput) ?? (self.client() as IMKTextInput?) else {
            if !BufferModel.shared.removeLastBlock() {
                IMELog.write("buffer backspace command consumed; no client/no blocks")
            }
            lastBufferBackspaceCommandHandledAt = now
            return true
        }

        Self.active = self
        Self.recent = self
        lastClient = client
        lastBufferBackspaceCommandHandledAt = now
        return performBufferBackspace(client: client, source: "command:\(NSStringFromSelector(selector))")
    }

    private func isDeleteBackwardSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))
    }

    private func performBufferBackspace(client: IMKTextInput, source: String) -> Bool {
        guard rimeEngine.start(), ensureSessionReady(), session != 0 else {
            if !BufferModel.shared.removeLastBlock() {
                IMELog.write("buffer backspace \(source) consumed; engine unavailable/no blocks")
            }
            BufferModel.shared.compositionActive = false
            candidateWindow.refreshBuffer()
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
        BufferModel.shared.compositionActive = false
        updateUI(client: client)
        return true
    }

    /// keyDown → Rime keysym: letters/punct/F-keys via the virtual-key table,
    /// then editing/navigation keys, then any typed ASCII character.
    private func keysym(for event: NSEvent) -> Int32? {
        if let k = RimeKey.fromVirtualKeyCode(event.keyCode) { return k }
        switch event.keyCode {
        case 36, 76: return RimeKey.return
        case 48:     return RimeKey.tab
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
            Delivery.insert("\n", into: client)
            return true
        }
        if let chars = event.characters, !chars.isEmpty,
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            Delivery.insert(chars, into: client)
            return true
        }
        return false
    }

    // MARK: Chord replay

    private func replayChordReleases(_ keys: [(keycode: Int32, mask: Int32)],
                                     client: (any IMKTextInput)?) {
        guard session != 0 else { return }
        for key in keys {
            _ = rimeEngine.processKey(key.keycode,
                                      mask: key.mask | RimeKey.releaseMask,
                                      session: session)
            // Chord commits go through the SAME routing as ordinary commits —
            // buffer mode must intercept these too.
            if let client { drainCommit(client) }
        }
        if let client { updateUI(client: client) }
    }

    // MARK: Candidate selection (mouse; routed here via `active` from main.swift)

    private func handleCandidateKey(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard candidateWindow.isVisible else { return false }
        switch keycode {
        case RimeKey.left:
            return candidateWindow.moveSelection(delta: -1)
        case RimeKey.right:
            return candidateWindow.moveSelection(delta: 1)
        case RimeKey.down:
            return pageCandidates(delta: 1, client: client)
        case RimeKey.up:
            return pageCandidates(delta: -1, client: client)
        case RimeKey.return:
            return commitRawInput(client: client)
        case 0x20:
            guard let index = candidateWindow.selectedCandidateIndex else { return false }
            selectCandidate(onPage: index)
            return true
        case 0x30:
            candidateWindow.performBufferAction()
            return true
        default:
            return false
        }
    }

    func pageCandidates(delta: Int) {
        guard let client = self.client() else { return }
        _ = pageCandidates(delta: delta, client: client)
    }

    @discardableResult
    private func pageCandidates(delta: Int, client: IMKTextInput) -> Bool {
        guard candidateWindow.hasCandidates else { return false }
        if candidateWindow.movePage(delta: delta) { return true }
        let keycode = delta < 0 ? RimeKey.pageUp : RimeKey.pageDown
        _ = processRimeKey(keycode, mask: 0, client: client)
        return true
    }

    func selectCandidate(onPage index: Int) {
        guard session != 0, let client = self.client() else { return }
        guard rimeEngine.selectCandidate(onPage: index, session: session) else { return }
        drainCommit(client)
        updateUI(client: client)
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
        if BufferModel.shared.enabled {
            BufferModel.shared.append(raw)
            composition.clear(client: client)
            IMELog.write("raw input '\(raw)' -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            Delivery.insert(raw, into: client)
            composition.commitDidInsert()
            IMELog.write("raw input '\(raw)' -> \(bundleId(of: client))")
        }
        BufferModel.shared.compositionActive = false
        updateUI(client: client)
        return true
    }

    // MARK: Commit drain + UI

    /// The single routing point (§5.9): buffer-OFF → straight to the field;
    /// buffer-ON → the commit becomes a staged block and the inline preedit is
    /// cleared from the field (nothing lands until the buffer flushes).
    private func drainCommit(_ client: IMKTextInput) {
        guard let commit = rimeEngine.takeCommit(session: session) else { return }
        if BufferModel.shared.enabled {
            BufferModel.shared.append(commit)
            composition.clear(client: client)
            IMELog.write("commit '\(commit)' -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            Delivery.insert(commit, into: client)
            composition.commitDidInsert()
            IMELog.write("commit '\(commit)' -> \(bundleId(of: client))")
        }
    }

    /// Buffer-flush destination: insert into whatever field currently has
    /// focus. Called via the sink wired in main.swift.
    func deliverText(_ text: String) -> Bool {
        let liveClient: IMKTextInput? = self.client()
        guard let client = liveClient ?? lastClient else {
            IMELog.write("buffer send blocked; no active IMK client")
            return false
        }
        Delivery.insert(text, into: client)
        lastClient = client
        return true
    }

    static func deliverBufferedText(_ text: String) -> Bool {
        guard let controller = active ?? recent else {
            IMELog.write("buffer send blocked; no active/recent controller")
            return false
        }
        return controller.deliverText(text)
    }

    static func refreshBufferDisplayForCurrentOrRecent() {
        if let controller = active ?? recent {
            controller.refreshBufferDisplay()
        } else {
            candidateWindow.refreshBuffer()
        }
    }

    func refreshBufferDisplay() {
        if candidateWindow.isVisible {
            candidateWindow.refreshBuffer()
            return
        }

        let liveClient: IMKTextInput? = self.client()
        guard let client = liveClient ?? lastClient,
              BufferModel.shared.shouldDisplay else {
            candidateWindow.refreshBuffer()
            return
        }
        candidateWindow.showBufferOnly(caretRect: caretRect(for: client),
                                       bundleId: bundleId(of: client))
    }

    private func updateUI(client: IMKTextInput) {
        guard session != 0 else { candidateWindow.hide(); return }

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
        composition.update(preedit: ctx.preedit, cursorPosUTF8: ctx.cursorPos,
                           client: client, mode: mode)
        BufferModel.shared.compositionActive = composition.composing   // expiry waits mid-composition

        let wantsPanel = !ctx.candidates.isEmpty
            || (mode == .placeholder && !ctx.preedit.isEmpty)
        if wantsPanel {
            candidateWindow.update(ctx,
                                   caretRect: caretRect(for: client),
                                   bundleId: bid,
                                   showPreedit: mode == .placeholder)
        } else if BufferModel.shared.shouldDisplay {
            candidateWindow.showBufferOnly(caretRect: caretRect(for: client), bundleId: bid)
        } else {
            candidateWindow.hide()
        }
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

    // MARK: Schema switching (IMK menu + StatusMenu)

    override func menu() -> NSMenu! {
        let m = NSMenu()
        for schema in StatusMenu.schemas {
            let mi = NSMenuItem(title: schema.title, action: #selector(chooseSchema(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = schema.id
            mi.state = currentSchemaId == schema.id ? .on : .off
            m.addItem(mi)
        }
        m.addItem(.separator())
        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        m.addItem(log)
        return m
    }

    @objc private func chooseSchema(_ sender: Any!) {
        // IMK passes the NSMenuItem directly or wrapped in a dictionary
        // depending on macOS version.
        let item = (sender as? NSMenuItem)
            ?? ((sender as? [String: Any])?["IMKCommandMenuItem"] as? NSMenuItem)
        guard let id = item?.representedObject as? String else { return }
        Self.applyPreferredSchema(id)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log"))
    }

    /// Set the preferred schema globally: persist it, apply to the live
    /// session now, and let every other controller apply it on next focus.
    static func applyPreferredSchema(_ id: String) {
        UserDefaults.standard.set(id, forKey: "preferredSchema")
        IMELog.write("preferredSchema -> \(id)")
        active?.switchSchema(id)
    }

    private func switchSchema(_ id: String) {
        guard session != 0 else { return }
        forceCommit()   // resolve any composition before the engine resets it
        _ = rimeEngine.selectSchema(id, session: session)
        refreshSchema()
    }

    private func applyStoredPreferenceIfNeeded() {
        guard session != 0,
              let pref = UserDefaults.standard.string(forKey: "preferredSchema"),
              !pref.isEmpty else { return }
        let current = rimeEngine.getStatus(session: session).schemaId
        if current != pref {
            _ = rimeEngine.selectSchema(pref, session: session)
        }
    }
}
