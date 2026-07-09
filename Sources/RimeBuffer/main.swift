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
if CommandLine.arguments.contains("remote-smoke") {
    exit(runRemoteSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("smoke") {
    runEngineSmokeTest()
    exit(0)
}

// Self-install into the input-source list. TIS enable/select only persist when
// run INSIDE the login (Aqua) session — a detached CLI's writes return success
// but never land. So the installer / build script launches THIS bundle in the
// user session (`open -n ETInput.app --args --install`) to register + enable +
// select itself, exactly like Squirrel's --install. Runs before the IMK server
// so this short-lived instance never contends for the connection.
if CommandLine.arguments.contains("--install") {
    installInputSource()
    exit(0)
}

// IMK bootstrap. The connection name MUST match Info.plist; IMK finds our
// controller via InputMethodServerControllerClass = RimeBufferController.
IMELog.reset("=== 恩特输入法 (ETInput) IME launch ===")
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "ETInput_1_Connection"

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

// No standalone menu-bar icon: all features live in the SYSTEM input menu via
// RimeBufferController.menu() (StatusMenu.populate builds it). setHealthy still
// feeds the health line shown at the top of that menu.
StatusMenu.shared.setHealthy(rimeEngine.isHealthy)

// Auto-update: silently check GitHub Releases on launch + hourly, download in the
// background, and surface a one-click install in the status menu when ready.
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
RemoteTypingService.shared.restart()   // starts only if enabled
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

// MARK: - Input-source self-install (register + enable + select)

/// Registers this bundle's path with TIS, then enables + selects our input mode.
/// Must run inside the login session (see call site). Mirrors Squirrel's
/// RegisterInputSource + ActivateInputSource.
func installInputSource() {
    let modeID = "com.isaac.inputmethod.ETInput.Hans"
    // Register THIS bundle's URL so the input-source id resolves to this exact
    // copy (kills the "duplicate id at multiple paths → blank row" problem).
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("install: register \(Bundle.main.bundleURL.path) -> \(status)")
    guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else {
        print("install: no input source list"); return
    }
    let list = cf as! [TISInputSource]
    var done = false
    for src in list {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
        let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        if id == modeID {
            let e = TISEnableInputSource(src)
            let s = TISSelectInputSource(src)
            print("install: enable=\(e) select=\(s) \(id)")
            done = true
        }
    }
    if !done { print("install: mode \(modeID) not found in TIS list") }
}

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

    // Candidate test on the DEFAULT deployed schema — this is the one a
    // self-contained (default-only) build always ships, so it proves the
    // bundled librime + SharedSupport actually produce input end-to-end.
    engine.setOption("ascii_mode", false, session: session)
    engine.clearComposition(session: session)
    print("typing 'nihao' on \(defaultStatus.schemaId) ...")
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

    // Informational: schema switch only does something if that schema is
    // installed (the custom 并击 schemas aren't part of a default-only build).
    let picked = engine.selectSchema("my_serial", session: session)
    print("select my_serial:", picked, "-> schema now:", engine.getStatus(session: session).schemaId)
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
