import Cocoa
import InputMethodKit

// `swift run RimeBuffer smoke` validates the engine end-to-end without IMK.
if CommandLine.arguments.contains("stats-smoke") {
    exit(runStatsSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("buffer-smoke") {
    exit(runBufferSmokeTest() ? 0 : 1)
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
candidateWindow.onPage = { delta in
    RimeBufferController.active?.pageCandidates(delta: delta)
}
candidateWindow.onSettings = {
    SettingsWindowController.shared.show()
}

// Buffer wiring: flushes deliver to the focused field; every model change
// re-renders the inline buffer that lives inside the candidate window.
BufferModel.shared.deliver = { text in
    RimeBufferController.deliverBufferedText(text)
}
BufferModel.shared.onChange = {
    RimeBufferController.refreshBufferDisplayForCurrentOrRecent()
}
candidateWindow.refreshBuffer()

// Menu-bar entry (schema switching / health / log) + a safety net that hides a
// stray candidate panel when the user switches apps mid-composition.
StatusMenu.shared.install()
StatusMenu.shared.setHealthy(rimeEngine.isHealthy)

// Auto-update: silently check GitHub Releases on launch + hourly, download in the
// background, and surface a one-click install in the status menu when ready.
UpdateManager.shared.startPeriodicUpdateCheck()
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

func runBufferSmokeTest() -> Bool {
    print("== RimeBuffer buffer smoke test ==")
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
    model.deliver = { text in
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
    model.deliver = { _ in false }
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
    model.deliver = { text in
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
