import AppKit
import Foundation

extension Notification.Name {
    static let keyFrequencyDidChange = Notification.Name("KeyFrequencyDidChange")
}

struct KeyFrequencySnapshot {
    let dayKey: String
    let counts: [String: Int]
    let total: Int
    let maxCount: Int
    let topKeyId: String?

    static let empty = KeyFrequencySnapshot(
        dayKey: "",
        counts: [:],
        total: 0,
        maxCount: 0,
        topKeyId: nil
    )
}

final class KeyFrequencyStore {
    static let shared = KeyFrequencyStore()

    private struct StoreFile: Codable {
        var version: Int
        var days: [String: DayRecord]
        var updatedAt: TimeInterval
    }

    private struct DayRecord: Codable {
        var keys: [String: Int]
    }

    private let url: URL
    private let dateProvider: () -> Date
    private let autosaveDelay: TimeInterval
    private let calendar = Calendar(identifier: .gregorian)
    private var file: StoreFile
    private var pendingSave: DispatchWorkItem?

    init(
        storageRoot: URL? = nil,
        autosaveDelay: TimeInterval = 1.0,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        let root = storageRoot
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/RimeBuffer")
        self.url = root.appendingPathComponent("stats/key_frequency.json")
        self.autosaveDelay = autosaveDelay
        self.dateProvider = dateProvider
        self.file = Self.load(from: self.url)
    }

    func record(keyCode: UInt16) {
        guard let keyId = KeyboardLayout.keyId(forKeyCode: keyCode) else { return }
        record(keyId: keyId, day: dateProvider())
    }

    func recordModifierPress(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard KeyboardLayout.isModifierKey(keyCode),
              KeyboardLayout.isModifierPressed(keyCode: keyCode, flags: flags),
              let keyId = KeyboardLayout.keyId(forKeyCode: keyCode)
        else { return }
        record(keyId: keyId, day: dateProvider())
    }

    func snapshot(for day: Date) -> KeyFrequencySnapshot {
        snapshot(dayKey: dayKey(for: day))
    }

