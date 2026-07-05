import Cocoa
import InputMethodKit

// `swift run RimeBuffer smoke` validates the engine end-to-end without IMK.
if CommandLine.arguments.contains("stats-smoke") {
    exit(runStatsSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("smoke") {
    runEngineSmokeTest()
    exit(0)
}

// IMK bootstrap. The connection name MUST match Info.plist; IMK finds our
// controller via InputMethodServerControllerClass = RimeBufferController.
IMELog.reset("=== RimeBuffer IME launch ===")
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
candidateWindow.onSelect = { index in
    RimeBufferController.active?.selectCandidate(onPage: index)
}
candidateWindow.onSettings = {
    SettingsWindowController.shared.show()
}

// Buffer wiring: flushes deliver to the focused field; every model change
// re-renders the staging strip.
BufferModel.shared.deliver = { text in
    RimeBufferController.active?.deliverText(text) ?? false
}
BufferSurface.shared.shouldSuppress = {
    candidateWindow.isShowingInlineBuffer
}
candidateWindow.onInlineBufferVisibilityChanged = {
    BufferSurface.shared.refresh()
}
BufferModel.shared.onChange = {
    candidateWindow.refreshBuffer()
    BufferSurface.shared.refresh()
}
candidateWindow.refreshBuffer()
BufferSurface.shared.refresh()   // restore visibility if buffer mode was left ON

// Menu-bar entry (schema switching / health / log) + a safety net that hides a
// stray candidate panel when the user switches apps mid-composition.
StatusMenu.shared.install()
StatusMenu.shared.setHealthy(rimeEngine.isHealthy)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in
    // Hostile apps may never deliver deactivateServer on Cmd-Tab — resolve
    // any in-flight chord/composition into its field instead of stranding
    // marked text. No-op when the switch was already handled normally.
    RimeBufferController.active?.forceCommit()
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

// MARK: - Engine smoke harness (bring-up only)

func runEngineSmokeTest() {
    let engine = RimeEngine()
    print("== RimeBuffer engine smoke test ==")
    let ok = engine.start()
    print("start:", ok, "healthy:", engine.isHealthy)
    guard ok, engine.isHealthy else { print("lastError:", engine.lastError()); return }

    let session = engine.createSession()
    print("session:", session)
    guard session != 0 else { print("no session"); return }

    let defaultStatus = engine.getStatus(session: session)
    print("default schema: \(defaultStatus.schemaId) (\(defaultStatus.schemaName))")

    let picked = engine.selectSchema("my_serial", session: session)
    let afterSelect = engine.getStatus(session: session)
    print("select my_serial:", picked, "-> schema now:", afterSelect.schemaId, "ascii:", afterSelect.asciiMode)
    engine.setOption("ascii_mode", false, session: session)
    engine.clearComposition(session: session)

    print("typing 'nihao' ...")
    for scalar in "nihao".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: session)
    }
    let ctx = engine.getContext(session: session)
    print("active=\(ctx.active) preedit='\(ctx.preedit)' page=\(ctx.pageNo) cands=\(ctx.candidates.count)")
    for c in ctx.candidates {
        print("  [\(c.label)] \(c.text)\(c.comment.isEmpty ? "" : "  · \(c.comment)")")
    }
    _ = engine.processKey(0x20, session: session)
    print("committed:", engine.takeCommit(session: session) ?? "(none)")
    engine.destroySession(session)
    print("== done ==")
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
