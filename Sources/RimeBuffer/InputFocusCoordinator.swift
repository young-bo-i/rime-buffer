import Cocoa
import InputMethodKit

/// Monotonic identity for one focused IMK client. A token becomes permanently
/// stale as soon as another client is observed, even when both clients belong
/// to the same application.
struct FocusToken: Hashable, CustomStringConvertible {
    fileprivate let generation: UInt64

    var description: String { "focus-\(generation)" }
}

/// Pure epoch state used by the runtime coordinator and the CLI smoke test.
struct FocusEpochState {
    private(set) var generation: UInt64 = 0
    private(set) var current: FocusToken?

    mutating func activate() -> FocusToken {
        generation &+= 1
        let token = FocusToken(generation: generation)
        current = token
        return token
    }

    @discardableResult
    mutating func deactivate(_ token: FocusToken) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    func isCurrent(_ token: FocusToken) -> Bool {
        current == token
    }
}

/// Pure eligibility gate shared by the runtime and the CLI smoke test. Keeping
/// every condition visible in one predicate makes it hard to accidentally
/// reintroduce a "recent client" fallback while evolving IMK callbacks.
enum FocusTargetRules {
    static func shouldPruneExpiredLease(controllerAlive: Bool,
                                        clientAlive: Bool) -> Bool {
        !controllerAlive || !clientAlive
    }

    static func requiresNoClientCleanup(controllerAlive: Bool,
                                        clientAlive: Bool) -> Bool {
        controllerAlive && !clientAlive
    }

    static func identifiesExternalTarget(bundleID: String,
                                          processIdentifier: pid_t,
                                          ownBundleID: String,
                                          ownProcessIdentifier: pid_t) -> Bool {
        bundleID != ownBundleID && processIdentifier != ownProcessIdentifier
    }

    static func allows(tokenIsCurrent: Bool,
                       expectedTokenMatches: Bool,
                       externalTarget: Bool,
                       deliveryTrusted: Bool,
                       controllerAlive: Bool,
                       clientAlive: Bool,
                       clientIdentityMatches: Bool,
                       controllerClientIdentityMatches: Bool,
                       clientBundleMatches: Bool,
                       frontmostApplicationMatches: Bool,
                       frontmostProcessMatches: Bool) -> Bool {
        tokenIsCurrent
            && expectedTokenMatches
            && externalTarget
            && deliveryTrusted
            && controllerAlive
            && clientAlive
            && clientIdentityMatches
            && controllerClientIdentityMatches
            && clientBundleMatches
            && frontmostApplicationMatches
            && frontmostProcessMatches
    }
}

enum FocusEventRules {
    static func isOrdered(_ eventTimestamp: TimeInterval,
                          activationFloor: TimeInterval?,
                          lastAccepted: TimeInterval?) -> Bool {
        let epsilon = 0.000_001
        if let activationFloor, eventTimestamp + epsilon < activationFloor { return false }
        if let lastAccepted, eventTimestamp + epsilon < lastAccepted { return false }
        return true
    }

    static func mayTakeOwnership(incomingBundleID: String,
                                 currentOwnerBundleID: String,
                                 frontmostBundleID: String?) -> Bool {
        guard let frontmostBundleID else {
            return incomingBundleID == currentOwnerBundleID
        }
        return incomingBundleID == frontmostBundleID
    }

    static func mayEstablishProcessBoundLease(ownerExists: Bool,
                                              frontmostProcessIdentifier: pid_t?,
                                              knownClientProcessIdentifier: pid_t?) -> Bool {
        !ownerExists
            && frontmostProcessIdentifier != nil
            && knownClientProcessIdentifier == nil
    }
}

enum FocusActivationRules {
    static let provisionalConfirmationWindow: TimeInterval = 0.25
    static let reusedClientLifecycleSuppressionWindow: TimeInterval = 0.25
    static let ambiguousLifecycleMinimumAge: TimeInterval = 0.08

    static func shouldConfirmProvisional(isProvisional: Bool,
                                         sameControllerAndClient: Bool,
                                         age: TimeInterval) -> Bool {
        isProvisional
            && sameControllerAndClient
            && age >= 0
            && age <= provisionalConfirmationWindow
    }

