import Cocoa
import InputMethodKit
import Network
import CryptoKit
import Carbon

// `swift run RimeBuffer smoke` validates the engine end-to-end without IMK.
if CommandLine.arguments.contains("stats-smoke") {
    exit(runStatsSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("buffer-smoke") {
    exit(runBufferSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("schema-smoke") {
    exit(runSchemaListStoreSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("marine-bridge-smoke") {
    exit(runMarineBridgeSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("remote-smoke") {
    exit(runRemoteSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("matrix-smoke") {
    exit(runCandidateMatrixSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("origin-smoke") {
    exit(runOriginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("inbound-smoke") {
    exit(runInboundBusSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("smoke") {
    exit(runEngineSmokeTest() ? 0 : 1)
}

// Self-install into the input-source list. TIS enable/select only persist when
// run INSIDE the login (Aqua) session — a detached CLI's writes return success
// but never land. So the installer / build script launches THIS bundle in the
// user session (`open -n ETInput.app --args --install`) to register + enable +
// select itself, exactly like Squirrel's --install. Runs before the IMK server
// so this short-lived instance never contends for the connection.
if CommandLine.arguments.contains("--install") {
    exit(installInputSource() ? 0 : 1)
}
if CommandLine.arguments.contains("--prepare-update") {
    exit(selectFallbackInputSourceForUpdate() ? 0 : 1)
}
// Dev-only: show the Settings window standalone (no IMK) so it can be reviewed
// or screenshotted without a live input session. Not wired into the shipped
// menus; invoked manually as `ETInput settings-preview`.
if CommandLine.arguments.contains("settings-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    SettingsWindowController.shared.show()
    app.activate(ignoringOtherApps: true)
    app.run()
}
// Dev-only: `ETInput settings-render <dir>` writes page-N.png for every page.
if let i = CommandLine.arguments.firstIndex(of: "settings-render"),
   i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    for page in 0..<6 {
        SettingsWindowController.shared.renderForPreview(
            pageIndex: page, to: "\(dir)/page-\(page).png")
    }
    print("rendered settings pages to \(dir)")
    exit(0)
}
// Dev-only: `ETInput panel-render <path>` writes the three-layer workbench bar.
if let i = CommandLine.arguments.firstIndex(of: "panel-render"),
   i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    WorkbenchBarView.renderDemo(to: CommandLine.arguments[i + 1])
    print("rendered workbench bar")
    exit(0)
}
// Dev-only: `ETInput gateway-serve` runs the local gateway + a runloop and prints
// each inbound event, so the productized HTTP/MCP path can be exercised by curl
// and the real `claude` client without the full IMK bootstrap.
if CommandLine.arguments.contains("gateway-serve") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    BufferModel.shared.deliver = { _, _ in true }
    InboundBus.shared.onChange = {
        let p = InboundBus.shared.pending
        print("[inbound] pending=\(p.count) latest=\(p.last.map { "\($0.origin.tag):\($0.text.count)chars streaming=\($0.streaming)" } ?? "-")")
        fflush(stdout)
    }
    LocalGateway.shared.start()
    print("gateway-serve on 127.0.0.1:\(LocalGateway.shared.port) token=\(GatewayToken.current())")
    fflush(stdout)
    app.run()
}

// IMK bootstrap. The connection name MUST match Info.plist; IMK finds our
// controller via InputMethodServerControllerClass = RimeBufferController.
IMELog.reset("=== Enter输入法 (ETInput) IME launch ===")
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "RimeBuffer_1_Connection"

NSApplication.shared.setActivationPolicy(.accessory)   // background app; panels can float above others

// Held for the process lifetime so the IMK connection stays up.
let imkServer = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
if imkServer == nil {
    // No connection = a selectable-but-dead input source. Exit loudly; the
    // text-input system respawns us on demand once the cause is fixed.
    IMELog.write("FATAL: IMKServer(name: \(connectionName)) returned nil — exiting")
    exit(1)
}
// Warm the engine so the first keystroke isn't slow / so failures surface early.
_ = rimeEngine.start()

// Mouse-selection routes to whichever controller currently owns focus — the
// shared window must never bind to one specific controller.
candidateWindow.onSelect = { selection in
    RimeBufferController.active?.selectCandidate(selection)
}
candidateWindow.onSettings = {
    SettingsWindowController.shared.show()
}

// Buffer wiring: flushes deliver to the focused field; every model change
// re-renders the inline buffer that lives inside the candidate window.
BufferModel.shared.deliver = { text, origin in
    RimeBufferController.deliverBufferedText(text, origin: origin)
}
BufferModel.shared.onChange = {
    RimeBufferController.refreshBufferDisplayForCurrentOrRecent()
}
candidateWindow.refreshBuffer()

// Local gateway: accept MCP / HTTP pushes from local agents into the inbound
// bus (loopback-only, token-gated). Off is a one-line setting.
InboundBus.shared.onChange = {
    InboundTrayWindow.refreshIfOpen()
    InboundToast.shared.update(pendingCount: InboundBus.shared.pendingCount,
                               trayVisible: InboundTrayWindow.isVisible)
}
LocalGateway.shared.startIfEnabled()

// No standalone NSStatusItem: ETInput's commands are supplied by
// RimeBufferController.menu() under the system input-source icon.
StatusMenu.shared.setHealthy(rimeEngine.isHealthy)

// Auto-update: silently check GitHub Releases on launch + hourly, download in the
// background, and surface it through the input method's controls when ready.
UpdateManager.shared.startPeriodicUpdateCheck()

// Remote typing ("隔空传字"): text committed here mirrors to a paired Mac; text
// from the peer lands here — into the focused field if ETInput is active, else
// on the clipboard as a fallback. Both callbacks run on the main thread.
var remoteClipboardBuffer = ""   // accumulates received text while no field is focused
RemoteTypingService.shared.onReceiveText = { text in
    if RimeBufferController.insertRemoteText(text) {
        remoteClipboardBuffer = ""
        IMELog.write("remote: inserted received text into focused field")
    } else {
        // No focused field — accumulate onto the clipboard (don't clobber each
        // prior message) so the user can paste the whole thing.
        remoteClipboardBuffer += text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remoteClipboardBuffer, forType: .string)
        IMELog.write("remote: no focused field; accumulated \(remoteClipboardBuffer.count) chars to clipboard")
    }
}
// A peer asks to pair — show 同意/拒绝 with the 4-digit SAS. One tap, no code entry.
RemoteTypingService.shared.onPairRequest = { peerName, sas, respond in
    let alert = NSAlert()
    alert.messageText = "「\(peerName)」请求隔空传字"
    alert.informativeText = "同意后，对方打的字会即时出现在你这里，你打的字也会发给对方。\n验证码：\(sas)（两台显示一致即代表安全，无中间人）"
    alert.addButton(withTitle: "同意")
    alert.addButton(withTitle: "拒绝")
    NSApp.activate(ignoringOtherApps: true)
    respond(alert.runModal() == .alertFirstButtonReturn)
}
// We initiated pairing and reached the peer — confirm the SAS matches, then request.
RemoteTypingService.shared.onPairConfirm = { peerName, sas, proceed in
    let alert = NSAlert()
    alert.messageText = "与「\(peerName)」配对"
    alert.informativeText = "请核对两台 Mac 显示的验证码一致：\(sas)\n一致后点「配对」，再请对方点「同意」。"
    alert.addButton(withTitle: "配对")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    proceed(alert.runModal() == .alertFirstButtonReturn)
}
RemoteTypingService.shared.onStatusChange = {
    SettingsWindowController.shared.remoteStatusDidChange()
}
RemoteTypingService.shared.restart()   // starts only if enabled

// macOS 26 can omit deactivateServer when another process switches input
// sources through TISSelectInputSource. The distributed TIS notification still
// arrives, so finish the live controller before its client becomes stranded.
let inputSourceChangedObserver = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
    object: nil,
    queue: .main
) { _ in
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let currentID = tisStringProperty(current, kTISPropertyInputSourceID) else {
        IMELog.write("TIS source changed: current source unavailable")
        return
    }
    let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    IMELog.write("TIS source changed: current=\(currentID) frontmost=\(frontmostID)")
    let ownID = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
    guard currentID != ownID, !currentID.hasPrefix(ownID + "."),
          let controller = RimeBufferController.active else { return }
    IMELog.write("input source changed away programmatically -> \(currentID); finalizing active controller")
    controller.deactivateServer(controller.client())
    candidateWindow.hide()
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { note in
    // Hostile apps may never deliver deactivateServer on Cmd-Tab — resolve
    // any in-flight chord/composition into its field instead of stranding
    // marked text. No-op when the switch was already handled normally.
    RimeBufferController.active?.forceCommit()

    // Reset staged buffer when focus leaves for a DIFFERENT app — but ONLY
    // locally-typed content. Two exceptions:
    //  · our own windows (Settings, inbox, pairing) activate us via
    //    NSApp.activate; filtering our bundle keeps opening them from self-wiping.
    //  · externally-accepted content (MCP/HTTP/远端) is staged precisely to be
    //    delivered to another app, so switching to that app must NOT wipe it.
    if BufferModel.shared.resetOnAppSwitch, !BufferModel.shared.holdsExternalContent {
        let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication)?.bundleIdentifier
        let own = Bundle.main.bundleIdentifier
        if let activated, activated != own {
            BufferModel.shared.clear()
        }
    }
    candidateWindow.hide()
}
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: NSApp,
    queue: .main
) { _ in
    KeyFrequencyStore.shared.saveNow()
}

IMELog.write("bootstrap done: server=\(imkServer != nil) engineHealthy=\(rimeEngine.isHealthy)")

NSApplication.shared.run()

// MARK: - Input-source lifecycle

private func tisStringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func tisBoolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    return Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().boolValue
}

/// Move the login session off ETInput before replacing its bundle or killing
/// its process. Long-lived clients (notably WeChat/Electron) otherwise retain a
/// dead IMK document connection and can immediately undo later source changes.
/// The legacy ETInput identity is included so an upgrade from older builds is
/// also handed off cleanly.
func selectFallbackInputSourceForUpdate() -> Bool {
    let ownBundleIDs = Set([
        Bundle.main.bundleIdentifier ?? "",
        "com.isaac.inputmethod.RimeBuffer",
        "com.isaac.inputmethod.ETInput",
    ].filter { !$0.isEmpty })

    func belongsToETInput(_ source: TISInputSource) -> Bool {
        if let bundleID = tisStringProperty(source, kTISPropertyBundleID),
           ownBundleIDs.contains(bundleID) {
            return true
        }
        guard let sourceID = tisStringProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        return ownBundleIDs.contains { sourceID == $0 || sourceID.hasPrefix($0 + ".") }
    }

    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        print("prepare-update: no current keyboard input source")
        return false
    }
    let currentID = tisStringProperty(current, kTISPropertyInputSourceID) ?? "(unknown)"
    guard belongsToETInput(current) else {
        print("prepare-update: current source is already safe: \(currentID)")
        return true
    }

    var candidates: [TISInputSource] = []
    if let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
        candidates.append(layout)
    }
    if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
        candidates.append(ascii)
    }
    if let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] {
        candidates.append(contentsOf: all.filter {
            tisBoolProperty($0, kTISPropertyInputSourceIsASCIICapable)
        })
    }

    for fallback in candidates {
        guard !belongsToETInput(fallback),
              tisBoolProperty(fallback, kTISPropertyInputSourceIsEnabled),
              tisBoolProperty(fallback, kTISPropertyInputSourceIsSelectCapable) else {
            continue
        }
        let fallbackID = tisStringProperty(fallback, kTISPropertyInputSourceID) ?? "(unknown)"
        let status = TISSelectInputSource(fallback)
        print("prepare-update: select fallback=\(status) \(fallbackID)")
        guard status == noErr else { continue }

        for _ in 0..<20 {
            if let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               !belongsToETInput(selected) {
                let selectedID = tisStringProperty(selected, kTISPropertyInputSourceID) ?? fallbackID
                print("prepare-update: fallback verified: \(selectedID)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    print("prepare-update: could not select a non-ETInput ASCII fallback")
    return false
}

/// Registers this bundle's path with TIS, then enables + selects our input mode.
/// Must run inside the login session (see call site). Mirrors Squirrel's
/// RegisterInputSource + ActivateInputSource.
func installInputSource() -> Bool {
    guard let component = Bundle.main.infoDictionary?["ComponentInputModeDict"] as? [String: Any],
          let visibleModes = component["tsVisibleInputModeOrderedArrayKey"] as? [String],
          let modeID = visibleModes.first,
          let bundleID = Bundle.main.bundleIdentifier else {
        print("install: missing bundle/input-mode metadata")
        return false
    }

    // Register THIS bundle's URL so the input-source id resolves to this exact
    // copy (kills the "duplicate id at multiple paths → blank row" problem).
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("install: register \(Bundle.main.bundleURL.path) -> \(status)")
    guard status == noErr else { return false }

    guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else {
        print("install: no input source list")
        return false
    }
    let list = cf as! [TISInputSource]
    var parentSource: TISInputSource?
    var selectableMode: TISInputSource?

    // TIS exposes a non-selectable parent input method plus one or more
    // selectable modes. Both must be enabled, but only the child mode may be
    // passed to TISSelectInputSource. Discover both first because TIS does not
    // promise list order; enabling the child before its parent can fail.
    for src in list {
        guard tisStringProperty(src, kTISPropertyBundleID) == bundleID else { continue }
        let id = tisStringProperty(src, kTISPropertyInputSourceID) ?? "(unknown)"
        if id == bundleID, !tisBoolProperty(src, kTISPropertyInputSourceIsSelectCapable) {
            parentSource = src
        }
        if id == modeID, tisBoolProperty(src, kTISPropertyInputSourceIsSelectCapable) {
            selectableMode = src
        }
    }

    guard let parentSource, let selectableMode else {
        print("install: parent or selectable mode \(modeID) not found in TIS list")
        return false
    }

    let parentIsASCIICapable = tisBoolProperty(parentSource, kTISPropertyInputSourceIsASCIICapable)
    let parentType = tisStringProperty(parentSource, kTISPropertyInputSourceType) ?? "(unknown)"
    let parentCategory = tisStringProperty(parentSource, kTISPropertyInputSourceCategory) ?? "(unknown)"
    print("install: parent metadata id=\(bundleID) type=\(parentType) category=\(parentCategory) ascii=\(parentIsASCIICapable)")

    let isASCIICapable = tisBoolProperty(selectableMode, kTISPropertyInputSourceIsASCIICapable)
    let sourceType = tisStringProperty(selectableMode, kTISPropertyInputSourceType) ?? "(unknown)"
    let category = tisStringProperty(selectableMode, kTISPropertyInputSourceCategory) ?? "(unknown)"
    print("install: mode metadata id=\(modeID) type=\(sourceType) category=\(category) ascii=\(isASCIICapable)")
    guard !isASCIICapable else {
        print("install: refusing ASCII-capable Chinese mode; TIS is serving stale metadata")
        return false
    }

    let parentEnableStatus = tisBoolProperty(parentSource, kTISPropertyInputSourceIsEnabled)
        ? noErr : TISEnableInputSource(parentSource)
    print("install: enable parent=\(parentEnableStatus) \(bundleID)")
    guard parentEnableStatus == noErr else { return false }

    let modeEnableStatus = tisBoolProperty(selectableMode, kTISPropertyInputSourceIsEnabled)
        ? noErr : TISEnableInputSource(selectableMode)
    print("install: enable mode=\(modeEnableStatus) \(modeID)")
    guard modeEnableStatus == noErr else { return false }

    guard tisBoolProperty(parentSource, kTISPropertyInputSourceIsEnabled),
          tisBoolProperty(selectableMode, kTISPropertyInputSourceIsEnabled) else {
        print("install: parent/mode did not remain enabled")
        return false
    }

    // The historical WeChat crash is in Apple's input-source HUD before our
    // controller runs. Never trigger that path automatically while WeChat is
    // frontmost; registration/enabling still succeeds and ABC remains active.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.xinWeChat" {
        print("install: WeChat is frontmost; skipping automatic selection")
        return true
    }

    let selectStatus = TISSelectInputSource(selectableMode)
    print("install: select=\(selectStatus) \(modeID)")

    // On macOS 26 the first selection after changing input-mode metadata can
    // return paramErr even though TextInputMenuAgent applies it asynchronously.
    // Trust the observable TIS state, not only the immediate OSStatus.
    for _ in 0..<20 {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           tisStringProperty(current, kTISPropertyInputSourceID) == modeID {
            print("install: selected mode verified")
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("install: selection verification timed out")
    return false
}

// MARK: - Engine smoke harness (bring-up only)

func runEngineSmokeTest() -> Bool {
    let engine = RimeEngine()
    print("== RimeBuffer engine smoke test ==")
    let ok = engine.start()
    print("start:", ok, "healthy:", engine.isHealthy)
    guard ok, engine.isHealthy else {
        print("FAILED: engine start:", engine.lastError())
        return false
    }

    let session = engine.createSession()
    print("session:", session)
    guard session != 0 else {
        print("FAILED: no session")
        return false
    }
    defer { engine.destroySession(session) }

    let expectedSchemas = InputSchemaCatalog.defaultEnabledIDs
    let deployedSchemas = engine.schemaList()
    let deployedIDs = deployedSchemas.map(\.id)
    print("deployed schemas:", deployedSchemas.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
    guard deployedIDs == expectedSchemas else {
        print("FAILED: schema_list expected=\(expectedSchemas) actual=\(deployedIDs)")
        return false
    }

    let defaultStatus = engine.getStatus(session: session)
    print("default schema: \(defaultStatus.schemaId) (\(defaultStatus.schemaName))")

    // Use a sequential Chinese schema for deterministic CLI key replay. The
    // default my_combo schema expects physical chord press/release timing.
    guard engine.selectSchema("rime_ice", session: session),
          engine.getStatus(session: session).schemaId == "rime_ice" else {
        print("FAILED: cannot select rime_ice")
        return false
    }
    engine.setOption("ascii_mode", false, session: session)
    engine.clearComposition(session: session)
    print("typing 'nihao' on rime_ice ...")
    for scalar in "nihao".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: session)
    }
    let ctx = engine.getContext(session: session)
    print("active=\(ctx.active) preedit='\(ctx.preedit)' page=\(ctx.pageNo) cands=\(ctx.candidates.count)")
    for c in ctx.candidates {
        print("  [\(c.label)] \(c.text)\(c.comment.isEmpty ? "" : "  · \(c.comment)")")
    }
    guard ctx.candidates.contains(where: { $0.text == "你好" }) else {
        print("FAILED: rime_ice did not produce 你好")
        return false
    }
    _ = engine.processKey(0x20, session: session)
    let chineseCommit = engine.takeCommit(session: session) ?? ""
    print("committed:", chineseCommit)
    guard chineseCommit == "你好" else {
        print("FAILED: unexpected Chinese commit '\(chineseCommit)'")
        return false
    }

    guard engine.selectSchema("english", session: session),
          engine.getStatus(session: session).schemaId == "english" else {
        print("FAILED: cannot select english")
        return false
    }
    engine.setOption("ascii_mode", false, session: session)

    engine.clearComposition(session: session)
    for scalar in "hel".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: session)
    }
    let completionContext = engine.getContext(session: session)
    let completionSamples = completionContext.candidates.prefix(8).map(\.text)
    print("english 'hel' candidates:", completionSamples)
    guard completionSamples.contains(where: { $0.lowercased().hasPrefix("hel") && $0.count > 3 }) else {
        print("FAILED: English prefix completion is unavailable")
        return false
    }

    func typeAndCommitEnglish(_ text: String) -> String {
        engine.clearComposition(session: session)
        for scalar in text.unicodeScalars {
            _ = engine.processKey(Int32(scalar.value), session: session)
        }
        _ = engine.processKey(0x20, session: session)
        return engine.takeCommit(session: session) ?? ""
    }

    let helloCommit = typeAndCommitEnglish("hello")
    let worldCommit = typeAndCommitEnglish("world")
    let rawCommit = typeAndCommitEnglish("codexzzq")
    print("english commits:", [helloCommit, worldCommit, rawCommit])
    guard helloCommit == "hello",
          worldCommit == " world",
          rawCommit.trimmingCharacters(in: .whitespaces) == "codexzzq" else {
        print("FAILED: English commit/spacing/raw fallback")
        return false
    }

    guard engine.selectSchema("my_combo", session: session) else {
        print("FAILED: cannot return to my_combo")
        return false
    }

    // F4 owns schema switching. The configured members/order were asserted
    // above; this additionally proves the switcher key enters Rime's menu.
    engine.clearComposition(session: session)
    let f4Handled = engine.processKey(RimeKey.f1 + 3, session: session)
    let switcherContext = engine.getContext(session: session)
    print("F4 handled=\(f4Handled) candidates=\(switcherContext.candidates.map(\.text))")
    let switcherNames = Set(switcherContext.candidates.map(\.text))
    let expectedNames = Set(InputSchemaCatalog.options.map(\.name))
    guard f4Handled, expectedNames.isSubset(of: switcherNames) else {
        print("FAILED: F4 schema switcher is incomplete")
        return false
    }
    print("engine smoke: OK")
    return true
}

func runSchemaListStoreSmokeTest() -> Bool {
    print("== RimeBuffer schema-list store smoke test ==")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rimebuffer-schema-list-\(UUID().uuidString)")
    let config = root.appendingPathComponent("default.custom.yaml")
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initial = """
        patch:
          schema_list:
            - schema: my_serial
            - schema: melt_eng
          menu:
            page_size: 9
          custom_flag: keep-me
        """
        try initial.write(to: config, atomically: true, encoding: .utf8)
        try SchemaListStore.writeEnabledIDs(["english", "my_combo", "rime_ice", "double_pinyin"],
                                            to: config)
        let ids = SchemaListStore.enabledIDs(at: config)
        let rewritten = try String(contentsOf: config, encoding: .utf8)
        guard ids == InputSchemaCatalog.defaultEnabledIDs,
              rewritten.contains("page_size: 9"),
              rewritten.contains("custom_flag: keep-me"),
              !rewritten.contains("my_serial"),
              !rewritten.contains("melt_eng") else {
            print("FAILED: schema-list rewrite", ids, rewritten)
            return false
        }

        do {
            try SchemaListStore.writeEnabledIDs([], to: config)
            print("FAILED: empty schema selection was accepted")
            return false
        } catch SchemaListStore.StoreError.emptySelection {
            // Expected.
        }
    } catch {
        print("FAILED: schema-list store error:", error)
        return false
    }

    print("schema-list store smoke: OK")
    return true
}

func runStatsSmokeTest() -> Bool {
    print("== RimeBuffer key-frequency smoke test ==")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rimebuffer-key-frequency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let calendar = Calendar(identifier: .gregorian)
    let day1 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5))!
    let day2 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!

    let store1 = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day1 }
    store1.record(keyCode: 0)       // A
    store1.record(keyCode: 0)       // A
    store1.record(keyCode: 8)       // C
    store1.recordModifierPress(keyCode: 55, flags: [.command])
    store1.recordModifierPress(keyCode: 55, flags: [])   // release, ignored
    store1.saveNow()

    let reloaded = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day1 }
    let day1Snapshot = reloaded.snapshot(for: day1)
    guard day1Snapshot.counts["KeyA"] == 2,
          day1Snapshot.counts["KeyC"] == 1,
          day1Snapshot.counts["LeftCommand"] == 1,
          day1Snapshot.total == 4 else {
        print("FAILED: day1 snapshot", day1Snapshot)
        return false
    }

    let store2 = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day2 }
    store2.record(keyCode: 11)      // B
    store2.saveNow()
    guard store2.snapshot(for: day1).total == 4,
          store2.snapshot(for: day2).counts["KeyB"] == 1 else {
        print("FAILED: day bucket isolation")
        return false
    }

    store2.clear(day: day1)
    guard store2.snapshot(for: day1).total == 0,
          store2.snapshot(for: day2).total == 1 else {
        print("FAILED: clear day")
        return false
    }

    store2.clear(day: nil)
    guard store2.snapshot(for: day2).total == 0 else {
        print("FAILED: clear all")
        return false
    }

    print("stats smoke: OK")
    return true
}

/// Pins the matrix viewport math. The three-row cap is visual only: the window
/// must slide far enough to reach the last page, never past the ends, and must
/// always keep the selected row on screen — a wrong base here would render one
/// row while selecting a different page's candidate.
func runCandidateMatrixSmokeTest() -> Bool {
    print("== RimeBuffer candidate matrix smoke test ==")
    let maxRows = CandidateWindow.expandedMaxRows
    guard maxRows == 3 else {
        print("FAILED: expected a three-row viewport, got \(maxRows)")
        return false
    }

    // Walking ↓ through six pages: the window pins to the top until the
    // selection leaves it, then trails the selection one row at a time.
    let walkDown = [0, 0, 0, 1, 2, 3]
    var base = 0
    for selection in 0..<6 {
        base = CandidateWindow.windowBase(selection: selection, currentBase: base, pageCount: 6)
        guard base == walkDown[selection] else {
            print("FAILED: ↓ to row \(selection) expected base \(walkDown[selection]), got \(base)")
            return false
        }
    }
    // ...and walking back ↑ retraces it, so the first page stays reachable.
    let walkUp = [0, 1, 2, 3, 3, 3]
    for selection in (0..<6).reversed() {
        base = CandidateWindow.windowBase(selection: selection, currentBase: base, pageCount: 6)
        guard base == walkUp[selection] else {
            print("FAILED: ↑ to row \(selection) expected base \(walkUp[selection]), got \(base)")
            return false
        }
    }

    // Fewer pages than rows must never scroll.
    for pageCount in 1...maxRows {
        for selection in 0..<pageCount {
            let b = CandidateWindow.windowBase(selection: selection, currentBase: 0, pageCount: pageCount)
            guard b == 0 else {
                print("FAILED: \(pageCount) pages should not scroll, got base \(b)")
                return false
            }
        }
    }

    // Invariants over every reachable (pageCount, base, selection): the base is
    // in range and its window contains the selection — from any starting base,
    // so a click or a re-fetch can never strand the selection off screen.
    for pageCount in 1...12 {
        for startBase in 0..<pageCount {
            for selection in 0..<pageCount {
                let b = CandidateWindow.windowBase(selection: selection,
                                                   currentBase: startBase,
                                                   pageCount: pageCount)
                let maxBase = max(0, pageCount - maxRows)
                guard b >= 0, b <= maxBase else {
                    print("FAILED: base \(b) out of 0...\(maxBase) (pages=\(pageCount) sel=\(selection))")
                    return false
                }
                guard selection >= b, selection < b + maxRows else {
                    print("FAILED: row \(selection) outside window \(b)..<\(b + maxRows) (pages=\(pageCount))")
                    return false
                }
            }
        }
    }

    // The last page must be reachable: its window is the final one.
    for pageCount in 4...12 {
        let b = CandidateWindow.windowBase(selection: pageCount - 1, currentBase: 0, pageCount: pageCount)
        guard b == pageCount - maxRows else {
            print("FAILED: last page of \(pageCount) expected base \(pageCount - maxRows), got \(b)")
            return false
        }
    }

    // --- Column viewport ---------------------------------------------------
    // A page_size:9 row that fits (9*40 + 8 separators*8 = 424 <= 460): the
    // common case, where the viewport must never scroll.
    let roomy = Array(repeating: CGFloat(40), count: 9)
    guard CandidateWindow.fittedColumnCount(widths: roomy, separator: 8, available: 460, base: 0) == 9 else {
        print("FAILED: nine 40pt candidates should all fit in 460pt")
        return false
    }
    for selection in 0..<9 {
        let b = CandidateWindow.columnBase(selection: selection, currentBase: 0, widths: roomy,
                                           separator: 8, available: 460)
        guard b == 0 else {
            print("FAILED: a row that fits must not scroll, got base \(b) for column \(selection)")
            return false
        }
    }

    // Narrow row: only some columns fit, so the tail is reachable only if the
    // viewport scrolls — this is the case the fix exists for.
    let tight = Array(repeating: CGFloat(100), count: 9)
    let fits = CandidateWindow.fittedColumnCount(widths: tight, separator: 8, available: 320, base: 0)
    guard fits > 0, fits < 9 else {
        print("FAILED: expected a partially fitting row, got \(fits)/9")
        return false
    }
    // Every candidate must be reachable, and the window must contain it.
    var colBase = 0
    for selection in 0..<9 {
        colBase = CandidateWindow.columnBase(selection: selection, currentBase: colBase, widths: tight,
                                             separator: 8, available: 320)
        let count = CandidateWindow.fittedColumnCount(widths: tight, separator: 8,
                                                      available: 320, base: colBase)
        guard selection >= colBase, selection < colBase + count else {
            print("FAILED: column \(selection) unreachable — window \(colBase)..<\(colBase + count)")
            return false
        }
    }
    // ...and walking back left retraces to the first column.
    for selection in (0..<9).reversed() {
        colBase = CandidateWindow.columnBase(selection: selection, currentBase: colBase, widths: tight,
                                             separator: 8, available: 320)
        let count = CandidateWindow.fittedColumnCount(widths: tight, separator: 8,
                                                      available: 320, base: colBase)
        guard selection >= colBase, selection < colBase + count else {
            print("FAILED: column \(selection) unreachable going back — window \(colBase)..<\(colBase + count)")
            return false
        }
    }
    guard colBase == 0 else {
        print("FAILED: walking left should return to column 0, got base \(colBase)")
        return false
    }

    // A single candidate wider than the whole row still renders (and stays
    // selectable) rather than vanishing.
    guard CandidateWindow.fittedColumnCount(widths: [900, 50], separator: 8, available: 460, base: 0) == 1 else {
        print("FAILED: an over-wide candidate must still occupy one column")
        return false
    }

    print("candidate matrix smoke OK")
    return true
}

/// Pins the echo guard — the workbench's rule that a peer's text is never
/// mirrored back. A wrong verdict here means two paired Macs bounce text
/// forever (or, the other way, that a legitimately-typed block silently fails
/// to reach the other Mac). Also checks the block-origin plumbing: appended
/// text carries its origin, and the send path can read it back.
/// Pins the inbound gating: trusted sources drop straight to the buffer, `ask`
/// sources wait as pending, blocked sources vanish, the pending cap holds, and
/// accept moves an item into the buffer carrying its origin. A wrong verdict
/// here would let unverified external text reach the buffer without review.
func runInboundBusSmokeTest() -> Bool {
    print("== RimeBuffer inbound bus smoke test ==")
    let bus = InboundBus.shared
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldDeliver = model.deliver
    defer { model.clear(); bus.clear(); model.enabled = oldEnabled; model.deliver = oldDeliver }
    model.deliver = { _, _ in true }
    model.enabled = true
    model.clear(); bus.clear()

    // Trust defaults: mcp/http = ask, marine = trusted.
    guard bus.trust(for: .mcp(client: "x")) == .ask,
          bus.trust(for: .http(source: "s")) == .ask,
          bus.trust(for: .marine) == .trusted else {
        print("FAILED: trust defaults wrong")
        return false
    }

    // ask source → pending, NOT in the buffer yet.
    let id = bus.submit(origin: .mcp(client: "codex"), text: "草稿一", title: "t")
    guard let id, bus.pendingCount == 1, model.blocks.isEmpty else {
        print("FAILED: ask source should wait in pending, not enter buffer")
        return false
    }
    // trusted source → straight to buffer, no pending.
    _ = bus.submit(origin: .marine, text: "marine 草稿")
    guard bus.pendingCount == 1, model.blocks.count == 1,
          model.blocks[0].origin == .marine else {
        print("FAILED: trusted source should drop into buffer")
        return false
    }
    // accept the pending mcp item → becomes a buffer block with mcp origin.
    bus.accept(id)
    guard bus.pendingCount == 0, model.blocks.count == 2,
          model.blocks.contains(where: { $0.origin == .mcp(client: "codex") }) else {
        print("FAILED: accept should move item into buffer with its origin")
        return false
    }
    // Externally-staged content must be marked so the switch-app reset spares it
    // (otherwise focusing the target field wipes what MCP/远端 just delivered).
    guard model.holdsExternalContent else {
        print("FAILED: buffer with external blocks must report holdsExternalContent")
        return false
    }
    // reject removes without touching the buffer.
    let rid = bus.submit(origin: .http(source: "s"), text: "拒绝我")
    bus.reject(rid!)
    guard bus.pendingCount == 0, model.blocks.count == 2 else {
        print("FAILED: reject should drop the item, not deliver it")
        return false
    }

    // Streaming: text updates in place, one pending item, endStream settles it.
    model.clear(); bus.clear()
    _ = bus.beginStream(origin: .mcp(client: "a"), streamID: "s1")
    bus.appendStream(streamID: "s1", delta: "部分")
    bus.appendStream(streamID: "s1", delta: "文本")
    guard bus.pendingCount == 1, bus.pending[0].text == "部分文本", bus.pending[0].streaming else {
        print("FAILED: streaming should update one item in place")
        return false
    }
    bus.endStream(streamID: "s1")
    guard !bus.pending[0].streaming else {
        print("FAILED: endStream should settle the item")
        return false
    }

    // Pending cap holds.
    bus.clear()
    for i in 0..<(InboundBus.maxPending + 10) { _ = bus.submit(origin: .mcp(client: "a"), text: "x\(i)") }
    guard bus.pendingCount == InboundBus.maxPending else {
        print("FAILED: pending cap not enforced, got \(bus.pendingCount)")
        return false
    }

    // A purely locally-typed buffer must NOT count as external, so the switch-
    // app reset still clears normal typing.
    model.clear(); bus.clear()
    model.append("本地打字")   // origin defaults to .rime
    guard !model.holdsExternalContent else {
        print("FAILED: locally-typed buffer must not report holdsExternalContent")
        return false
    }

    print("inbound bus smoke OK")
    return true
}

func runOriginSmokeTest() -> Bool {
    print("== RimeBuffer origin/echo smoke test ==")

    // Only remote-peer origins are barred from mirroring; every other source
    // (local typing, agent drafts, network inbound) mirrors as before.
    let mirrors: [Origin] = [.rime, .marine, .mcp(client: "x"),
                             .http(source: "s"), .sse(feed: "f"), .ssh(host: "h")]
    for o in mirrors where !o.allowsRemoteMirror {
        print("FAILED: \(o.tag) should mirror to remote")
        return false
    }
    guard !Origin.remotePeer(deviceID: "mac-b").allowsRemoteMirror else {
        print("FAILED: remotePeer must NOT mirror back (echo loop)")
        return false
    }

    // Origin identity is by-case AND by-payload, so two peers stay distinct.
    guard Origin.remotePeer(deviceID: "a") != Origin.remotePeer(deviceID: "b"),
          Origin.mcp(client: "a") != Origin.rime else {
        print("FAILED: origin equality is wrong")
        return false
    }

    // Block plumbing: default origin is rime; explicit origin is preserved and
    // readable where the send path reads it.
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldDeliver = model.deliver
    defer { model.clear(); model.enabled = oldEnabled; model.deliver = oldDeliver }
    model.deliver = { _, _ in true }
    model.enabled = true
    model.clear()
    model.append("你")
    model.append("hi", origin: .mcp(client: "codex"))
    guard model.blocks.count == 2,
          model.blocks[0].origin == .rime,
          model.blocks[1].origin == .mcp(client: "codex") else {
        print("FAILED: append did not carry origin: \(model.blocks.map(\.origin.tag))")
        return false
    }

    print("origin/echo smoke OK")
    return true
}

func runBufferSmokeTest() -> Bool {
    print("== RimeBuffer buffer smoke test ==")
    guard RimeKey.fromVirtualKeyCode(22) == 0x36,
          RimeKey.fromVirtualKeyCode(27) == 0x2d,
          RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1e, 0x1f], bundleId: "com.openai.codex", bufferActive: true
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1e], bundleId: "com.apple.Terminal", bufferActive: true
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1f], bundleId: "com.openai.codex", bufferActive: false
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x01], bundleId: "com.openai.codex", bufferActive: true
          ) else {
        print("FAILED: buffer control-key escape gate")
        return false
    }
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldDeliver = model.deliver
    let oldOnChange = model.onChange
    defer {
        model.clear()
        model.enabled = oldEnabled
        model.deliver = oldDeliver
        model.onChange = oldOnChange
    }

    model.onChange = nil
    model.deliver = nil
    model.enabled = true
    model.clear()

    var delivered: [String] = []
    model.deliver = { text, _ in
        delivered.append(text)
        return true
    }
    model.append("你")
    model.append("好")
    model.sendAll()
    guard delivered == ["你", "好"], model.blocks.isEmpty, model.enabled == true else {
        print("FAILED: sendAll success should keep buffer mode",
              "delivered=\(delivered)",
              "blocks=\(model.blocks.count)",
              "enabled=\(model.enabled)")
        return false
    }

    model.enabled = true
    model.append("保留")
    model.deliver = { _, _ in false }
    model.sendAll()
    guard model.blocks.count == 1, model.enabled == true else {
        print("FAILED: send failure should preserve state",
              "blocks=\(model.blocks.count)",
              "enabled=\(model.enabled)")
        return false
    }

    model.clear()
    guard model.blocks.isEmpty, model.enabled == true else {
        print("FAILED: clear should not exit buffer mode",
              "blocks=\(model.blocks.count)",
              "enabled=\(model.enabled)")
        return false
    }

    model.append("前")
    model.append("后")
    guard model.removeLastBlock(),
          model.blocks.map(\.text) == ["前"] else {
        print("FAILED: removeLastBlock should drop newest block",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    guard model.removeLastBlock(),
          model.blocks.isEmpty,
          model.removeLastBlock() == false else {
        print("FAILED: removeLastBlock empty semantics",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }

    model.clear()
    model.append("一")
    model.append("三")
    guard model.moveInsertionPoint(delta: -1),
          model.insertionIndex == 1 else {
        print("FAILED: moveInsertionPoint should move left",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    model.append("二")
    guard model.blocks.map(\.text) == ["一", "二", "三"],
          model.insertionIndex == 2 else {
        print("FAILED: append should insert at insertion point",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    _ = model.moveInsertionPoint(delta: 99)
    guard model.insertionIndex == model.blocks.count else {
        print("FAILED: insertion point should clamp to end",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }

    delivered.removeAll()
    model.deliver = { text, _ in
        delivered.append(text)
        return true
    }
    guard model.sendNextBlock(),
          delivered == ["一"],
          model.blocks.map(\.text) == ["二", "三"],
          model.enabled == true else {
        print("FAILED: sendNextBlock should send oldest and keep buffer mode",
              "delivered=\(delivered)",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))",
              "enabled=\(model.enabled)")
        return false
    }

    print("buffer smoke: OK")
    return true
}

func runMarineBridgeSmokeTest() -> Bool {
    print("== ETInput Marine bridge smoke test ==")
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldDeliver = model.deliver
    let oldOnChange = model.onChange
    defer {
        model.clear()
        model.enabled = oldEnabled
        model.deliver = oldDeliver
        model.onChange = oldOnChange
    }

    model.onChange = nil
    model.deliver = nil
    model.clear()

    MarineBridge.shared.checkForFocusedIntent()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let block = model.blocks.first {
            let expected = ProcessInfo.processInfo.environment["MARINE_BRIDGE_SMOKE_EXPECTED"]
            if let expected, !expected.isEmpty, block.text != expected {
                print("FAILED: loaded unexpected draft", "got=\(block.text)", "expected=\(expected)")
                return false
            }
            guard model.active, model.loadingMessage == nil else {
                print("FAILED: draft loaded but buffer state is inconsistent",
                      "active=\(model.active)",
                      "loading=\(model.loadingMessage ?? "nil")")
                return false
            }
            print("loaded draft chars:", block.text.count)
            print("marine bridge smoke: OK")
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    print("FAILED: no Marine draft loaded",
          "loading=\(model.loadingMessage ?? "nil")",
          "active=\(model.active)",
          "blocks=\(model.blocks.count)")
    return false
}

// MARK: - Remote-typing transport smoke (crypto + framing + loopback socket)

func runRemoteSmokeTest() -> Bool {
    print("== ETInput remote-typing smoke test ==")
    print("identity fp:", RemoteIdentity.fingerprint)   // must be stable across launches (Keychain)

    // 1) ECDH session key: two identities derive the SAME key; and AES-GCM
    //    round-trips only under that key.
    let a = Curve25519.KeyAgreement.PrivateKey()
    let b = Curve25519.KeyAgreement.PrivateKey()
    let nA = RemoteCrypto.randomNonce(), nB = RemoteCrypto.randomNonce()
    func derive(_ priv: Curve25519.KeyAgreement.PrivateKey, _ peer: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey {
        let shared = try! priv.sharedSecretFromKeyAgreement(with: peer)
        let salt = nA.lexicographicallyPrecedes(nB) ? nA + nB : nB + nA
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data("etinput-remote-session-v1".utf8), outputByteCount: 32)
    }
    let keyA = derive(a, b.publicKey)
    let keyB = derive(b, a.publicKey)
    let wrong = SymmetricKey(size: .bits256)
    let plain = Data("你好 hello".utf8)
    guard keyA.withUnsafeBytes({ Data($0) }) == keyB.withUnsafeBytes({ Data($0) }),
          let sealed = RemoteCrypto.seal(plain, key: keyA),
          RemoteCrypto.open(sealed, key: keyB) == plain,
          RemoteCrypto.open(sealed, key: wrong) == nil else {
        print("FAILED: ECDH key agreement / AES-GCM"); return false
    }
    print("ECDH + crypto: OK")

    // 2) Framing: plaintext hello + sealed message, streaming reassembly.
    let hello = HelloMessage(deviceID: "A", name: "阿 Mac", pubKey: "cHViaw==", nonce: "bm9uYw==")
    guard let hf = RemoteFrame.encodeHello(hello),
          let sf = RemoteFrame.encodeSealed(.init(kind: .text, seq: 7, text: "世界B"), key: keyA) else {
        print("FAILED: frame encode"); return false
    }
    let dec = RemoteFrame.Decoder()
    var helloOK = false, textOK = false
    for byte in (hf + sf) {
        guard let frames = dec.feed(Data([byte])) else { print("FAILED: decoder dropped"); return false }
        for f in frames {
            switch f.type {
            case .hello:
                if let h = try? JSONDecoder().decode(HelloMessage.self, from: f.payload),
                   h.deviceID == "A", h.name == "阿 Mac" { helloOK = true }
            case .sealed:
                if let j = RemoteCrypto.open(f.payload, key: keyB),
                   let m = try? JSONDecoder().decode(SealedMessage.self, from: j),
                   m.kind == .text, m.seq == 7, m.text == "世界B" { textOK = true }
            }
        }
    }
    guard helloOK, textOK else { print("FAILED: framing hello=\(helloOK) text=\(textOK)"); return false }
    print("framing (hello + sealed, streaming): OK")

    // 3) Loopback transport: real NWListener <- NWConnection over 127.0.0.1.
    let q = DispatchQueue(label: "remote-smoke")
    let listener: NWListener
    do { listener = try NWListener(using: .tcp) } catch { print("FAILED: listener \(error)"); return false }
    let ldec = RemoteFrame.Decoder()
    let recvSem = DispatchSemaphore(value: 0)
    var received: String?
    listener.newConnectionHandler = { conn in
        conn.stateUpdateHandler = { st in
            guard case .ready = st else { return }
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    if let data, !data.isEmpty, let frames = ldec.feed(data) {
                        for f in frames where f.type == .sealed {
                            if let j = RemoteCrypto.open(f.payload, key: keyA),
                               let m = try? JSONDecoder().decode(SealedMessage.self, from: j) {
                                received = m.text; recvSem.signal()
                            }
                        }
                    }
                    if err == nil && !done { loop() }
                }
            }
            loop()
        }
        conn.start(queue: q)
    }
    let portSem = DispatchSemaphore(value: 0)
    var port: NWEndpoint.Port?
    listener.stateUpdateHandler = { st in
        switch st {
        case .ready: port = listener.port; portSem.signal()
        case .failed: portSem.signal()
        default: break
        }
    }
    listener.start(queue: q)
    guard portSem.wait(timeout: .now() + 5) == .success, let port else {
        print("FAILED: listener did not become ready"); listener.cancel(); return false
    }
    let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    conn.stateUpdateHandler = { st in
        guard case .ready = st else { return }
        if let frame = RemoteFrame.encodeSealed(.init(kind: .text, seq: 1, text: "远程你好"), key: keyA) {
            conn.send(content: frame, completion: .idempotent)
        }
    }
    conn.start(queue: q)
    let ok = recvSem.wait(timeout: .now() + 5) == .success
    conn.cancel(); listener.cancel()
    guard ok, received == "远程你好" else {
        print("FAILED: loopback transport received=\(received ?? "nil")"); return false
    }
    print("loopback transport: OK")

    print("remote smoke: OK")
    return true
}
