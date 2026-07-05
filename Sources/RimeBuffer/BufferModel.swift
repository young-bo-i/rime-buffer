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
    /// Wired to the surface panel.
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

    /// Send a copy of everything now, oldest first. Keep blocks queued because
    /// IMK insertText provides no success acknowledgement from the target app.
    func flushAll() {
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
        IMELog.write("buffer send end; preserved \(blocks.count) blocks")
        onChange?()
    }

    func clear() {
        if !blocks.isEmpty {
            IMELog.write("buffer clear dropped \(blocks.count) blocks chars=\(stagedCharacterCount)")
        }
        blocks.removeAll()
        onChange?()
    }
}
