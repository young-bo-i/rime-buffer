import Foundation
import Network
import CryptoKit

// Snapshots read by the UI on the MAIN thread only (never touch service state
// off the service queue — that was a data race in the first cut).
struct RemotePeer { let id: String; let name: String; let trusted: Bool }
struct RemoteTrusted { let pubB64: String; let name: String }
struct RemoteStatus {
    var enabled = false
    var connectedPeerName: String?
    var discovered: [RemotePeer] = []
    var trusted: [RemoteTrusted] = []
}

/// 隔空传字: send committed text to a paired Mac and receive text from it, over an
/// encrypted local peer-to-peer channel.
///
/// Trust model (AirDrop / KDE-Connect style, NO typed code): discovery is open
/// (Bonjour), but text only flows to/from a peer whose X25519 public key you've
/// accepted. To pair you tap a peer in the menu → the other Mac shows an 同意
/// prompt (with a 4-digit SAS to eyeball) → on accept both remember each other
/// (TOFU) and reconnect silently thereafter. Every frame after the plaintext
/// key-exchange handshake is AES-GCM sealed under an ECDH session key that is
/// freshened per connection (nonces) and carries a monotonic seq (replay-proof).
///
/// All mutable state lives on `queue`; UI reads only `status` (main-thread copy).
final class RemoteTypingService {
    static let shared = RemoteTypingService()
    static let serviceType = "_etinput._tcp"

    /// Main-thread: text typed on the peer Mac.
    var onReceiveText: ((String) -> Void)?
    /// Main-thread: an untrusted peer asks to pair. Show 同意/拒绝 (with the SAS to
    /// eyeball against the other Mac), then call respond.
    var onPairRequest: ((_ peerName: String, _ sas: String, _ respond: @escaping (Bool) -> Void) -> Void)?
    /// Main-thread: WE initiated pairing and the handshake finished — show the SAS
    /// so the user confirms it matches the peer's screen, then proceed to request.
    var onPairConfirm: ((_ peerName: String, _ sas: String, _ proceed: @escaping (Bool) -> Void) -> Void)?
    /// Main-thread: status changed (rebuild menu).
    var onStatusChange: (() -> Void)?

    /// Main-thread snapshot for the UI.
    private(set) var status = RemoteStatus()

    private let queue = DispatchQueue(label: "com.isaac.inputmethod.ETInput.remote")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var running = false

    // Per-connection state (queue only)
    private var connection: NWConnection?
    private var decoder: RemoteFrame.Decoder?
    private var sessionKey: SymmetricKey?
    private var myNonce: Data?
    private var peerPubKey: Data?
    private var peerDeviceName: String?
    private var peerDeviceID: String?
    private var handshakeDone = false
    private var pairingIntent = false        // did WE initiate a pairing to this peer?
    private var pairRequestSent = false      // ...AND the user confirmed the SAS + we sent the request
    private var pairingPeerID: String?       // the peer we're actively pairing with
    private var pairingPeerPub: Data?        // the exact pubkey whose SAS the user confirmed
    private var outgoingPeerID: String?      // id we dialed (nil == we accepted an incoming)
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0
    private var missedTicks = 0
    private var heartbeat: DispatchSourceTimer?
    private var activePeerName: String?      // non-nil == trusted + live (queue side)

    // Discovery (queue only)
    private struct Discovered { let id: String; let name: String; let fp: String; let endpoint: NWEndpoint }
    private var discovered: [String: Discovered] = [:]

    private var pending: [String] = []
    private let pendingCap = 50

    // MARK: - Lifecycle

    func restart() { queue.async { [weak self] in self?.stopLocked(); self?.startLocked() } }
    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    private func startLocked() {
        guard RemoteConfig.enabled else { publishStatus(); return }
        running = true
        _ = RemoteIdentity.privateKey   // ensure identity exists
        startListener()
        startBrowser()
        publishStatus()
        IMELog.write("remote: started (\(RemoteConfig.deviceName) fp=\(RemoteIdentity.fingerprint))")
    }

    private func stopLocked() {
        running = false
        dropConnectionLocked(reconnect: false)
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        discovered.removeAll()
        pending.removeAll()
        publishStatus()
    }