    func clear(day: Date?) {
        if let day {
            file.days.removeValue(forKey: dayKey(for: day))
        } else {
            file.days.removeAll()
        }
        file.updatedAt = Date().timeIntervalSince1970
        saveNow()
        NotificationCenter.default.post(name: .keyFrequencyDidChange, object: self)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.prettySorted.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            IMELog.write("key-frequency save FAILED: \(error.localizedDescription)")
        }
    }

    func dayKey(for day: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private func record(keyId: String, day: Date) {
        let key = dayKey(for: day)
        var record = file.days[key] ?? DayRecord(keys: [:])
        record.keys[keyId, default: 0] += 1
        file.days[key] = record
        file.updatedAt = Date().timeIntervalSince1970
        scheduleSave()
        NotificationCenter.default.post(name: .keyFrequencyDidChange, object: self)
    }

    private func snapshot(dayKey: String) -> KeyFrequencySnapshot {
        let counts = file.days[dayKey]?.keys ?? [:]
        let total = counts.values.reduce(0, +)
        let maxCount = counts.values.max() ?? 0
        let topKeyId = counts.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
        return KeyFrequencySnapshot(
            dayKey: dayKey,
            counts: counts,
            total: total,
            maxCount: maxCount,
            topKeyId: topKeyId
        )
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    private static func load(from url: URL) -> StoreFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StoreFile.self, from: data)
        else {
            return StoreFile(version: 1, days: [:], updatedAt: Date().timeIntervalSince1970)
        }
        return decoded
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct KeyboardKeySpec {
    let keyId: String
    let label: String
    let keyCode: UInt16?
    let frame: CGRect
}

struct KeyboardLayout {
    let keys: [KeyboardKeySpec]
    let size: CGSize

    static let macANSI = KeyboardLayout(keys: macANSIKeys)

    init(keys: [KeyboardKeySpec]) {
        self.keys = keys
        let maxX = keys.map { $0.frame.maxX }.max() ?? 0
        let maxY = keys.map { $0.frame.maxY }.max() ?? 0
        self.size = CGSize(width: maxX, height: maxY)
    }

    static func keyId(forKeyCode keyCode: UInt16) -> String? {
        keyCodeToKeyId[keyCode]
    }

    static func displayName(for keyId: String) -> String {
        keyIdToLabel[keyId] ?? keyId
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func isModifierPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 57: return true
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63: return flags.contains(.function)
        default: return false
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let keyCodeToKeyId: [UInt16: String] = {
        var map = Dictionary(uniqueKeysWithValues: macANSIKeys.compactMap { key in
            key.keyCode.map { ($0, key.keyId) }
        })
        let extra: [UInt16: String] = [
            64: "F17", 65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd",
            71: "NumpadClear", 75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract",
            81: "NumpadEqual", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2",
            85: "Numpad3", 86: "Numpad4", 87: "Numpad5", 88: "Numpad6",
            89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 105: "F13",
            106: "F16", 107: "F14", 113: "F15", 114: "Help"
        ]
        for (code, keyId) in extra { map[code] = keyId }
        return map
    }()

    private static let keyIdToLabel: [String: String] = {
        var map = Dictionary(uniqueKeysWithValues: macANSIKeys.map { ($0.keyId, $0.label) })
        let extra = [
            "NumpadDecimal": "Num .", "NumpadMultiply": "Num *", "NumpadAdd": "Num +",
            "NumpadClear": "Clear", "NumpadDivide": "Num /", "NumpadEnter": "Num Enter",
            "NumpadSubtract": "Num -", "NumpadEqual": "Num =", "Numpad0": "Num 0",
            "Numpad1": "Num 1", "Numpad2": "Num 2", "Numpad3": "Num 3",
            "Numpad4": "Num 4", "Numpad5": "Num 5", "Numpad6": "Num 6",
            "Numpad7": "Num 7", "Numpad8": "Num 8", "Numpad9": "Num 9"
        ]
        for (keyId, label) in extra { map[keyId] = label }
        return map
    }()

    private static let macANSIKeys: [KeyboardKeySpec] = [
        key("Escape", "Esc", 53, 0, 0, 1.15),
        key("F1", "F1", 122, 1.6, 0), key("F2", "F2", 120, 2.7, 0),
        key("F3", "F3", 99, 3.8, 0), key("F4", "F4", 118, 4.9, 0),
        key("F5", "F5", 96, 6.25, 0), key("F6", "F6", 97, 7.35, 0),
        key("F7", "F7", 98, 8.45, 0), key("F8", "F8", 100, 9.55, 0),
        key("F9", "F9", 101, 10.9, 0), key("F10", "F10", 109, 12.0, 0),
        key("F11", "F11", 103, 13.1, 0), key("F12", "F12", 111, 14.2, 0),

        key("Backquote", "`", 50, 0, 1.35), key("Digit1", "1", 18, 1.05, 1.35),
        key("Digit2", "2", 19, 2.1, 1.35), key("Digit3", "3", 20, 3.15, 1.35),
        key("Digit4", "4", 21, 4.2, 1.35), key("Digit5", "5", 23, 5.25, 1.35),
        key("Digit6", "6", 22, 6.3, 1.35), key("Digit7", "7", 26, 7.35, 1.35),
        key("Digit8", "8", 28, 8.4, 1.35), key("Digit9", "9", 25, 9.45, 1.35),
        key("Digit0", "0", 29, 10.5, 1.35), key("Minus", "-", 27, 11.55, 1.35),
        key("Equal", "=", 24, 12.6, 1.35), key("Backspace", "Delete", 51, 13.65, 1.35, 1.65),

        key("Tab", "Tab", 48, 0, 2.4, 1.45), key("KeyQ", "Q", 12, 1.5, 2.4),
        key("KeyW", "W", 13, 2.55, 2.4), key("KeyE", "E", 14, 3.6, 2.4),
        key("KeyR", "R", 15, 4.65, 2.4), key("KeyT", "T", 17, 5.7, 2.4),
        key("KeyY", "Y", 16, 6.75, 2.4), key("KeyU", "U", 32, 7.8, 2.4),
        key("KeyI", "I", 34, 8.85, 2.4), key("KeyO", "O", 31, 9.9, 2.4),
        key("KeyP", "P", 35, 10.95, 2.4), key("BracketLeft", "[", 33, 12.0, 2.4),
        key("BracketRight", "]", 30, 13.05, 2.4), key("Backslash", "\\", 42, 14.1, 2.4, 1.2),

        key("CapsLock", "Caps", 57, 0, 3.45, 1.7), key("KeyA", "A", 0, 1.75, 3.45),
        key("KeyS", "S", 1, 2.8, 3.45), key("KeyD", "D", 2, 3.85, 3.45),
        key("KeyF", "F", 3, 4.9, 3.45), key("KeyG", "G", 5, 5.95, 3.45),
        key("KeyH", "H", 4, 7.0, 3.45), key("KeyJ", "J", 38, 8.05, 3.45),
        key("KeyK", "K", 40, 9.1, 3.45), key("KeyL", "L", 37, 10.15, 3.45),
        key("Semicolon", ";", 41, 11.2, 3.45), key("Quote", "'", 39, 12.25, 3.45),
        key("Enter", "Return", 36, 13.3, 3.45, 2.0),

        key("LeftShift", "Shift", 56, 0, 4.5, 2.25), key("KeyZ", "Z", 6, 2.3, 4.5),
        key("KeyX", "X", 7, 3.35, 4.5), key("KeyC", "C", 8, 4.4, 4.5),
        key("KeyV", "V", 9, 5.45, 4.5), key("KeyB", "B", 11, 6.5, 4.5),
        key("KeyN", "N", 45, 7.55, 4.5), key("KeyM", "M", 46, 8.6, 4.5),
        key("Comma", ",", 43, 9.65, 4.5), key("Period", ".", 47, 10.7, 4.5),
        key("Slash", "/", 44, 11.75, 4.5), key("RightShift", "Shift", 60, 12.8, 4.5, 2.5),

        key("Function", "fn", 63, 0, 5.55, 0.85), key("LeftControl", "Control", 59, 0.9, 5.55, 1.25),
        key("LeftOption", "Option", 58, 2.2, 5.55, 1.25), key("LeftCommand", "Command", 55, 3.5, 5.55, 1.45),
        key("Space", "Space", 49, 5.0, 5.55, 4.8), key("RightCommand", "Command", 54, 9.85, 5.55, 1.45),
        key("RightOption", "Option", 61, 11.35, 5.55, 1.25), key("ArrowLeft", "←", 123, 12.85, 5.8, 0.9, 0.65),
        key("ArrowUp", "↑", 126, 13.8, 5.55, 0.9, 0.65), key("ArrowDown", "↓", 125, 13.8, 6.25, 0.9, 0.65),
        key("ArrowRight", "→", 124, 14.75, 5.8, 0.9, 0.65),
        key("Home", "Home", 115, 15.95, 1.35), key("PageUp", "PgUp", 116, 17.0, 1.35),
        key("ForwardDelete", "Del", 117, 15.95, 2.4), key("End", "End", 119, 15.95, 3.45),
        key("PageDown", "PgDn", 121, 17.0, 3.45)
    ]

    private static func key(
        _ id: String,
        _ label: String,
        _ keyCode: UInt16?,
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat = 1,
        _ height: CGFloat = 0.85
    ) -> KeyboardKeySpec {
        KeyboardKeySpec(
            keyId: id,
            label: label,
            keyCode: keyCode,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
