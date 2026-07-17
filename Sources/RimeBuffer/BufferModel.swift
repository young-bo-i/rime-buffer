import Foundation

/// External foreground identity used only by the optional privacy purge. Our
/// own settings/editor windows are deliberately represented as `nil`, so an
/// A -> ETInput -> A round trip is not mistaken for an application switch.
struct ForegroundApplicationIdentity: Equatable {
    let bundleID: String?
    let processIdentifier: pid_t
}

enum BufferPrivacyTransitionRules {
    static func externalIdentity(bundleID: String?,
                                 processIdentifier: pid_t,
                                 ownBundleID: String,
                                 ownProcessIdentifier: pid_t) -> ForegroundApplicationIdentity? {
        if bundleID == ownBundleID || processIdentifier == ownProcessIdentifier {
            return nil
        }
        guard let bundleID else {
            guard processIdentifier > 0 else { return nil }
            return ForegroundApplicationIdentity(bundleID: nil,
                                                 processIdentifier: processIdentifier)
        }
        return ForegroundApplicationIdentity(bundleID: bundleID,
                                             processIdentifier: processIdentifier)
    }

    /// Bundle identity is authoritative when both observations have it. PID is
    /// only a bridge while one side is temporarily missing a bundle, so a
    /// recycled PID can never equate two known, different applications.
    static func sameApplication(_ lhs: ForegroundApplicationIdentity,
                                _ rhs: ForegroundApplicationIdentity) -> Bool {
        if let leftBundleID = lhs.bundleID,
           let rightBundleID = rhs.bundleID {
            return leftBundleID == rightBundleID
        }
        return lhs.processIdentifier > 0
            && lhs.processIdentifier == rhs.processIdentifier
    }

    static func shouldDiscard(previousExternal: ForegroundApplicationIdentity?,
                              activatedExternal: ForegroundApplicationIdentity?,
                              resetOnSwitch: Bool,
                              holdsExternalContent: Bool) -> Bool {
        guard resetOnSwitch,
              !holdsExternalContent,
              let previousExternal,
              let activatedExternal else { return false }
        return !sameApplication(previousExternal, activatedExternal)
    }

    static func updatedPrevious(_ previousExternal: ForegroundApplicationIdentity?,
                                activatedExternal: ForegroundApplicationIdentity?)
        -> ForegroundApplicationIdentity? {
        guard let activatedExternal else { return previousExternal }
        guard let previousExternal,
              sameApplication(previousExternal, activatedExternal) else {
            return activatedExternal
        }
        // Do not let a transient PID-only observation erase a known bundle;
        // retaining the strong identity lets a later PID reuse be detected.
        if previousExternal.bundleID != nil,
           activatedExternal.bundleID == nil {
            return previousExternal
        }
        return activatedExternal
    }
}

/// Ordered staging buffer. Rime commits establish block boundaries before they
/// enter this model, so editing and delivery can preserve identity/provenance
/// without reviving the old diff/reconcile machinery.
final class BufferModel {
    static let shared = BufferModel()

    struct Block {
        let id: UUID
        var text: String
        let origin: Origin
        let createdAt: Date
        var lastSentAt: Date?
        var lastSentTargetBundleID: String?

        init(id: UUID = UUID(),
             text: String,
             origin: Origin = .rime,
             createdAt: Date = Date(),
             lastSentAt: Date? = nil,
             lastSentTargetBundleID: String? = nil) {
            self.id = id
            self.text = text
            self.origin = origin
            self.createdAt = createdAt
            self.lastSentAt = lastSentAt
            self.lastSentTargetBundleID = lastSentTargetBundleID
        }
    }

    /// In-memory delivery ledger. A record means IMK accepted the insert call;
    /// it is not an acknowledgement from the destination application.
    struct DeliveryRecord {
        let id = UUID()
        let blocks: [Block]
        /// Complete live ordering immediately before this delivery. Keeping
        /// the surrounding block IDs lets a later restore recover the exact
        /// relative position of blocks that disappeared after a successful
        /// insert attempt.
        let originalOrder: [UUID]
        let targetBundleID: String
        let targetName: String
        let sentAt = Date()

        var characterCount: Int { blocks.reduce(0) { $0 + $1.text.count } }
    }

    private(set) var blocks: [Block] = []
    private(set) var insertionIndex = 0
    private(set) var transientEnabled = false
    private(set) var loadingMessage: String?
    private(set) var loadingRequestId: String?
    private(set) var sentHistory: [DeliveryRecord] = []
    private(set) var lastClearedBlocks: [Block] = []

    var stagedText: String { blocks.map(\.text).joined() }
    var stagedCharacterCount: Int { stagedText.count }
    var pendingDeliveryBlocks: [Block] { blocks.filter { $0.lastSentAt == nil } }
    var pendingDeliveryCount: Int { pendingDeliveryBlocks.count }
    var canUndoClear: Bool { !lastClearedBlocks.isEmpty }

    /// External content exists to be sent to another app, so an optional
    /// app-switch cleanup must never erase it automatically.
    var holdsExternalContent: Bool {
        blocks.contains { $0.origin != .rime }
    }