    private var params: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true          // detect half-open links
        tcp.keepaliveIdle = 8
        tcp.keepaliveInterval = 4
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true          // AWDL — works off a shared Wi-Fi (Mac-only)
        return p
    }

    // MARK: - Advertise + discover

    private func startListener() {
        do {
            let l = try NWListener(using: params)
            l.service = NWListener.Service(type: Self.serviceType, txtRecord: NWTXTRecord([
                "id": RemoteConfig.deviceID,
                "name": RemoteConfig.deviceName,
                "fp": RemoteIdentity.fingerprint,
            ]))
            l.newConnectionHandler = { [weak self] conn in self?.adopt(conn, outgoingTo: nil) }
            l.stateUpdateHandler = { if case .failed(let e) = $0 { IMELog.write("remote: listener failed \(e)") } }
            l.start(queue: queue)
            listener = l
        } catch { IMELog.write("remote: listener setup failed \(error)") }
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handleResults(results) }
        b.stateUpdateHandler = { if case .failed(let e) = $0 { IMELog.write("remote: browser failed \(e)") } }
        b.start(queue: queue)
        browser = b
    }

    private func restartBrowser() {
        browser?.cancel()
        startBrowser()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var next: [String: Discovered] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let id = txtValue(txt, "id"), id != RemoteConfig.deviceID else { continue }
            let name = txtValue(txt, "name") ?? "Mac"
            let fp = txtValue(txt, "fp") ?? ""
            next[id] = Discovered(id: id, name: name, fp: fp, endpoint: result.endpoint)
        }
        discovered = next
        publishStatus()

        // Auto-connect ONLY to already-trusted peers (silent reconnect), with the
        // smaller-id-initiates tie-break so we never form two connections.
        guard running, connection == nil else { return }
        for peer in discovered.values where RemoteIdentity.trustedFingerprints.contains(peer.fp) {
            if RemoteConfig.deviceID < peer.id {
                pairingIntent = false; pairingPeerID = nil
                adopt(NWConnection(to: peer.endpoint, using: params), outgoingTo: peer.id)
            }
            return
        }
    }

    private func txtValue(_ txt: NWTXTRecord, _ key: String) -> String? {
        if case .string(let v) = txt.getEntry(for: key) { return v }
        return nil
    }

    // MARK: - Pairing (called from the menu, main thread)

    func requestPair(peerID: String) {
        queue.async { [weak self] in
            guard let self, self.running, let peer = self.discovered[peerID] else { return }
            if self.connection != nil, self.peerDeviceID == peerID, self.handshakeDone {
                self.pairingIntent = true; self.pairingPeerID = peerID
                self.beginInitiatorPairing()
                return
            }
            self.dropConnectionLocked(reconnect: false)
            self.pairingIntent = true
            self.pairingPeerID = peerID
            self.adopt(NWConnection(to: peer.endpoint, using: self.params), outgoingTo: peerID)
        }
    }

    /// WE initiated: show the user the SAS to confirm against the peer's screen,
    /// then (only on confirm) send the pair request. Trust is granted later, when
    /// a *solicited* pairAccept comes back (guarded in handleSealed).
    private func beginInitiatorPairing() {
        guard let peerPub = peerPubKey, let name = peerDeviceName else { return }
        let sas = RemoteIdentity.sas(with: peerPub)
        DispatchQueue.main.async { [weak self] in
            self?.onPairConfirm?(name, sas) { proceed in
                self?.queue.async {
                    // Bind the confirmation to the EXACT pubkey whose SAS we showed
                    // (peerPub captured above), not to the attacker-settable deviceID —
                    // if a dueling-yield swapped the live connection during the modal,
                    // peerPubKey no longer matches and we refuse.
                    guard let self, self.connection != nil, self.pairingIntent,
                          self.peerPubKey == peerPub else { return }
                    if proceed {
                        // User confirmed the SAS — only NOW may a pairAccept from THIS
                        // pubkey be trusted (guarded in handleSealed).
                        self.pairRequestSent = true
                        self.pairingPeerPub = peerPub
                        self.sendSealed(.init(kind: .pairRequest, seq: self.nextSeq(), text: nil))
                    } else {
                        self.dropConnectionLocked(reconnect: false)
                    }
                }
            }
        }
    }

    func unpair(pubB64: String) {
        queue.async { [weak self] in
            RemoteIdentity.untrust(pubB64: pubB64)
            if let cur = self?.peerPubKey?.base64EncodedString(), cur == pubB64 {
                self?.dropConnectionLocked(reconnect: false)
            }
            self?.publishStatus()
        }
    }

    // MARK: - Connection

    private func adopt(_ conn: NWConnection, outgoingTo: String?) {
        guard running else { conn.cancel(); return }
        if connection != nil {
            // Deterministic dueling-connection resolution: the peer with the
            // SMALLER deviceID is the canonical initiator. If we (larger id) had
            // dialed out and now receive an incoming, yield to it; otherwise keep
            // our connection and drop the newcomer. Prevents the both-cancel
            // deadlock when two Macs request pairing simultaneously.
            if outgoingTo == nil, let out = outgoingPeerID, RemoteConfig.deviceID > out {
                resetConnectionState()
            } else {
                conn.cancel(); return
            }
        }
        outgoingPeerID = outgoingTo
        connection = conn
        decoder = RemoteFrame.Decoder()
        sessionKey = nil; handshakeDone = false; myNonce = nil
        peerPubKey = nil; peerDeviceName = nil; peerDeviceID = nil
        sendSeq = 0; recvSeq = 0; missedTicks = 0
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHello()
                self.startHeartbeat()
                self.receiveLoop(conn)
            case .failed(let e): IMELog.write("remote: connection failed \(e)"); self.dropConnectionLocked(reconnect: true)
            case .cancelled: break
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Tear down just the connection (keeps pairing intent + active-peer state).
    private func resetConnectionState() {
        heartbeat?.cancel(); heartbeat = nil
        connection?.cancel(); connection = nil
        decoder = nil; sessionKey = nil; handshakeDone = false; myNonce = nil
        peerPubKey = nil; peerDeviceName = nil; peerDeviceID = nil; outgoingPeerID = nil
        sendSeq = 0; recvSeq = 0; missedTicks = 0
        pairRequestSent = false   // a fresh connection must re-confirm the SAS
    }

    private func dropConnectionLocked(reconnect: Bool) {
        resetConnectionState()
        pairingIntent = false; pairingPeerID = nil; pairingPeerPub = nil
        if activePeerName != nil { activePeerName = nil; publishStatus() }
        guard reconnect, running else { return }
        // Fresh discovery re-triggers auto-connect to trusted peers.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }
            self.restartBrowser()
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                guard let frames = self.decoder?.feed(data) else {
                    IMELog.write("remote: bad framing — dropping"); self.dropConnectionLocked(reconnect: true); return
                }
                for f in frames { self.handleFrame(f) }
            }
            if let error { IMELog.write("remote: receive error \(error)"); self.dropConnectionLocked(reconnect: true); return }
            if isComplete { self.dropConnectionLocked(reconnect: true); return }
            if self.connection === conn { self.receiveLoop(conn) }
        }
    }

    private func handleFrame(_ f: RawFrame) {
        missedTicks = 0
        switch f.type {
        case .hello:
            guard !handshakeDone,
                  let hello = try? JSONDecoder().decode(HelloMessage.self, from: f.payload),
                  let peerPub = Data(base64Encoded: hello.pubKey),
                  let peerNonce = Data(base64Encoded: hello.nonce),
                  let mine = myNonce,
                  let sk = RemoteIdentity.sessionKey(peerPub: peerPub, nonceA: mine, nonceB: peerNonce) else {
                IMELog.write("remote: bad hello — dropping"); dropConnectionLocked(reconnect: false); return
            }
            peerPubKey = peerPub; peerDeviceName = hello.name; peerDeviceID = hello.deviceID
            sessionKey = sk; handshakeDone = true; recvSeq = 0
            onHandshakeComplete()
        case .sealed:
            guard let sk = sessionKey, let json = RemoteCrypto.open(f.payload, key: sk),
                  let msg = try? JSONDecoder().decode(SealedMessage.self, from: json) else {
                IMELog.write("remote: undecryptable/premature sealed frame — dropping")
                dropConnectionLocked(reconnect: false); return
            }
            guard msg.seq > recvSeq else { return }   // replay / out-of-order → ignore frame
            recvSeq = msg.seq
            handleSealed(msg)
        }
    }

    private func onHandshakeComplete() {
        guard let peerPub = peerPubKey else { return }
        if RemoteIdentity.isTrusted(pub: peerPub) {
            activePeerName = peerDeviceName
            flushPending()
            publishStatus()
            IMELog.write("remote: connected + trusted \(peerDeviceName ?? "?")")
        } else if pairingIntent, peerDeviceID == pairingPeerID {
            beginInitiatorPairing()   // WE dialed this peer to pair: confirm SAS first
        } else {
            IMELog.write("remote: untrusted peer \(peerDeviceName ?? "?") connected; awaiting its pair request")
        }
    }

    private func handleSealed(_ msg: SealedMessage) {
        guard let peerPub = peerPubKey else { return }
        switch msg.kind {
        case .text:
            guard RemoteIdentity.isTrusted(pub: peerPub), let text = msg.text, !text.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onReceiveText?(text) }
        case .pairRequest:
            if RemoteIdentity.isTrusted(pub: peerPub) {
                sendSealed(.init(kind: .pairAccept, seq: nextSeq(), text: nil))
                activePeerName = peerDeviceName; flushPending(); publishStatus()
            } else {
                let name = peerDeviceName ?? "对方 Mac"
                let sas = RemoteIdentity.sas(with: peerPub)
                DispatchQueue.main.async { [weak self] in
                    self?.onPairRequest?(name, sas) { accept in
                        self?.queue.async { self?.resolveIncomingPair(accept: accept, peerPub: peerPub, name: name) }
                    }
                }
            }
        case .pairAccept:
            // CRITICAL: only trust a pairAccept we actually SOLICITED — we initiated
            // pairing to THIS peer AND the user confirmed the SAS (pairRequestSent,
            // set only in the onPairConfirm proceed branch). Guarding on pairingIntent
            // alone is not enough: it's set before the async SAS modal, so an attacker
            // could race an unsolicited pairAccept in and self-trust before the user
            // ever sees/confirms the code.
            guard pairingIntent, pairRequestSent, let confirmed = pairingPeerPub,
                  peerPubKey == confirmed else {
                IMELog.write("remote: unsolicited/unconfirmed pairAccept ignored")
                return
            }
            pairingIntent = false; pairRequestSent = false; pairingPeerID = nil; pairingPeerPub = nil
            RemoteIdentity.trust(pub: peerPub, name: peerDeviceName ?? "Mac")
            activePeerName = peerDeviceName; flushPending(); publishStatus()
            IMELog.write("remote: peer accepted — paired with \(peerDeviceName ?? "?")")
        case .pairReject:
            pairingIntent = false; pairRequestSent = false; pairingPeerID = nil; pairingPeerPub = nil
            IMELog.write("remote: peer rejected pairing")
            publishStatus()
        case .heartbeat:
            break
        }
    }

    private func resolveIncomingPair(accept: Bool, peerPub: Data, name: String) {
        guard connection != nil, peerPubKey == peerPub else { return }   // peer may have changed
        if accept {
            RemoteIdentity.trust(pub: peerPub, name: name)
            sendSealed(.init(kind: .pairAccept, seq: nextSeq(), text: nil))
            activePeerName = name; flushPending(); publishStatus()
            IMELog.write("remote: accepted pairing with \(name)")
        } else {
            sendSealed(.init(kind: .pairReject, seq: nextSeq(), text: nil))
            IMELog.write("remote: rejected pairing with \(name)")
        }
    }

    // MARK: - Sending

    func send(_ text: String) {
        guard !text.isEmpty, RemoteConfig.enabled else { return }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if self.handshakeDone, let pub = self.peerPubKey, RemoteIdentity.isTrusted(pub: pub) {
                self.sendSealed(.init(kind: .text, seq: self.nextSeq(), text: text))
            } else {
                if self.pending.count >= self.pendingCap { self.pending.removeFirst() }
                self.pending.append(text)
            }
        }
    }

    private func flushPending() {
        guard handshakeDone, let pub = peerPubKey, RemoteIdentity.isTrusted(pub: pub) else { return }
        let queued = pending; pending.removeAll()
        for t in queued { sendSealed(.init(kind: .text, seq: nextSeq(), text: t)) }
    }

    private func sendHello() {
        let nonce = RemoteCrypto.randomNonce()
        myNonce = nonce
        let hello = HelloMessage(deviceID: RemoteConfig.deviceID, name: RemoteConfig.deviceName,
                                 pubKey: RemoteIdentity.publicKeyB64, nonce: nonce.base64EncodedString())
        guard let conn = connection, let frame = RemoteFrame.encodeHello(hello) else { return }
        conn.send(content: frame, completion: .idempotent)
    }

    private func sendSealed(_ m: SealedMessage) {
        guard let conn = connection, let sk = sessionKey,
              let frame = RemoteFrame.encodeSealed(m, key: sk) else { return }
        conn.send(content: frame, completion: .idempotent)
    }

    private func nextSeq() -> UInt64 { sendSeq += 1; return sendSeq }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.connection != nil else { return }
            self.missedTicks += 1
            if self.missedTicks >= 3 { IMELog.write("remote: peer idle — dropping"); self.dropConnectionLocked(reconnect: true); return }
            if self.handshakeDone { self.sendSealed(.init(kind: .heartbeat, seq: self.nextSeq(), text: nil)) }
        }
        t.resume()
        heartbeat = t
    }

    // MARK: - Status (published to main)

    private func publishStatus() {
        let enabled = RemoteConfig.enabled
        let peerName = activePeerName
        let trustedFPs = RemoteIdentity.trustedFingerprints
        let disc = discovered.values
            .map { RemotePeer(id: $0.id, name: $0.name, trusted: trustedFPs.contains($0.fp)) }
            .sorted { $0.name < $1.name }
        let trusted = RemoteIdentity.trustedPeers
            .map { RemoteTrusted(pubB64: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in
            self?.status = RemoteStatus(enabled: enabled, connectedPeerName: peerName,
                                        discovered: disc, trusted: trusted)
            self?.onStatusChange?()
        }
    }

    /// One-line status for the menu (main thread).
    var statusSummary: String {
        if !status.enabled { return "已关闭" }
        if let peer = status.connectedPeerName { return "已连接：\(peer)" }
        if status.trusted.isEmpty { return "未配对（点下方设备配对）" }
        return "搜索已配对设备…"
    }
}