    static func lifecycleCallbackMayApply(now: TimeInterval,
                                          suppressionUntil: TimeInterval,
                                          leaseAge: TimeInterval,
                                          senderIsExplicit: Bool,
                                          clientIdentityWasReused: Bool) -> Bool {
        guard !clientIdentityWasReused else { return false }
        guard now >= suppressionUntil else { return false }
        return senderIsExplicit || leaseAge >= ambiguousLifecycleMinimumAge
    }

    static func currentControllerClientMayApply(clientExists: Bool,
                                                 identityMatches: Bool) -> Bool {
        clientExists && identityMatches
    }

    static func mayContinueExactLeaseWithoutBundle(forceNewEpoch: Bool,
                                                    eventRequiresFreshEpoch: Bool) -> Bool {
        !forceNewEpoch && !eventRequiresFreshEpoch
    }

    static func eventRevealsFieldChange(hasEvent: Bool,
                                        reusesExactOwner: Bool,
                                        compositionActive: Bool,
                                        markedRangeReliable: Bool,
                                        markedRangeWasObservable: Bool,
                                        markedRangeIsMissing: Bool) -> Bool {
        hasEvent
            && reusesExactOwner
            && compositionActive
            && markedRangeReliable
            && markedRangeWasObservable
            && markedRangeIsMissing
    }
}

/// Runtime lease for the currently focused IMK client. References stay on the
/// main thread and are weak so a hostile host that omits deactivateServer cannot
/// keep an old controller/client alive forever.
final class FocusLease {
    let token: FocusToken
    weak var controller: RimeBufferController?
    weak var client: IMKTextInput?
    let clientIdentity: ObjectIdentifier
    let bundleID: String
    let processIdentifier: pid_t
    let isExternalTarget: Bool
    var activationEventFloor: TimeInterval?
    var lastAcceptedEventTimestamp: TimeInterval?
    var provisionalFromEvent: Bool
    let createdAtUptime: TimeInterval
    let lifecycleSuppressionUntilUptime: TimeInterval
    let clientIdentityWasReused: Bool
    var deliverySuspended = false
    var compositionActive = false
    var markedRangeReliable = true
    var markedRangeWasObservable = false

    init(token: FocusToken,
         controller: RimeBufferController,
         client: IMKTextInput,
         bundleID: String,
         processIdentifier: pid_t,
         isExternalTarget: Bool,
         activationEventFloor: TimeInterval?,
         lastAcceptedEventTimestamp: TimeInterval?,
         provisionalFromEvent: Bool,
         createdAtUptime: TimeInterval,
         lifecycleSuppressionUntilUptime: TimeInterval,
         clientIdentityWasReused: Bool) {
        self.token = token
        self.controller = controller
        self.client = client
        self.clientIdentity = ObjectIdentifier(client as AnyObject)
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
        self.isExternalTarget = isExternalTarget
        self.activationEventFloor = activationEventFloor
        self.lastAcceptedEventTimestamp = lastAcceptedEventTimestamp
        self.provisionalFromEvent = provisionalFromEvent
        self.createdAtUptime = createdAtUptime
        self.lifecycleSuppressionUntilUptime = lifecycleSuppressionUntilUptime
        self.clientIdentityWasReused = clientIdentityWasReused
    }

    var applicationName: String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? bundleID
    }
}

/// Owns focus epochs and the one delivery lease that is allowed to receive
/// buffered text. Candidate ownership and delivery eligibility share the same
/// token, but clients inside ETInput itself are never exposed as delivery
/// targets (notably the explicit block editor).
final class InputFocusCoordinator {
    static let shared = InputFocusCoordinator()

    struct Activation {
        let token: FocusToken
        let displaced: FocusLease?
    }

    private var epochs = FocusEpochState()
    private(set) var owner: FocusLease?
    private let knownClientProcesses = NSMapTable<AnyObject, NSNumber>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    var onChange: (() -> Void)?
    var onInvalidated: ((FocusToken) -> Void)?

    private init() {}

