import Foundation

/// Optional bridge to Marine's local API. Marine owns page/comment context; the
/// input method only stages the latest generated draft in its native buffer.
final class MarineBridge {
    static let shared = MarineBridge()

    private struct RuntimeConfig: Decodable {
        let apiBase: String
        let token: String
        let updatedAt: TimeInterval?
    }

    private struct BufferState: Decodable {
        let requestId: String
        let status: String
        let platform: String?
        let mode: String?
        let drafts: [Draft]
        let error: String?
        let updatedAt: TimeInterval
    }

    private struct Draft: Decodable {
        let kind: String?
        let text: String
    }

    private var loadedRequestIds = Set<String>()
    private var pollingRequestId: String?
    private var pollAttempts = 0
    private var pollScheduled = false
    private var lastConfigMissLoggedAt: TimeInterval = 0

    func checkForFocusedIntent() {
        fetchLatest()
        // The extension publishes the focus intent asynchronously from the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.fetchLatest()
        }
    }

    private func fetchLatest() {
        guard let config = runtimeConfig() else { return }
        guard let url = URL(string: config.apiBase + "/buffer-state/latest") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                IMELog.write("marine bridge fetch failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                IMELog.write("marine bridge fetch status=\(code)")
                return
            }
            do {
                let state = try JSONDecoder().decode(BufferState.self, from: data)
                DispatchQueue.main.async { self.handle(state) }
            } catch {
                IMELog.write("marine bridge decode failed: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func handle(_ state: BufferState) {
        guard state.platform == "bilibili" else { return }
        guard !state.requestId.isEmpty else { return }
        guard Date().timeIntervalSince1970 - state.updatedAt <= 180 else { return }

        switch state.status {
        case "generating":
            let message = state.mode == "reply" ? "Marine 正在生成回复…" : "Marine 正在生成直评…"
            BufferModel.shared.beginTransientLoading(requestId: state.requestId, message: message)
            startPolling(requestId: state.requestId)
        case "ready":
            pollingRequestId = nil
            pollScheduled = false
            guard !loadedRequestIds.contains(state.requestId) else { return }
            guard let draft = state.drafts.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                BufferModel.shared.failTransientLoading(requestId: state.requestId, message: "Marine 没有返回话术")
                return
            }
            loadedRequestIds.insert(state.requestId)
            BufferModel.shared.appendMarineDraft(draft.text, requestId: state.requestId)
        case "error":
            pollingRequestId = nil
            pollScheduled = false
            BufferModel.shared.failTransientLoading(
                requestId: state.requestId,
                message: state.error ?? "Marine 生成失败"
            )
        default:
            break
        }
    }

    private func startPolling(requestId: String) {
        if pollingRequestId != requestId {
            pollingRequestId = requestId
            pollAttempts = 0
            pollScheduled = false
        }
        schedulePoll()
    }

    private func schedulePoll() {
        guard !pollScheduled, pollingRequestId != nil, pollAttempts < 30 else { return }
        pollScheduled = true
        pollAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.pollScheduled = false
            self.fetchLatest()
        }
    }

    private func runtimeConfig() -> RuntimeConfig? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MARINE_ETINPUT_RUNTIME_CONFIG"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Marine/etinput-runtime.json"))
            candidates.append(support.appendingPathComponent("MarineDev/etinput-runtime.json"))
        }

        for url in candidates where fm.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let config = try JSONDecoder().decode(RuntimeConfig.self, from: data)
                guard !config.apiBase.isEmpty, !config.token.isEmpty else { continue }
                return config
            } catch {
                IMELog.write("marine bridge config read failed \(url.path): \(error.localizedDescription)")
            }
        }

        let now = Date().timeIntervalSince1970
        if now - lastConfigMissLoggedAt > 30 {
            IMELog.write("marine bridge config not found")
            lastConfigMissLoggedAt = now
        }
        return nil
    }
}
