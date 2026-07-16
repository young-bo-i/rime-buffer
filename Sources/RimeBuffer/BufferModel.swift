import Foundation

/// The staging buffer (P2): with buffer mode ON, every Rime commit becomes a
/// block here instead of going to the field. Blocks stay queued until the user
/// explicitly flushes them; automatic flushing is intentionally disabled until
/// delivery can be acknowledged more strongly than "an IMK client object exists".
///
/// Rewritten from scratch (append-only, boundaries known at insert time) — the
/// old buffer-bar's diff/reconcile machinery is deliberately absent.
final class BufferModel {
    static let shared = BufferModel()

    struct Block {
        let id = UUID()
        let text: String
        let createdAt = Date()
    }

    private(set) var blocks: [Block] = []
    private(set) var insertionIndex = 0
    private(set) var transientEnabled = false
    private(set) var loadingMessage: String?
    private(set) var loadingRequestId: String?

    var stagedText: String {
        blocks.map(\.text).joined()
    }

    var stagedCharacterCount: Int {
        stagedText.count
    }

    var shouldDisplay: Bool {
        active || !blocks.isEmpty || loadingMessage != nil
    }

    var active: Bool {
        enabled || transientEnabled
    }

    /// Wired in main.swift → active controller's client. Returns false when no
    /// client is available (block stays queued and retries).
    var deliver: ((String) -> Bool)?
    /// Wired to the candidate-window buffer UI.
    var onChange: (() -> Void)?
    /// Set by the controller around composition state. Future automatic flush or
    /// edit-mode operations must still respect it.
    var compositionActive = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "bufferEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "bufferEnabled")
            if !newValue, !blocks.isEmpty {
                IMELog.write("buffer mode off; preserving \(blocks.count) queued blocks")
            }
            onChange?()
        }
    }

    /// Clear staged blocks when focus leaves for another application, so buffer
    /// content can't linger across app boundaries. Default on. Stored inverted
    /// (`bufferKeepOnAppSwitch`) so the default-on behavior holds when the key
    /// is unset — UserDefaults.bool defaults to false.
    var resetOnAppSwitch: Bool {
        get { !UserDefaults.standard.bool(forKey: "bufferKeepOnAppSwitch") }
        set { UserDefaults.standard.set(!newValue, forKey: "bufferKeepOnAppSwitch") }
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        let index = clampedInsertionIndex()
        blocks.insert(Block(text: text), at: index)
        insertionIndex = index + 1
        IMELog.write("buffer insert block at \(index) count=\(blocks.count)")
        onChange?()
    }

    func beginTransientLoading(requestId: String, message: String) {
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        IMELog.write("buffer transient loading request=\(requestId) message=\(IMELog.redact(message))")
        onChange?()
    }

    func appendMarineDraft(_ text: String, requestId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        transientEnabled = true
        if loadingRequestId == requestId {
            loadingRequestId = nil
            loadingMessage = nil
        }
        append(text)
        IMELog.write("buffer marine draft loaded request=\(requestId) chars=\(text.count)")
    }

    func failTransientLoading(requestId: String, message: String) {
        guard loadingRequestId == nil || loadingRequestId == requestId else { return }
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        IMELog.write("buffer transient failed request=\(requestId) message=\(IMELog.redact(message))")
        onChange?()
    }

    func cancelActiveMode() {
        loadingRequestId = nil
        loadingMessage = nil
        if transientEnabled {
            transientEnabled = false
        } else {
            enabled = false
        }
        onChange?()
    }

    @discardableResult
    func removeLastBlock() -> Bool {
        guard let removed = blocks.popLast() else { return false }
        clampInsertionIndexInPlace()
        IMELog.write("buffer remove last block \(IMELog.redact(removed.text)) remaining=\(blocks.count)")
        onChange?()
        return true
    }

    @discardableResult
    func moveInsertionPoint(delta: Int) -> Bool {
        let old = clampedInsertionIndex()
        let next = min(max(old + delta, 0), blocks.count)
        insertionIndex = next
        guard next != old else {
            IMELog.write("buffer insertion point edge index=\(next) count=\(blocks.count)")
            return false
        }
        IMELog.write("buffer insertion point \(old)->\(next) count=\(blocks.count)")
        onChange?()
        return true
    }

    /// Send everything now, oldest first. If every delivery path accepts the
    /// text, clear the queue but keep buffer mode active; otherwise preserve
    /// the unsent blocks so the user can retry.
    func sendAll() {
        guard !blocks.isEmpty else { return }
        IMELog.write("buffer send start blocks=\(blocks.count) chars=\(stagedCharacterCount)")
        for block in blocks {
            guard deliver?(block.text) == true else {
                IMELog.write("buffer send blocked; keeping \(blocks.count) blocks")
                onChange?()
                return
            }
            IMELog.write("buffer send attempted \(IMELog.redact(block.text))")
        }
        let count = blocks.count
        blocks.removeAll()
        insertionIndex = 0
        settleTransientIfIdle()
        IMELog.write("buffer send end; cleared \(count) blocks; buffer mode preserved")
        onChange?()
    }

    /// Send one block in FIFO order. A short Enter tap uses this, so releasing
    /// staged text never exits buffer mode.
    @discardableResult
    func sendNextBlock() -> Bool {
        guard let block = blocks.first else { return false }
        IMELog.write("buffer send next start block=\(IMELog.redact(block.text)) remaining=\(blocks.count)")
        guard deliver?(block.text) == true else {
            IMELog.write("buffer send next blocked; keeping \(blocks.count) blocks")
            onChange?()
            return false
        }

        blocks.removeFirst()
        if insertionIndex > 0 {
            insertionIndex -= 1
        }
        clampInsertionIndexInPlace()
        settleTransientIfIdle()
        IMELog.write("buffer send next attempted \(IMELog.redact(block.text)) remaining=\(blocks.count)")
        onChange?()
        return true
    }

    func clear() {
        if !blocks.isEmpty {
            IMELog.write("buffer clear dropped \(blocks.count) blocks chars=\(stagedCharacterCount)")
        }
        blocks.removeAll()
        insertionIndex = 0
        loadingRequestId = nil
        loadingMessage = nil
        if transientEnabled {
            transientEnabled = false
        }
        onChange?()
    }

    private func clampedInsertionIndex() -> Int {
        min(max(insertionIndex, 0), blocks.count)
    }

    private func clampInsertionIndexInPlace() {
        insertionIndex = clampedInsertionIndex()
    }

    private func settleTransientIfIdle() {
        if transientEnabled, blocks.isEmpty, loadingMessage == nil {
            transientEnabled = false
        }
    }
}
