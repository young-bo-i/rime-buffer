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

/// FlyYao divides every printable chording key by physical keyboard half.  The
/// split is expressed in Rime keysyms (not macOS virtual key codes), because a
/// keyboard layout may change the latter's printable character.
enum FlyChordHalf: Hashable {
    case left
    case right
}

enum FlyChordLayout {
    static let leftAlphabet = "qwertasdfgzxcvb"
    static let rightAlphabet = "yuiophjklnm,."

    private static let leftKeycodes = Set(leftAlphabet.unicodeScalars.map { Int32($0.value) })
    private static let rightKeycodes = Set(rightAlphabet.unicodeScalars.map { Int32($0.value) })

    static func half(for keycode: Int32) -> FlyChordHalf? {
        if leftKeycodes.contains(keycode) { return .left }
        if rightKeycodes.contains(keycode) { return .right }
        return nil
    }
}

/// Product-level settlement policy layered over the same FlyYao key map.
///
/// - `bothHalvesRequired` is 并击: a batch is not sent to Rime until at least
///   one key from each half has participated.
/// - `independentHalves` is 互击: a left-only initial, right-only final, or a
///   cross-half batch is sent to Rime and resolved normally.
enum FlyChordSettlementPolicy: Equatable {
    case bothHalvesRequired
    case independentHalves
}

/// A my_combo session only owns plain alphabet presses while it is composing
/// Chinese.  In ASCII mode Rime intentionally returns those keys to the host;
/// staging them here would swallow ordinary Latin typing until the chord timer
/// fires (and strict 并击 would discard a one-sided letter altogether).
enum FlyChordRoutingRules {
    static func shouldStage(schemaID: String, asciiMode: Bool) -> Bool {
        schemaID == "my_combo" && !asciiMode
    }
}

/// Every settled FlyYao batch is one syllable.  Rime's speller otherwise has
/// no way to distinguish two physical strokes whose canonical spellings also
/// form a valid single syllable (`ni` + `an` -> `nian`).  Insert the configured
/// apostrophe delimiters on the occupied sides of the raw-input cursor.  At
/// the end this is only a leading delimiter; editing in the middle also needs
/// a trailing delimiter so the inserted syllable cannot merge with its suffix.
struct FlyChordBoundaryPlan: Equatable {
    let before: Bool
    let after: Bool
}

enum FlyChordBoundaryRules {
    static let delimiterKeycode: Int32 = 0x27

    static func plan(for context: RimeContextModel) -> FlyChordBoundaryPlan {
        let bytes = Array(context.input.utf8)
        let cursor = min(max(context.cursorPos, 0), bytes.count)
        let delimiter = UInt8(delimiterKeycode)
        return FlyChordBoundaryPlan(
            before: cursor > 0 && bytes[cursor - 1] != delimiter,
            after: cursor < bytes.count && bytes[cursor] != delimiter
        )
    }
}

struct FlyChordKeyEvent: Equatable {
    let keycode: Int32
    let mask: Int32
}

enum FlyChordPressDecision: Equatable {
    /// The key belongs to a batch, but strict 并击 is still waiting for the
    /// complementary half (or this is an auto-repeat already in the batch).
    case consume
    /// Feed these press events to Rime now.  Strict 并击 returns the complete
    /// staged batch when its second half arrives; 互击 returns the new key.
    case process([FlyChordKeyEvent])
}

enum FlyChordBatchShape: Equatable {
    case leftOnly
    case rightOnly
    case bothHalves

    init?(keys: [(keycode: Int32, mask: Int32)]) {
        let halves = Set(keys.compactMap { FlyChordLayout.half(for: $0.keycode) })
        switch halves {
        case [.left]: self = .leftOnly
        case [.right]: self = .rightOnly
        case [.left, .right]: self = .bothHalves
        default: return nil
        }
    }
}

/// Tracks the one cross-batch relationship that 互击 must preserve: a settled
/// left-only initial followed by a right-only final belongs to one syllable.
/// The left batch is visible immediately; when its right complement arrives,
/// the controller removes that one insertion and replays both physical halves
/// as a normal full chord. Rime therefore ends with the exact same canonical
/// raw input, candidates, editing positions and commit semantics as a
/// simultaneous chord—no hidden sentinel spelling is left in the session.
struct FlyChordMutualPairingState {
    struct SettledLeft: Equatable {
        let keys: [FlyChordKeyEvent]
        let baseInput: String
        let settledInput: String
        let settledCursorPos: Int
        let settledSelStart: Int
        let settledSelEnd: Int
        let boundaryPlan: FlyChordBoundaryPlan
        let insertedScalarCount: Int
    }

    private var settledLeft: SettledLeft?

    mutating func recordSettledLeft(keys: [FlyChordKeyEvent],
                                    baseInput: String,
                                    settledContext: RimeContextModel,
                                    boundaryPlan: FlyChordBoundaryPlan,
                                    policy: FlyChordSettlementPolicy,
                                    shape: FlyChordBatchShape) {
        guard policy == .independentHalves,
              shape == .leftOnly,
              let inserted = FlyChordInputRollback.insertedScalarCount(
                before: baseInput,
                after: settledContext.input
              ),
              inserted > 0 else {
            settledLeft = nil
            return
        }
        settledLeft = SettledLeft(keys: keys,
                                  baseInput: baseInput,
                                  settledInput: settledContext.input,
                                  settledCursorPos: settledContext.cursorPos,
                                  settledSelStart: settledContext.selStart,
                                  settledSelEnd: settledContext.selEnd,
                                  boundaryPlan: boundaryPlan,
                                  insertedScalarCount: inserted)
    }

