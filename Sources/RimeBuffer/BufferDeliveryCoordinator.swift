import Cocoa
import Carbon.HIToolbox

/// The only coordinator allowed to turn staged blocks into Delivery.insert
/// calls. It validates one live focus lease, resolves composition deliberately,
/// and consumes only the blocks whose insert attempts were accepted.
final class BufferDeliveryCoordinator {
    static let shared = BufferDeliveryCoordinator()

    enum BlockedReason: Equatable {
        case noFocusedField
        case composing
        case secureInput
        case nothingPending
        case targetChanged
        case deliveryRejected

        var message: String {
            switch self {
            case .noFocusedField: return "请先点选要接收文字的外部文本框"
            case .composing: return "正在组字，结束组字后才能发送"
            case .secureInput: return "安全输入已开启，发送被保护性禁用"
            case .nothingPending: return "缓冲区没有待发送内容"
            case .targetChanged: return "输入焦点已经变化，发送已停止"
            case .deliveryRejected: return "目标拒绝了发送，未发送内容仍然保留"
            }
        }
    }

    enum Availability: Equatable {
        case ready(appName: String, bundleID: String)
        case blocked(BlockedReason)

        var canSend: Bool {
            if case .ready = self { return true }
            return false
        }

        var label: String {
            switch self {
            case let .ready(appName, _): return "发送到：\(appName) · 当前文本框"
            case let .blocked(reason): return reason.message
            }
        }
    }

    struct SendResult {
        let sentCount: Int
        let blockedReason: BlockedReason?

        var succeeded: Bool { sentCount > 0 && blockedReason == nil }
    }

    private init() {}

    func availability() -> Availability {
        guard let target = InputFocusCoordinator.shared.liveTarget() else {
            return .blocked(.noFocusedField)
        }
        if target.compositionActive {
            return .blocked(.composing)
        }
        if IsSecureEventInputEnabled() {
            return .blocked(.secureInput)
        }
        if BufferModel.shared.pendingDeliveryBlocks.isEmpty {
            return .blocked(.nothingPending)
        }
        return .ready(appName: target.applicationName, bundleID: target.bundleID)
    }

    @discardableResult
    func sendNext(resolveCompositionIfNeeded: Bool = true,
                  expectedToken: FocusToken? = nil) -> SendResult {
        send(all: false,
             resolveCompositionIfNeeded: resolveCompositionIfNeeded,
             expectedToken: expectedToken)
    }

    @discardableResult
    func sendAll(resolveCompositionIfNeeded: Bool = true,
                 expectedToken: FocusToken? = nil) -> SendResult {
        send(all: true,
             resolveCompositionIfNeeded: resolveCompositionIfNeeded,
             expectedToken: expectedToken)
    }

    private func send(all: Bool,
                      resolveCompositionIfNeeded: Bool,
                      expectedToken: FocusToken?) -> SendResult {
        dispatchPrecondition(condition: .onQueue(.main))
        let initialTarget = expectedToken.flatMap {
            InputFocusCoordinator.shared.liveTarget(expected: $0)
        } ?? (expectedToken == nil ? InputFocusCoordinator.shared.liveTarget() : nil)
        guard var target = initialTarget else {
            let reason: BlockedReason = expectedToken == nil ? .noFocusedField : .targetChanged
            IMELog.write("buffer send blocked: \(reason.message)")
            return SendResult(sentCount: 0, blockedReason: reason)
        }

        if target.compositionActive {
            guard resolveCompositionIfNeeded,
                  let controller = target.controller else {
                return SendResult(sentCount: 0, blockedReason: .composing)
            }
            controller.resolveCompositionForBufferDelivery(target: target)
            guard let refreshed = InputFocusCoordinator.shared.liveTarget(expected: target.token) else {
                return SendResult(sentCount: 0, blockedReason: .targetChanged)
            }
            target = refreshed
            guard !target.compositionActive else {
                return SendResult(sentCount: 0, blockedReason: .composing)
            }
        }

        guard !IsSecureEventInputEnabled() else {
            IMELog.write("buffer send blocked: secure input")
            return SendResult(sentCount: 0, blockedReason: .secureInput)
        }

        let pending = BufferModel.shared.pendingDeliveryBlocks
        guard !pending.isEmpty else {
            return SendResult(sentCount: 0, blockedReason: .nothingPending)
        }
        let selected = all ? pending : Array(pending.prefix(1))
        var deliveredIDs: [UUID] = []
        var blockedReason: BlockedReason?

        for block in selected {
            guard let current = InputFocusCoordinator.shared.liveTarget(expected: target.token),
                  let controller = current.controller else {
                blockedReason = .targetChanged
                break
            }
            guard !current.compositionActive else {
                blockedReason = .composing
                break
            }
            guard !IsSecureEventInputEnabled() else {
                blockedReason = .secureInput
                break
            }
            guard controller.deliverBufferedBlock(block.text,
                                                   origin: block.origin,
                                                   target: current) else {
                blockedReason = InputFocusCoordinator.shared.liveTarget(expected: target.token) == nil
                    ? .targetChanged
                    : .deliveryRejected
                break
            }
            deliveredIDs.append(block.id)
            IMELog.write("buffer send accepted block=\(block.id) origin=\(block.origin.tag)")
        }

        if !deliveredIDs.isEmpty {
            BufferModel.shared.recordDelivery(blockIDs: deliveredIDs,
                                              targetBundleID: target.bundleID,
                                              targetName: target.applicationName)
        }
        if let blockedReason {
            IMELog.write("buffer send stopped reason=\(blockedReason.message) sent=\(deliveredIDs.count)")
        }
        return SendResult(sentCount: deliveredIDs.count, blockedReason: blockedReason)
    }
}