    @discardableResult
    private func pruneExpiredOwner() -> Bool {
        guard let expired = owner else { return false }
        let controller = expired.controller
        let controllerAlive = controller != nil
        let clientAlive = expired.client != nil
        guard FocusTargetRules.shouldPruneExpiredLease(
            controllerAlive: controllerAlive,
            clientAlive: clientAlive
        ) else { return false }
        _ = epochs.deactivate(expired.token)
        owner = nil
        IMELog.write("focus expired weak lease removed token=\(expired.token)")
        // If only the IMK client disappeared, the controller and its librime
        // session can still survive. Clear/recover that session without ever
        // calling the expired client, otherwise the next field can inherit its
        // chord or composition.
        if FocusTargetRules.requiresNoClientCleanup(
            controllerAlive: controllerAlive,
            clientAlive: clientAlive
        ) {
            controller?.finalizeProtectedSession(expired, reason: "focus client expired")
        }
        onInvalidated?(expired.token)
        onChange?()
        return true
    }

    /// A server activation denotes a new field focus even when IMK reuses the
    /// same application-level client proxy for multiple text controls.
    func beginActivation(controller: RimeBufferController,
                         client: IMKTextInput,
                         eventFloor: TimeInterval?) -> Activation? {
        activate(controller: controller,
                 client: client,
                 forceNewEpoch: true,
                 eventTimestamp: nil,
                 eventFloor: eventFloor)
    }

    /// `handle(_:client:)` can precede activateServer in some clients. A key
    /// event reuses the exact current lease, or establishes a new one when the
    /// client really changed. Its monotonic event timestamp rejects callbacks
    /// queued before the current activation.
    func noteEvent(controller: RimeBufferController,
                   client: IMKTextInput,
                   eventTimestamp: TimeInterval) -> Activation? {
        activate(controller: controller,
                 client: client,
                 forceNewEpoch: false,
                 eventTimestamp: eventTimestamp,
                 eventFloor: nil)
    }