    mutating func takeComplement(before shape: FlyChordBatchShape,
                                 policy: FlyChordSettlementPolicy,
                                 currentContext: RimeContextModel) -> SettledLeft? {
        guard policy == .independentHalves,
              shape == .rightOnly,
              let pending = settledLeft,
              pending.settledInput == currentContext.input,
              pending.settledCursorPos == currentContext.cursorPos,
              pending.settledSelStart == currentContext.selStart,
              pending.settledSelEnd == currentContext.selEnd else {
            settledLeft = nil
            return nil
        }
        settledLeft = nil
        return pending
    }

    mutating func reset() {
        settledLeft = nil
    }
}

/// Pure batching state.  Keeping this independent of Timer/IMK makes the
/// important "strict chord vs independent halves" contract executable in the
/// CLI smoke test.
struct FlyChordBatchState {
    private(set) var pending: [FlyChordKeyEvent] = []
    private(set) var handled: [FlyChordKeyEvent] = []
    private var strictBatchActivated = false

    var hasPending: Bool { !pending.isEmpty }

    mutating func stage(_ key: FlyChordKeyEvent,
                        policy: FlyChordSettlementPolicy) -> FlyChordPressDecision {
        guard FlyChordLayout.half(for: key.keycode) != nil else { return .consume }
        guard !pending.contains(where: { $0.keycode == key.keycode }) else {
            return .consume
        }
        guard pending.count < 50 else { return .consume }
        pending.append(key)

        switch policy {
        case .independentHalves:
            return .process([key])
        case .bothHalvesRequired:
            if strictBatchActivated { return .process([key]) }
            let halves = Set(pending.compactMap { FlyChordLayout.half(for: $0.keycode) })
            guard halves.count == 2 else { return .consume }
            strictBatchActivated = true
            return .process(pending)
        }
    }

    mutating func noteHandled(_ key: FlyChordKeyEvent) {
        guard pending.contains(key), !handled.contains(key) else { return }
        handled.append(key)
    }

    mutating func settle() -> [FlyChordKeyEvent] {
        let replay = handled
        pending.removeAll(keepingCapacity: true)
        handled.removeAll(keepingCapacity: true)
        strictBatchActivated = false
        return replay
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        handled.removeAll(keepingCapacity: true)
        strictBatchActivated = false
    }
}

/// Detect the only mutation chord_composer is allowed to make when a failed
/// press subset is released: one contiguous insertion at the current raw-input
/// cursor.  The cursor remains immediately after that insertion, so ordinary
/// BackSpace events can remove it without disturbing the prefix or suffix that
/// predated the failed batch.
enum FlyChordInputRollback {
    static func insertedScalarCount(before: String, after: String) -> Int? {
        let old = Array(before.unicodeScalars)
        let new = Array(after.unicodeScalars)
        guard new.count >= old.count else { return nil }
        let insertedCount = new.count - old.count
        for offset in 0...old.count {
            guard new.prefix(offset).elementsEqual(old.prefix(offset)) else { continue }
            guard new.dropFirst(offset + insertedCount)
                    .elementsEqual(old.dropFirst(offset)) else { continue }
            return insertedCount
        }
        return nil
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

    private var batch = FlyChordBatchState()
    private var timer: Timer?
    private weak var client: (any IMKTextInput)?

    /// Replays keys (with releaseMask) against the session and drains commits.
    var onFlush: ((_ keys: [(keycode: Int32, mask: Int32)], _ client: (any IMKTextInput)?) -> Void)?

    /// A strict one-sided batch never entered Rime.  Its timer still needs to
    /// retire the owner's temporary marked-text guard.
    var onDiscard: ((_ client: (any IMKTextInput)?) -> Void)?

    var hasPending: Bool { batch.hasPending }

    /// Stage a physical chord press before it reaches Rime.  This is load
    /// bearing for strict 并击: rejecting a one-sided batch after its press was
    /// already processed would leave chord_composer with a stuck key or force
    /// us to clear unrelated preedit.
    func stageChordKey(_ keycode: Int32,
                       mask: Int32,
                       client: any IMKTextInput,
                       policy: FlyChordSettlementPolicy) -> FlyChordPressDecision {
        let decision = batch.stage(FlyChordKeyEvent(keycode: keycode, mask: mask),
                                   policy: policy)
        self.client = client
        guard batch.hasPending else { return decision }
        timer?.invalidate()
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.flush()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        return decision
    }

    /// Record only presses that Rime accepted.  Releases are synthesized only
    /// for this subset, preserving the original Squirrel replay invariant.
    func noteHandledChordKey(_ keycode: Int32, mask: Int32) {
        batch.noteHandled(FlyChordKeyEvent(keycode: keycode, mask: mask))
    }

    /// Resolve the pending chord NOW (timer fired, a non-chord key arrived,
    /// focus is leaving, or a commit is being forced).
    func flush() {
        guard batch.hasPending else { return }
        let keys = batch.settle().map { (keycode: $0.keycode, mask: $0.mask) }
        let flushClient = client      // strong for the duration of the flush
        timer?.invalidate()
        timer = nil
        client = nil
        if keys.isEmpty {
            onDiscard?(flushClient)
        } else {
            onFlush?(keys, flushClient)
        }
    }

    /// Cancel a batch after Rime rejects one of its press events.  The caller
    /// receives the already-accepted subset so it can synthesize matching
    /// releases before clearing the failed composition.  No normal flush or
    /// client callback is fired: a partially accepted FlyYao batch must never
    /// be allowed to settle as a valid one-sided mapping.
    func abort() -> [(keycode: Int32, mask: Int32)] {
        let keys = batch.settle().map { (keycode: $0.keycode, mask: $0.mask) }
        timer?.invalidate()
        timer = nil
        client = nil
        return keys
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        client = nil
        batch.reset()
    }
}
