import Foundation

/// A deliberately sanitized, non-consuming observation channel. Events never
/// contain committed text, IMK client proxies, focus tokens, or callbacks into
/// the key-routing path. Observers can measure input but cannot alter it.
enum InputTelemetryEvent: Equatable {
    struct Key: Equatable {
        let keyID: String
        let timestamp: TimeInterval
        let isRepeat: Bool
        let modifierFlags: UInt
        let schemaID: String
    }

    enum CommitSource: String, Equatable {
        case direct
        case buffer
    }

    struct Commit: Equatable {
        let characterCount: Int
        let timestamp: TimeInterval
        let source: CommitSource
        let schemaID: String
    }

    struct Chord: Equatable {
        let rimeKeyCodes: [Int32]
        let timestamp: TimeInterval
        let duration: TimeInterval
        let handledReleaseCount: Int
        let schemaID: String
    }

    case key(Key)
    case commit(Commit)
    case chord(Chord)
}

final class InputTelemetryObservation {
    fileprivate let id: UUID
    fileprivate weak var bus: InputTelemetryBus?

    fileprivate init(id: UUID, bus: InputTelemetryBus) {
        self.id = id
        self.bus = bus
    }

    func cancel() {
        bus?.removeObserver(id: id)
        bus = nil
    }

    deinit { cancel() }
}

final class InputTelemetryBus {
    static let shared = InputTelemetryBus()

    typealias Observer = (InputTelemetryEvent) -> Void
    private var observers: [UUID: Observer] = [:]

    @discardableResult
    func observe(_ observer: @escaping Observer) -> InputTelemetryObservation {
        precondition(Thread.isMainThread, "Input telemetry observers must be registered on main")
        let id = UUID()
        observers[id] = observer
        return InputTelemetryObservation(id: id, bus: self)
    }

    func publish(_ event: InputTelemetryEvent) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.publish(event) }
            return
        }
        // Snapshotting also makes it safe for an observer to cancel itself.
        let current = Array(observers.values)
        for observer in current { observer(event) }
    }

    fileprivate func removeObserver(id: UUID) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.removeObserver(id: id) }
            return
        }
        observers.removeValue(forKey: id)
    }
}

/// Pure value-level coverage for the sanitized observation channel and the
/// typing-speed admission policy. This deliberately needs no NSEvent, IMK
/// client, focus lease, settings window, or committed text fixture.
func runInputTelemetrySmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: input telemetry \(message)")
        return false
    }

    guard Thread.isMainThread else {
        return fail("must run on main thread")
    }

    let timestamp: TimeInterval = 1_700_000_000
    let ordinaryKey = InputTelemetryEvent.Key(
        keyID: "KeyA",
        timestamp: timestamp,
        isRepeat: false,
        modifierFlags: 0,
        schemaID: "smoke"
    )
    let bus = InputTelemetryBus()
    var received: [InputTelemetryEvent] = []
    let observation = bus.observe { received.append($0) }
    bus.publish(.key(ordinaryKey))
    observation.cancel()
    bus.publish(.commit(.init(
        characterCount: 1,
        timestamp: timestamp + 1,
        source: .direct,
        schemaID: "smoke"
    )))
    guard received == [.key(ordinaryKey)] else {
        return fail("observation cancellation")
    }

    let shiftMask = UInt(1) << 17
    let controlMask = UInt(1) << 18
    let optionMask = UInt(1) << 19
    let commandMask = UInt(1) << 20
    let shiftedTextKey = InputTelemetryEvent.Key(
        keyID: "KeyA", timestamp: timestamp, isRepeat: false,
        modifierFlags: shiftMask, schemaID: "smoke"
    )
    let rejectedKeys = [
        InputTelemetryEvent.Key(
            keyID: "KeyA", timestamp: timestamp, isRepeat: true,
            modifierFlags: 0, schemaID: "smoke"
        ),
        InputTelemetryEvent.Key(
            keyID: "KeyC", timestamp: timestamp, isRepeat: false,
            modifierFlags: controlMask, schemaID: "smoke"
        ),
        InputTelemetryEvent.Key(
            keyID: "KeyC", timestamp: timestamp, isRepeat: false,
            modifierFlags: optionMask, schemaID: "smoke"
        ),
        InputTelemetryEvent.Key(
            keyID: "KeyC", timestamp: timestamp, isRepeat: false,
            modifierFlags: commandMask, schemaID: "smoke"
        ),
        InputTelemetryEvent.Key(
            keyID: "ArrowLeft", timestamp: timestamp, isRepeat: false,
            modifierFlags: 0, schemaID: "smoke"
        ),
    ]
    guard TypingSpeedStore.countsTowardTypingSpeed(ordinaryKey),
          TypingSpeedStore.countsTowardTypingSpeed(shiftedTextKey),
          rejectedKeys.allSatisfy({ !TypingSpeedStore.countsTowardTypingSpeed($0) }) else {
        return fail("typing-speed filtering")
    }

    print("input telemetry smoke OK")
    return true
}
