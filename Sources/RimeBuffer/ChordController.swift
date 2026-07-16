import Cocoa
import InputMethodKit

extension Notification.Name {
    static let chordDurationDidChange = Notification.Name("ChordDurationDidChange")
}

/// User-tunable 并击 (chord) release window, persisted in UserDefaults and
/// surfaced in Settings ▸ 输入. This is the single source of truth: the value
/// replaces the old squirrel.yaml `chord_duration` read so tuning never needs a
/// config-file edit or redeploy. Changing it posts `.chordDurationDidChange`,
/// which every live controller observes to update its `ChordController` at once.
enum ChordSettings {
    static let defaultDuration: TimeInterval = 0.10
    static let range: ClosedRange<TimeInterval> = 0.02...0.50
    private static let key = "chord.duration"

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static var duration: TimeInterval {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: key) != nil else { return defaultDuration }
            return clamp(defaults.double(forKey: key))
        }
        set {
            let clamped = clamp(newValue)
            UserDefaults.standard.set(clamped, forKey: key)
            IMELog.write("chord_duration=\(clamped) source=preference")
            NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
        }
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        IMELog.write("chord_duration reset -> \(defaultDuration)")
        NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
    }
}

/// Synchronous routing barrier used while a focus lease is being revoked or
/// suspended. `ChordController.flush()` still feeds every release into Rime so
/// the composition can be recovered, but its callback must not touch the IMK
/// client proxy whose destination is no longer trustworthy.
final class ChordClientRoutingGate {
    private var isolationDepth = 0

    var allowsClientRouting: Bool { isolationDepth == 0 }

    func withIsolatedClientRouting(_ action: () -> Void) {
        isolationDepth += 1
        defer { isolationDepth -= 1 }
        action()
    }
}

/// Chord (并击) release-replay, Squirrel-style: chord keys that Rime handled are
/// buffered; when `duration` elapses with no new chord key, every buffered key
/// is replayed with releaseMask so chord_composer resolves the chord.
///
/// The OWNER gates this on the active schema (only my_combo uses
/// chord_composer) — sequential schemas must never see synthetic releases.
/// `duration` is seeded from `ChordSettings.duration` by the owner; never
/// hardcode a competing value here.
final class ChordController {
    var duration: TimeInterval = ChordSettings.defaultDuration

    private var pending: [(keycode: Int32, mask: Int32)] = []
    private var timer: Timer?
    private weak var client: (any IMKTextInput)?

    /// Replays keys (with releaseMask) against the session and drains commits.
    var onFlush: ((_ keys: [(keycode: Int32, mask: Int32)], _ client: (any IMKTextInput)?) -> Void)?

    var hasPending: Bool { !pending.isEmpty }

    /// Buffer a chord key Rime just handled; (re)arm the release timer.
    func noteHandledChordKey(_ keycode: Int32, mask: Int32, client: any IMKTextInput) {
        // Match Squirrel's rollover buffer: one physical key participates at
        // most once in a chord, even if macOS emits key-repeat before release.
        guard !pending.contains(where: { $0.keycode == keycode }) else { return }
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
