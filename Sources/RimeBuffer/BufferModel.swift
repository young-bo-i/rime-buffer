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

    var stagedText: String {
        blocks.map(\.text).joined()
    }

    var stagedCharacterCount: Int {
        stagedText.count
    }

    var shouldDisplay: Bool {
        enabled || !blocks.isEmpty
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

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        blocks.append(Block(text: text))
        onChange?()
    }

    @discardableResult
    func removeLastBlock() -> Bool {
        guard let removed = blocks.popLast() else { return false }
        IMELog.write("buffer remove last block '\(removed.text)' remaining=\(blocks.count)")
        onChange?()
        return true
    }

    /// Send everything now, oldest first. If every delivery path accepts the
    /// text, clear the queue and leave buffer mode; otherwise preserve state so
    /// the user can retry.
    func sendAllAndExit() {
        guard !blocks.isEmpty else { return }
        IMELog.write("buffer send start blocks=\(blocks.count) chars=\(stagedCharacterCount)")
        for block in blocks {
            guard deliver?(block.text) == true else {
                IMELog.write("buffer send blocked; keeping \(blocks.count) blocks")
                onChange?()
                return
            }
            IMELog.write("buffer send attempted '\(block.text)'")
        }
        let count = blocks.count
        blocks.removeAll()
        IMELog.write("buffer send end; cleared \(count) blocks and disabled buffer mode")
        enabled = false
    }

    func clear() {
        if !blocks.isEmpty {
            IMELog.write("buffer clear dropped \(blocks.count) blocks chars=\(stagedCharacterCount)")
        }
        blocks.removeAll()
        onChange?()
    }
}