    var shouldDisplay: Bool {
        active || !blocks.isEmpty || loadingMessage != nil
    }

    /// Interaction mode (Enter/backspace controls). Commit capture itself is
    /// deliberately narrower and uses `enabled`; transient external content
    /// must not silently begin capturing the user's local typing.
    var active: Bool { enabled || transientEnabled }

    /// Wired to the independent workbench window in main.swift.
    var onChange: (() -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "bufferEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "bufferEnabled")
            if !newValue, !blocks.isEmpty {
                IMELog.write("buffer mode off; preserving \(blocks.count) queued blocks")
            }
            notifyChange()
        }
    }

    /// A persistent workbench preserves content across applications by default.
    /// The old default-on reset remains available as an explicit privacy option.
    var resetOnAppSwitch: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "bufferResetOnAppSwitch.v2") != nil {
                return defaults.bool(forKey: "bufferResetOnAppSwitch.v2")
            }
            // Migrate the former inverted preference when it was explicitly
            // stored; a fresh install keeps the new workbench-safe default.
            if defaults.object(forKey: "bufferKeepOnAppSwitch") != nil {
                return !defaults.bool(forKey: "bufferKeepOnAppSwitch")
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: "bufferResetOnAppSwitch.v2") }
    }

    /// Stage accepted external text without changing the user's persistent
    /// capture preference. It may expose buffer keyboard commands while visible,
    /// but local Rime commits still use `enabled` to decide whether to capture.
    func stageExternal(_ text: String, origin: Origin) {
        transientEnabled = true
        append(text, origin: origin)
    }

    func append(_ text: String, origin: Origin = .rime) {
        guard !text.isEmpty else { return }
        let index = clampedInsertionIndex()
        blocks.insert(Block(text: text, origin: origin), at: index)
        insertionIndex = index + 1
        IMELog.write("buffer insert block at \(index) origin=\(origin.tag) count=\(blocks.count)")
        notifyChange()
    }

    func beginTransientLoading(requestId: String, message: String) {
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        IMELog.write("buffer transient loading request=\(requestId) message=\(IMELog.redact(message))")
        notifyChange()
    }

    func appendMarineDraft(_ text: String, requestId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        transientEnabled = true
        if loadingRequestId == requestId {
            loadingRequestId = nil
            loadingMessage = nil
        }
        append(text, origin: .marine)
        IMELog.write("buffer marine draft loaded request=\(requestId) chars=\(text.count)")
    }

    func failTransientLoading(requestId: String, message: String) {
        guard loadingRequestId == nil || loadingRequestId == requestId else { return }
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        IMELog.write("buffer transient failed request=\(requestId) message=\(IMELog.redact(message))")
        notifyChange()
    }

    func cancelActiveMode() {
        loadingRequestId = nil
        loadingMessage = nil
        if transientEnabled {
            transientEnabled = false
            notifyChange()
        } else {
            enabled = false
        }
    }

    /// Safe close-window behavior: stop invisible capture/interaction while
    /// preserving every staged block and any loading message.
    func pauseCapturePreservingContent() {
        UserDefaults.standard.set(false, forKey: "bufferEnabled")
        transientEnabled = false
        IMELog.write("buffer capture paused; preserved blocks=\(blocks.count)")
        notifyChange()
    }

    @discardableResult
    func removeLastBlock() -> Bool {
        guard let removed = blocks.popLast() else { return false }
        clampInsertionIndexInPlace()
        IMELog.write("buffer remove last block \(IMELog.redact(removed.text)) remaining=\(blocks.count)")
        settleTransientIfIdle()
        notifyChange()
        return true
    }

    @discardableResult
    func removeBlock(id: UUID) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        let removed = blocks.remove(at: index)
        if insertionIndex > index { insertionIndex -= 1 }
        clampInsertionIndexInPlace()
        settleTransientIfIdle()
        IMELog.write("buffer remove block id=\(id) origin=\(removed.origin.tag)")
        notifyChange()
        return true
    }

    /// Explicit per-block editing preserves id, origin and createdAt. Edited
    /// text becomes pending again even if the previous version was sent.
    @discardableResult
    func updateBlock(id: UUID, text: String) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        guard !text.isEmpty else { return removeBlock(id: id) }
        blocks[index].text = text
        blocks[index].lastSentAt = nil
        blocks[index].lastSentTargetBundleID = nil
        IMELog.write("buffer edit block id=\(id) chars=\(text.count) origin=\(blocks[index].origin.tag)")
        notifyChange()
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
        notifyChange()
        return true
    }

    /// Record accepted delivery attempts and consume those blocks from the live
    /// workbench in one model mutation. The history snapshot remains available
    /// for an explicit restore, but accepted blocks disappear immediately and
    /// cannot be retried accidentally.
    func recordDelivery(blockIDs: [UUID], targetBundleID: String, targetName: String) {
        guard !blockIDs.isEmpty else { return }
        let ids = Set(blockIDs)
        let sentAt = Date()
        let originalOrder = blocks.map(\.id)
        let deliveredIndexes = blocks.indices.filter { ids.contains(blocks[$0].id) }
        let snapshots = deliveredIndexes.map { index -> Block in
            var snapshot = blocks[index]
            snapshot.lastSentAt = sentAt
            snapshot.lastSentTargetBundleID = targetBundleID
            return snapshot
        }
        guard !snapshots.isEmpty else { return }

        let removedBeforeInsertion = deliveredIndexes.reduce(into: 0) { count, index in
            if index < insertionIndex { count += 1 }
        }
        blocks.removeAll { ids.contains($0.id) }
        insertionIndex -= removedBeforeInsertion
        clampInsertionIndexInPlace()
        settleTransientIfIdle()

        sentHistory.append(DeliveryRecord(blocks: snapshots,
                                          originalOrder: originalOrder,
                                          targetBundleID: targetBundleID,
                                          targetName: targetName))
        if sentHistory.count > 50 {
            sentHistory.removeFirst(sentHistory.count - 50)
        }
        IMELog.write("buffer delivery consumed blocks=\(snapshots.count) remaining=\(blocks.count) target=\(targetBundleID)")
        notifyChange()
    }

    /// Restore a delivery record for deliberate re-send/edit. Missing blocks
    /// are placed relative to every surviving block from the original live
    /// order, rather than merely appended in delivery-history order. This does
    /// not claim to remove text from the host app.
    @discardableResult
    func restoreDelivery(recordID: UUID) -> Bool {
        guard let record = sentHistory.first(where: { $0.id == recordID }) else { return false }
        var changed = false
        let originalIndexes = Dictionary(uniqueKeysWithValues: record.originalOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        let orderedSnapshots = record.blocks.sorted {
            (originalIndexes[$0.id] ?? Int.max) < (originalIndexes[$1.id] ?? Int.max)
        }

        for snapshot in orderedSnapshots {
            if let index = blocks.firstIndex(where: { $0.id == snapshot.id }) {
                if blocks[index].lastSentAt != nil || blocks[index].lastSentTargetBundleID != nil {
                    blocks[index].lastSentAt = nil
                    blocks[index].lastSentTargetBundleID = nil
                    changed = true
                }
            } else {
                let originalIndex = originalIndexes[snapshot.id] ?? record.originalOrder.count
                let laterIDs = record.originalOrder.dropFirst(min(originalIndex + 1,
                                                                   record.originalOrder.count))
                let nextIndex = laterIDs.compactMap { laterID in
                    blocks.firstIndex(where: { $0.id == laterID })
                }.first
                let earlierIDs = record.originalOrder.prefix(min(originalIndex,
                                                                  record.originalOrder.count)).reversed()
                let previousIndex = earlierIDs.compactMap { earlierID in
                    blocks.firstIndex(where: { $0.id == earlierID })
                }.first
                let insertionIndex = nextIndex
                    ?? previousIndex.map { min($0 + 1, blocks.count) }
                    ?? min(originalIndex, blocks.count)
                var restored = snapshot
                restored.lastSentAt = nil
                restored.lastSentTargetBundleID = nil
                blocks.insert(restored, at: insertionIndex)
                changed = true
            }
        }
        if changed {
            insertionIndex = blocks.count
            IMELog.write("buffer delivery restored record=\(recordID) blocks=\(record.blocks.count)")
            notifyChange()
        }
        return changed
    }

    func clear() {
        if !blocks.isEmpty {
            IMELog.write("buffer clear dropped \(blocks.count) blocks chars=\(stagedCharacterCount)")
            lastClearedBlocks = blocks
        }
        blocks.removeAll()
        insertionIndex = 0
        loadingRequestId = nil
        loadingMessage = nil
        transientEnabled = false
        notifyChange()
    }

    /// Non-recoverable privacy cleanup. Unlike the user's Clear action, an
    /// automatic app-switch purge must not leave the text recoverable through
    /// undo or delivery-history snapshots in the destination application.
    func discardForPrivacy() {
        let blockCount = blocks.count
        let historyCount = sentHistory.count
        blocks.removeAll()
        insertionIndex = 0
        loadingRequestId = nil
        loadingMessage = nil
        transientEnabled = false
        lastClearedBlocks.removeAll()
        sentHistory.removeAll()
        IMELog.write("buffer privacy discard blocks=\(blockCount) history=\(historyCount)")
        notifyChange()
    }

    @discardableResult
    func undoLastClear() -> Bool {
        guard !lastClearedBlocks.isEmpty else { return false }
        let restored = lastClearedBlocks
        lastClearedBlocks = []
        let existing = Set(blocks.map(\.id))
        blocks.insert(contentsOf: restored.filter { !existing.contains($0.id) }, at: 0)
        insertionIndex = blocks.count
        IMELog.write("buffer undo clear restored=\(restored.count)")
        notifyChange()
        return true
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

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(name: .bufferModelDidChange, object: self)
    }
}

extension Notification.Name {
    static let bufferModelDidChange = Notification.Name("BufferModelDidChange")
}