    private func activate(controller: RimeBufferController,
                          client: IMKTextInput,
                          forceNewEpoch: Bool,
                          eventTimestamp: TimeInterval?,
                          eventFloor: TimeInterval?) -> Activation? {
        dispatchPrecondition(condition: .onQueue(.main))
        let identity = ObjectIdentifier(client as AnyObject)
        let bundleID = client.bundleIdentifier() ?? "unknown"
        let controllerClient = controller.client()
        let controllerClientMatches = controllerClient.map {
            ObjectIdentifier($0 as AnyObject) == identity
        } ?? false
        guard FocusActivationRules.currentControllerClientMayApply(
            clientExists: controllerClient != nil,
            identityMatches: controllerClientMatches
        ) else {
            IMELog.write("focus callback rejected; controller current client unavailable or mismatched bundle=\(bundleID)")
            return nil
        }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApplication?.bundleIdentifier
        let frontmostProcessIdentifier = frontmostApplication?.processIdentifier

        _ = pruneExpiredOwner()

        let reusesExactOwner = owner.map {
            epochs.isCurrent($0.token)
                && $0.controller === controller
                && $0.clientIdentity == identity
                && $0.client != nil
                && $0.bundleID == bundleID
        } ?? false

        if let frontmostBundleID, let frontmostProcessIdentifier {
            guard bundleID == frontmostBundleID else {
                IMELog.write("focus background callback rejected bundle=\(bundleID) frontmost=\(frontmostBundleID)")
                return nil
            }
            let clientObject = client as AnyObject
            if let knownProcess = knownClientProcesses.object(forKey: clientObject),
               knownProcess.int32Value != frontmostProcessIdentifier {
                IMELog.write("focus client process mismatch rejected bundle=\(bundleID) known=\(knownProcess.int32Value) frontmost=\(frontmostProcessIdentifier)")
                return nil
            }
            knownClientProcesses.setObject(NSNumber(value: frontmostProcessIdentifier),
                                           forKey: clientObject)
        } else {
            // NSWorkspace can briefly omit a bundle. Continue an exact lease;
            // when there is no owner yet, the frontmost PID plus the current
            // IMK client is enough to establish a process-bound lease. A known
            // client may also resume only in its recorded process.
            let clientObject = client as AnyObject
            let knownProcess = knownClientProcesses.object(forKey: clientObject)
            let knownProcessMatches = frontmostProcessIdentifier.map { processIdentifier in
                knownProcess?.int32Value == processIdentifier
            } ?? false
            let mayEstablishProcessBoundLease = FocusEventRules.mayEstablishProcessBoundLease(
                ownerExists: owner != nil,
                frontmostProcessIdentifier: frontmostProcessIdentifier,
                knownClientProcessIdentifier: knownProcess?.int32Value
            )
            guard reusesExactOwner
                    || knownProcessMatches
                    || mayEstablishProcessBoundLease else {
                IMELog.write("focus callback rejected; unverifiable frontmost bundle=\(bundleID)")
                return nil
            }
            if let owner,
               let frontmostProcessIdentifier,
               owner.processIdentifier != frontmostProcessIdentifier {
                IMELog.write("focus callback rejected; frontmost PID changed without bundle")
                return nil
            }
            if let frontmostProcessIdentifier {
                knownClientProcesses.setObject(NSNumber(value: frontmostProcessIdentifier),
                                               forKey: clientObject)
            }
        }

        if let owner, epochs.isCurrent(owner.token) {
            if let eventTimestamp,
               !FocusEventRules.isOrdered(eventTimestamp,
                                          activationFloor: owner.activationEventFloor,
                                          lastAccepted: owner.lastAcceptedEventTimestamp) {
                IMELog.write("focus out-of-order event rejected bundle=\(bundleID) owner=\(owner.token)")
                return nil
            }
            guard FocusEventRules.mayTakeOwnership(incomingBundleID: bundleID,
                                                   currentOwnerBundleID: owner.bundleID,
                                                   frontmostBundleID: frontmostBundleID) else { return nil }
        }

        // `markedRange()` touches the host proxy. Do it only after the app/PID
        // and event ordering gates above have proved this is not a stale or
        // background callback.
        let shouldInspectMarkedRange = eventTimestamp != nil
            && reusesExactOwner
            && owner?.compositionActive == true
            && owner?.markedRangeReliable == true
            && owner?.markedRangeWasObservable == true
        let markedRangeIsMissing = shouldInspectMarkedRange
            && client.markedRange().location == NSNotFound
        let eventRevealsFieldChange = FocusActivationRules.eventRevealsFieldChange(
            hasEvent: eventTimestamp != nil,
            reusesExactOwner: reusesExactOwner,
            compositionActive: owner?.compositionActive == true,
            markedRangeReliable: owner?.markedRangeReliable == true,
            markedRangeWasObservable: owner?.markedRangeWasObservable == true,
            markedRangeIsMissing: markedRangeIsMissing
        )
        let eventRequiresFreshEpoch = eventRevealsFieldChange
            || (eventTimestamp != nil
                && reusesExactOwner
                && owner?.deliverySuspended == true)

        // Some hosts deliver the first key before activateServer. That event
        // creates a provisional epoch; the matching activation confirms it
        // instead of displacing the just-started composition. Later explicit
        // activations still create fresh epochs even when IMK reuses a proxy.
        if forceNewEpoch,
           let owner,
           FocusActivationRules.shouldConfirmProvisional(
                isProvisional: owner.provisionalFromEvent,
                sameControllerAndClient: owner.controller === controller
                    && owner.clientIdentity == identity
                    && owner.client != nil,
                age: ProcessInfo.processInfo.systemUptime - owner.createdAtUptime
           ),
           !owner.deliverySuspended,
           epochs.isCurrent(owner.token) {
            owner.provisionalFromEvent = false
            owner.deliverySuspended = false
            if let eventFloor {
                owner.activationEventFloor = max(owner.activationEventFloor ?? eventFloor,
                                                 eventFloor)
            }
            return Activation(token: owner.token, displaced: nil)
        }

        // With no verifiable frontmost bundle, an ordered key event may
        // continue the exact PID-bound lease. An explicit server activation
        // still denotes a new field (except the provisional confirmation
        // handled above), so same-proxy reuse is displaced and recovered.
        if frontmostBundleID == nil,
           let owner,
           reusesExactOwner,
           FocusActivationRules.mayContinueExactLeaseWithoutBundle(
                forceNewEpoch: forceNewEpoch,
                eventRequiresFreshEpoch: eventRequiresFreshEpoch
           ),
           epochs.isCurrent(owner.token) {
            if let eventTimestamp {
                owner.lastAcceptedEventTimestamp = eventTimestamp
                if owner.deliverySuspended {
                    owner.deliverySuspended = false
                    onChange?()
                }
            }
            return Activation(token: owner.token, displaced: nil)
        }

        if let owner,
           !forceNewEpoch,
           !eventRequiresFreshEpoch,
           owner.controller === controller,
           owner.clientIdentity == identity,
           owner.client != nil,
           epochs.isCurrent(owner.token) {
            if let eventTimestamp {
                owner.lastAcceptedEventTimestamp = eventTimestamp
            }
            if owner.deliverySuspended {
                owner.deliverySuspended = false
                onChange?()
            }
            return Activation(token: owner.token, displaced: nil)
        }

        let displaced = owner
        let token = epochs.activate()
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let targetProcessIdentifier = frontmostProcessIdentifier
            ?? displaced?.processIdentifier
            ?? 0
        let isExternalTarget = FocusTargetRules.identifiesExternalTarget(
            bundleID: bundleID,
            processIdentifier: targetProcessIdentifier,
            ownBundleID: ownBundleID,
            ownProcessIdentifier: ownProcessIdentifier
        )
        let now = ProcessInfo.processInfo.systemUptime
        // An IMK proxy may be reused across controller instances as well as
        // fields within one controller. Identity reuse alone makes the old
        // destination unsafe.
        let reusesDisplacedIdentity = displaced?.clientIdentity == identity
        owner = FocusLease(token: token,
                           controller: controller,
                           client: client,
                           bundleID: bundleID,
                           processIdentifier: targetProcessIdentifier,
                           isExternalTarget: isExternalTarget,
                           activationEventFloor: eventFloor ?? eventTimestamp,
                           lastAcceptedEventTimestamp: eventTimestamp,
                           provisionalFromEvent: !forceNewEpoch,
                           createdAtUptime: now,
                           lifecycleSuppressionUntilUptime: reusesDisplacedIdentity
                               ? now + FocusActivationRules.reusedClientLifecycleSuppressionWindow
                               : now,
                           clientIdentityWasReused: reusesDisplacedIdentity)
        IMELog.write("focus activate token=\(token) bundle=\(bundleID) external=\(isExternalTarget)")
        onChange?()
        return Activation(token: token, displaced: displaced)
    }

