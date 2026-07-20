import Carbon.HIToolbox
import Foundation

enum WorkbenchGlobalHotKeyRoute: Equatable {
    case toggleVisibility
    case ignore
}

/// Pure definition/matcher for the process-wide workbench shortcut. Keeping
/// this separate from registration lets smoke tests validate the contract
/// without temporarily claiming a real global shortcut from the user's Mac.
enum WorkbenchGlobalHotKeyRouting {
    /// FourCC `ETBW` (Enter input method, Buffer Workbench).
    static let signature: OSType = 0x4554_4257
    static let identifierValue: UInt32 = 1
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(cmdKey | shiftKey)

    static var identifier: EventHotKeyID {
        EventHotKeyID(signature: signature, id: identifierValue)
    }

    static func route(eventClass: OSType,
                      eventKind: UInt32,
                      identifier: EventHotKeyID) -> WorkbenchGlobalHotKeyRoute {
        guard eventClass == OSType(kEventClassKeyboard),
              eventKind == UInt32(kEventHotKeyPressed),
              identifier.signature == signature,
              identifier.id == identifierValue else {
            return .ignore
        }
        return .toggleVisibility
    }
}

/// Carbon remains the least invasive way for an accessory input-method process
/// to own a true global shortcut: unlike an NSEvent global monitor it needs no
/// Accessibility permission, and a handled hot-key event is not delivered as a
/// character or application key equivalent. Normal Command-key IMK routing is
/// deliberately untouched.
final class GlobalHotKeyController {
    static let shared = GlobalHotKeyController()

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private init() {}

    @discardableResult
    func install() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if hotKeyRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard handlerStatus == noErr, let installedHandler else {
            IMELog.write("global hotkey handler install failed status=\(handlerStatus)")
            return false
        }
        eventHandlerRef = installedHandler

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            WorkbenchGlobalHotKeyRouting.keyCode,
            WorkbenchGlobalHotKeyRouting.modifiers,
            WorkbenchGlobalHotKeyRouting.identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            IMELog.write("global hotkey registration failed shortcut=Cmd+Shift+B status=\(registrationStatus)")
            _ = RemoveEventHandler(installedHandler)
            eventHandlerRef = nil
            return false
        }

        hotKeyRef = registeredHotKey
        IMELog.write("global hotkey installed shortcut=Cmd+Shift+B")
        return true
    }

    deinit {
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            _ = RemoveEventHandler(eventHandlerRef)
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return controller.handle(event)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard parameterStatus == noErr,
              WorkbenchGlobalHotKeyRouting.route(
                eventClass: GetEventClass(event),
                eventKind: GetEventKind(event),
                identifier: identifier
              ) == .toggleVisibility else {
            return OSStatus(eventNotHandledErr)
        }

        // The application event target normally invokes us on the main loop;
        // retain the same behavior defensively if Carbon ever calls elsewhere.
        let toggleWorkbench = {
            BufferWindowController.shared.toggleVisibility()
            IMELog.write("global hotkey toggled buffer workbench")
        }
        if Thread.isMainThread {
            toggleWorkbench()
        } else {
            DispatchQueue.main.async(execute: toggleWorkbench)
        }

        // This exact registered hot key is ours. Mark it handled so the B key
        // cannot continue into the focused host application.
        return noErr
    }
}
