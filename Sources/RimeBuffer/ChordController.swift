import Cocoa
import InputMethodKit

/// Chord (并击) release-replay, Squirrel-style: chord keys that Rime handled are
/// buffered; when `duration` elapses with no new chord key, every buffered key
/// is replayed with releaseMask so chord_composer resolves the chord.
///
/// The OWNER gates this on the active schema (only my_combo uses
/// chord_composer) — sequential schemas must never see synthetic releases.
/// `duration` comes from the deployed squirrel config's `chord_duration`
/// (user-tuned to 0.05s); never hardcode.
final class ChordController {
    var duration: TimeInterval = 0.10

    private var pending: [(keycode: Int32, mask: Int32)] = []
    private var timer: Timer?
    private weak var client: (any IMKTextInput)?

    /// Replays keys (with releaseMask) against the session and drains commits.
    var onFlush: ((_ keys: [(keycode: Int32, mask: Int32)], _ client: (any IMKTextInput)?) -> Void)?

    var hasPending: Bool { !pending.isEmpty }

    /// Buffer a chord key Rime just handled; (re)arm the release timer.
    func noteHandledChordKey(_ keycode: Int32, mask: Int32, client: any IMKTextInput) {
        if pending.count < 50 { pending.append((keycode, mask)) }
        self.client = client
        timer?.invalidate()
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.flush()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Resolve the pending chord NOW (timer fired, a non-chord key arrived,
    /// focus is leaving, or a commit is being forced).
    func flush() {
        guard !pending.isEmpty else { return }
        let keys = pending
        let flushClient = client      // strong for the duration of the flush
        pending.removeAll()
        timer?.invalidate()
        timer = nil
        onFlush?(keys, flushClient)
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        pending.removeAll()
    }
}
