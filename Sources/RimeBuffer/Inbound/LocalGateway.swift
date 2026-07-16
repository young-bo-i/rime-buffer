import Foundation
import Network

/// Loopback-only HTTP server carrying MCP (streamable HTTP) + plain HTTP push,
/// feeding InboundBus. The hand-written HTTP/1.1 parsing was validated by the
/// M2 spike (real Claude Code connected, SSE streamed, keep-alive held).
///
/// Security: binds 127.0.0.1 only; every endpoint except /health requires the
/// bearer token; strict line/size limits on the parser. Runs on a background
/// queue; all InboundBus/BufferModel calls hop to the main thread.
final class LocalGateway {
    static let shared = LocalGateway()

    static let defaultPort: UInt16 = 47700
    private static let maxHeaderBytes = 32 * 1024
    private static let maxBodyBytes = 256 * 1024

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "etinput.gateway")
    private var connections: [ObjectIdentifier: Connection] = [:]
    private(set) var running = false

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "gatewayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gatewayEnabled"); newValue ? start() : stop() }
    }
    var port: UInt16 {
        let v = UserDefaults.standard.integer(forKey: "gatewayPort")
        return v > 0 ? UInt16(v) : Self.defaultPort
    }

    func startIfEnabled() { if enabled { start() } }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        // Bind loopback only — never reachable off-box.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            IMELog.write("gateway: cannot bind 127.0.0.1:\(port)")
            return
        }
        l.newConnectionHandler = { [weak self] nw in
            guard let self else { nw.cancel(); return }
            let c = Connection(nw) { [weak self] in self?.drop($0) }
            self.connections[ObjectIdentifier(c)] = c   // retain (spike caught this bug)
            c.start(on: self.queue)
        }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.running = true; IMELog.write("gateway ready on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let e): IMELog.write("gateway listener failed: \(e)"); self?.stop()
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        running = false
    }

    private func drop(_ c: Connection) { queue.async { self.connections[ObjectIdentifier(c)] = nil } }

    // MARK: - one connection

    private final class Connection {
        private let conn: NWConnection
        private let onClose: (Connection) -> Void
        private var buffer = Data()
        // Each MCP session gets a server-issued id + the client's self-reported
        // (unverified) name, used only for the source label.
        private var mcpSessionID = ""
        private var mcpClientName = "MCP"

        init(_ c: NWConnection, onClose: @escaping (Connection) -> Void) {
            conn = c; self.onClose = onClose
        }

        func start(on queue: DispatchQueue) {
            conn.stateUpdateHandler = { [weak self] st in
                if case .failed = st { self?.close() }
                if case .cancelled = st { self.map { $0.onClose($0) } }
            }
            conn.start(queue: queue)
            receive()
        }

        func cancel() { conn.cancel() }
        private func close() { conn.cancel() }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    if self.buffer.count > LocalGateway.maxHeaderBytes + LocalGateway.maxBodyBytes {
                        self.close(); return
                    }
                    self.drain()
                }
                if isDone || err != nil { self.close(); return }
                self.receive()
            }
        }

        private func drain() {
            while let (req, consumed) = parse(buffer) {
                buffer.removeSubrange(0..<consumed)
                handle(req)
                if (req.headers["connection"] ?? "").lowercased() == "close" { return }
            }
        }

        // MARK: HTTP parse

        private struct Req { var method = "", path = ""; var headers: [String: String] = [:]; var body = Data() }

        private func parse(_ data: Data) -> (Req, Int)? {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                return nil  // header terminator not in yet; receive() caps total buffer size
            }
            guard let headerStr = String(data: data.subdata(in: 0..<end.lowerBound), encoding: .utf8) else { return nil }
            var lines = headerStr.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let start = lines.removeFirst().split(separator: " ")
            guard start.count == 3 else { return nil }
            var req = Req(); req.method = String(start[0]); req.path = String(start[1])
            for line in lines {
                guard let c = line.firstIndex(of: ":") else { continue }
                req.headers[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = end.upperBound
            let len = min(Int(req.headers["content-length"] ?? "0") ?? 0, LocalGateway.maxBodyBytes)
            guard data.count - bodyStart >= len else { return nil }
            req.body = data.subdata(in: bodyStart..<(bodyStart + len))
            return (req, bodyStart + len)
        }

        // MARK: responses

        private func send(_ status: String, headers: [String: String] = [:], body: Data = Data()) {
            var h = headers
            h["Content-Length"] = "\(body.count)"; h["Connection"] = "keep-alive"
            var head = "HTTP/1.1 \(status)\r\n"
            for (k, v) in h { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in })
        }

        private func json(_ obj: Any, status: String = "200 OK", session: String? = nil) {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            var h = ["Content-Type": "application/json"]
            if let session { h["Mcp-Session-Id"] = session }
            send(status, headers: h, body: data)
        }

        // MARK: routing

        private func handle(_ req: Req) {
            let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
            if req.method == "GET", path == "/v1/health" { json(["ok": true]); return }
            // Spec MUST: reject cross-origin browsers (DNS-rebinding defence). Real
            // MCP agents are not browsers and omit Origin, so they pass through.
            guard originAllowed(req) else {
                json(["error": "forbidden origin"], status: "403 Forbidden"); return
            }
            guard let auth = req.headers["authorization"], auth.hasPrefix("Bearer "),
                  GatewayToken.matches(String(auth.dropFirst(7))) else {
                json(["error": "unauthorized"], status: "401 Unauthorized"); return
            }
            switch (req.method, path) {
            case ("POST", "/v1/inbound"): handleInbound(req)
            case ("POST", "/mcp"): handleMCP(req)
            // Streamable HTTP: we push no server-initiated messages, so per spec the
            // GET SSE stream is declined with 405 (clients treat this as "no stream").
            case ("GET", "/mcp"): send("405 Method Not Allowed", headers: ["Allow": "POST, DELETE"])
            // Session teardown — we hold no per-session state, so just acknowledge.
            case ("DELETE", "/mcp"): mcpSessionID = ""; send("200 OK")
            default: json(["error": "not found"], status: "404 Not Found")
            }
        }

        /// Origin is absent for CLI/agent clients (allowed). A browser attacker
        /// reaching the loopback port would carry a non-local Origin — rejected.
        private func originAllowed(_ req: Req) -> Bool {
            guard let origin = req.headers["origin"], !origin.isEmpty else { return true }
            let o = origin.lowercased()
            return o == "null"
                || o.hasPrefix("http://localhost") || o.hasPrefix("https://localhost")
                || o.hasPrefix("http://127.0.0.1") || o.hasPrefix("https://127.0.0.1")
                || o.hasPrefix("http://[::1]") || o.hasPrefix("https://[::1]")
        }

        private func handleInbound(_ req: Req) {
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String else {
                json(["error": "bad request"], status: "400 Bad Request"); return
            }
            let source = obj["source"] as? String ?? "http"
            let title = obj["title"] as? String
            DispatchQueue.main.async {
                InboundBus.shared.submit(origin: .http(source: source), text: text, title: title)
            }
            json(["accepted": true])
        }

        // MCP Streamable HTTP, protocol rev 2025-06-18 (negotiates down to older
        // clients). Single JSON response per POST — no server-initiated stream.
        private func handleMCP(_ req: Req) {
            guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                json(["jsonrpc": "2.0", "error": ["code": -32700, "message": "parse error"], "id": NSNull()],
                     status: "400 Bad Request"); return
            }
            let method = msg["method"] as? String ?? ""
            let id = msg["id"] ?? NSNull()
            // A message with no id is a notification/response → 202 Accepted, no body.
            let isNotification = msg["id"] == nil

            // Spec MUST: after initialization the client sends MCP-Protocol-Version;
            // an unsupported value is a 400. A missing header stays lenient (assume
            // the negotiated version) so simpler clients keep working.
            if method != "initialize",
               let pv = req.headers["mcp-protocol-version"],
               !Self.supportedProtocolVersions.contains(pv) {
                json(["jsonrpc": "2.0", "id": id,
                      "error": ["code": -32600, "message": "unsupported MCP-Protocol-Version: \(pv)"]],
                     status: "400 Bad Request")
                return
            }

            switch method {
            case "initialize":
                mcpSessionID = "s-" + UUID().uuidString   // visible-ASCII, unique per spec
                let params = msg["params"] as? [String: Any]
                if let ci = params?["clientInfo"] as? [String: Any],
                   let name = ci["name"] as? String { mcpClientName = name }
                // Version negotiation: echo the client's version if we speak it,
                // otherwise offer our latest and let the client decide.
                let requested = params?["protocolVersion"] as? String ?? ""
                let chosen = Self.supportedProtocolVersions.contains(requested)
                    ? requested : Self.latestProtocolVersion
                json(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": chosen,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "Enter输入法", "title": "Enter输入法 缓冲区", "version": "1"],
                    "instructions": "把文字送进用户输入法的缓冲区收件箱，等用户确认后由用户上屏。"
                        + "只进不出：无法读取缓冲区，也不会自动上屏。",
                ]], session: mcpSessionID)
            case "notifications/initialized":
                send("202 Accepted")
            case "ping":
                json(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            case "tools/list":
                json(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.toolList]])
            case "tools/call":
                handleToolCall(msg, id: id)
            default:
                if isNotification { send("202 Accepted") }
                else { json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]) }
            }
        }

        private func handleToolCall(_ msg: [String: Any], id: Any) {
            let params = msg["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let args = params?["arguments"] as? [String: Any] ?? [:]
            let client = mcpClientName
            func ok(_ text: String) {
                json(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]]]])
            }
            switch name {
            case "buffer_push":
                let text = args["text"] as? String ?? ""
                let title = args["title"] as? String ?? args["kind"] as? String
                DispatchQueue.main.async {
                    InboundBus.shared.submit(origin: .mcp(client: client), text: text, title: title)
                }
                ok("queued \(text.count) chars into the buffer inbox")
            case "buffer_stream_begin":
                let sid = "st-" + UUID().uuidString.prefix(8)
                let title = args["title"] as? String
                DispatchQueue.main.async {
                    InboundBus.shared.beginStream(origin: .mcp(client: client), streamID: sid, title: title)
                }
                json(["jsonrpc": "2.0", "id": id, "result": [
                    "content": [["type": "text", "text": "stream \(sid) open"]],
                    "structuredContent": ["stream_id": sid]]])
            case "buffer_stream_append":
                if let sid = args["stream_id"] as? String, let delta = args["delta"] as? String {
                    DispatchQueue.main.async { InboundBus.shared.appendStream(streamID: sid, delta: delta) }
                }
                ok("appended")
            case "buffer_stream_end":
                if let sid = args["stream_id"] as? String {
                    DispatchQueue.main.async { InboundBus.shared.endStream(streamID: sid) }
                }
                ok("stream closed")
            default:
                json(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "unknown tool"]])
            }
        }

        // Protocol revisions we can speak, newest first. `initialize` negotiates
        // one of these; anything else on MCP-Protocol-Version is a 400.
        private static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
        private static let latestProtocolVersion = "2025-06-18"

        // Give-only tools: an agent can push, never read the buffer or deliver.
        // `readOnlyHint: false` (they mutate the inbox) + no destructive/open-world
        // effects — the annotations any 2025-06-18 client can surface to the user.
        private static let toolList: [[String: Any]] = [
            ["name": "buffer_push",
             "title": "送入缓冲区",
             "description": "把一段文字送进 Enter输入法 的缓冲区收件箱，等用户确认后上屏。不会自动上屏。",
             "inputSchema": ["type": "object",
                             "properties": ["text": ["type": "string", "description": "要送入的文字"],
                                            "title": ["type": "string", "description": "可选来源标题"]],
                             "required": ["text"]],
             "annotations": ["title": "送入缓冲区", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]],
            ["name": "buffer_stream_begin",
             "title": "开始流式条目",
             "description": "开一个流式条目，返回 stream_id。",
             "inputSchema": ["type": "object", "properties": ["title": ["type": "string"]]],
             "annotations": ["title": "开始流式条目", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]],
            ["name": "buffer_stream_append",
             "title": "追加流式内容",
             "description": "向流式条目追加文字（原位更新，不产生新条目）。",
             "inputSchema": ["type": "object",
                             "properties": ["stream_id": ["type": "string"], "delta": ["type": "string"]],
                             "required": ["stream_id", "delta"]],
             "annotations": ["title": "追加流式内容", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]],
            ["name": "buffer_stream_end",
             "title": "结束流式条目",
             "description": "结束流式条目，使其可被接受。",
             "inputSchema": ["type": "object", "properties": ["stream_id": ["type": "string"]],
                             "required": ["stream_id"]],
             "annotations": ["title": "结束流式条目", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]],
        ]
    }
}