    @discardableResult
    func deactivate(controller: RimeBufferController, token: FocusToken) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner,
              owner.controller === controller,
              owner.token == token,
              epochs.deactivate(token) else {
            IMELog.write("focus stale deactivate ignored token=\(token)")
            return nil
        }
        self.owner = nil
        IMELog.write("focus deactivate token=\(token) bundle=\(owner.bundleID)")
        onInvalidated?(token)
        onChange?()
        return owner
    }

    /// `markedRangeReliable` is false while the buffer keeps IMK alive with an
    /// invisible zero-width placeholder: hosts report that placeholder's marked
    /// range inconsistently (NSNotFound during fast chords / in terminals /
    /// Electron), so arming the marked-range field-change detector on it makes
    /// activate() spuriously fresh-epoch a valid key and drop it — the user then
    /// has to press again (broken 并击, F4 "select twice"). Identity + bundle +
    /// PID still guard delivery; only this one unreliable signal is skipped.
    func setCompositionActive(_ active: Bool, token: FocusToken, markedRangeReliable: Bool = true) {
        guard let owner, owner.token == token, epochs.isCurrent(token) else { return }
        owner.markedRangeReliable = markedRangeReliable
        if active,
           markedRangeReliable,
           !owner.markedRangeWasObservable,
           let client = owner.client,
           client.markedRange().location != NSNotFound {
            owner.markedRangeWasObservable = true
        } else if !active || !markedRangeReliable {
            owner.markedRangeWasObservable = false
        }
        guard owner.compositionActive != active else { return }
        owner.compositionActive = active
        onChange?()
    }

    /// A lifecycle callback that cannot yet be attributed safely must never
    /// leave the old field eligible for buffered delivery. A subsequent exact
    /// key event or activation restores trust without discarding composition.
    func suspendDelivery(token: FocusToken, reason: String) {
        guard let owner,
              owner.token == token,
              epochs.isCurrent(token),
              !owner.deliverySuspended else { return }
        owner.deliverySuspended = true
        IMELog.write("focus delivery suspended token=\(token) reason=\(reason)")
        onInvalidated?(token)
        onChange?()
    }

    func isCurrent(_ token: FocusToken, controller: RimeBufferController? = nil) -> Bool {
        if Thread.isMainThread { _ = pruneExpiredOwner() }
        guard let owner,
              owner.token == token,
              epochs.isCurrent(token),
              owner.controller != nil,
              owner.client != nil else { return false }
        if let controller { return owner.controller === controller }
        return true
    }

    func controller(for token: FocusToken) -> RimeBufferController? {
        guard isCurrent(token) else { return nil }
        return owner?.controller
    }

    func lease(for token: FocusToken) -> FocusLease? {
        guard isCurrent(token) else { return nil }
        return owner
    }

    private func validatedTarget(expected token: FocusToken?,
                                 requireExternal: Bool) -> FocusLease? {
        if Thread.isMainThread { _ = pruneExpiredOwner() }
        guard let owner else { return nil }
        let client = owner.client
        let controllerClient = owner.controller?.client()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        // A running application can briefly expose a PID before its bundle ID.
        // The exact PID gate below still applies, so nil bundle is consistent
        // with the process-bound lease admitted by `activate` above.
        let frontmostBundleMatches = frontmostApplication?.bundleIdentifier.map {
            $0 == owner.bundleID
        } ?? true
        guard FocusTargetRules.allows(
            tokenIsCurrent: epochs.isCurrent(owner.token),
            expectedTokenMatches: token == nil || owner.token == token,
            externalTarget: !requireExternal || owner.isExternalTarget,
            deliveryTrusted: !owner.deliverySuspended,
            controllerAlive: owner.controller != nil,
            clientAlive: client != nil,
            clientIdentityMatches: client.map { ObjectIdentifier($0 as AnyObject) == owner.clientIdentity } ?? false,
            controllerClientIdentityMatches: controllerClient.map {
                ObjectIdentifier($0 as AnyObject) == owner.clientIdentity
            } ?? false,
            clientBundleMatches: client.map { ($0.bundleIdentifier() ?? "unknown") == owner.bundleID } ?? false,
            frontmostApplicationMatches: frontmostBundleMatches,
            frontmostProcessMatches: frontmostApplication?.processIdentifier == owner.processIdentifier
        ) else { return nil }
        return owner
    }

    /// Exact current client eligible for candidate interaction. Unlike buffered
    /// delivery this may be an ETInput-owned editor, but it still requires a
    /// trusted lifecycle plus the current bundle and process.
    func interactionTarget(expected token: FocusToken? = nil) -> FocusLease? {
        validatedTarget(expected: token, requireExternal: false)
    }

    /// Returns a target only while the exact external app/client lease is live.
    /// There is deliberately no recent-controller or last-client fallback.
    func liveTarget(expected token: FocusToken? = nil) -> FocusLease? {
        validatedTarget(expected: token, requireExternal: true)
    }

    /// Workspace activation can arrive before or after IMK focus callbacks. If
    /// the current lease already belongs to the activated app it remains valid;
    /// otherwise it is revoked and returned so its owner can resolve composition.
    func invalidateIfFrontmostChanged(to application: NSRunningApplication?) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner else { return nil }
        let bundleID = application?.bundleIdentifier
        let processIdentifier = application?.processIdentifier
        let bundleChanged = bundleID.map { $0 != owner.bundleID } ?? false
        guard bundleChanged || processIdentifier != owner.processIdentifier else { return nil }
        _ = epochs.deactivate(owner.token)
        self.owner = nil
        IMELog.write("focus invalidated token=\(owner.token) activated=\(bundleID ?? "unknown")")
        onInvalidated?(owner.token)
        onChange?()
        return owner
    }

    func invalidateAll(reason: String) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner else { return nil }
        _ = epochs.deactivate(owner.token)
        self.owner = nil
        IMELog.write("focus invalidated token=\(owner.token) reason=\(reason)")
        onInvalidated?(owner.token)
        onChange?()
        return owner
    }
}
