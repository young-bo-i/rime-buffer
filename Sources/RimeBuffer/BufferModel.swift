import Foundation

/// The staging buffer (P2): with buffer mode ON, every Rime commit becomes a
/// block here instead of going to the field. Blocks age (default 3s), fade
/// (0.45s), then flush IN ORDER to the focused field via the injected sink.
/// Flushing pauses while a composition is in flight (`compositionActive`).
///
/// Rewritten from scratch (append-only, boundaries known at insert time) — the
/// old buffer-bar's diff/reconcile machinery is deliberately absent.
final class BufferModel {
    static let shared = BufferModel()

    struct Block {
        let id = UUID()
        let text: String
        let createdAt = Date()
        var fadeStartedAt: Date?
    }

    private(set) var blocks: [Block] = []
    private var timer: Timer?

    /// Wired in main.swift → active controller's client. Returns false when no
    /// client is available (block stays queued and retries).
    var deliver: ((String) -> Bool)?
    /// Wired to the surface panel.
    var onChange: (() -> Void)?
    /// Set by the controller around composition state; expiry waits on it.
    var compositionActive = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "bufferEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "bufferEnabled")
            if !newValue { flushAll() }      // leaving buffer mode delivers what's staged
            onChange?()
        }
    }

    var lifetime: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: "bufferBlockLifetime")
            return v > 0 ? v : 3.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "bufferBlockLifetime") }
    }

    let fadeDuration: TimeInterval = 0.45

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        blocks.append(Block(text: text))
        ensureTimer()
        onChange?()
    }

    /// Deliver everything now, oldest first, stopping if no client is around.
    func flushAll() {
        while let first = blocks.first {
            guard deliver?(first.text) == true else { break }
            blocks.removeFirst()
        }
        onChange?()
    }

    func clear() {
        blocks.removeAll()
        onChange?()
    }

    // MARK: Lifecycle ticking

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !blocks.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard !compositionActive else { return }   // never flush mid-composition
        let now = Date()
        var changed = false

        for i in blocks.indices
        where blocks[i].fadeStartedAt == nil && now.timeIntervalSince(blocks[i].createdAt) >= lifetime {
            blocks[i].fadeStartedAt = now
            changed = true
        }

        // Flush only from the FRONT so delivery order always matches typing order.
        while let first = blocks.first,
              let fadeStart = first.fadeStartedAt,
              now.timeIntervalSince(fadeStart) >= fadeDuration {
            guard deliver?(first.text) == true else { break }   // no client yet → retry next tick
            blocks.removeFirst()
            changed = true
        }
        if changed { onChange?() }
    }
}
