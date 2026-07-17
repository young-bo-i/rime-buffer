import Cocoa
import InputMethodKit

/// The v2 composition protocol: a marked-text session ALWAYS exists while Rime
/// is composing. Squirrel-proven — without a session, clients echo the raw
/// keystrokes ("zuoye作业" leak, seen in WeChat) and the caret-rect API returns
/// zero. The session's CONTENT is a policy:
///   .inline       marked text = underlined preedit (matches the user's
///                 squirrel.yaml `inline_preedit: true`); default.
///   .placeholder  marked text = one full-width space "　" (Squirrel's trick to
///                 keep hostile fields — iTerm2 etc. — from echoing, while the
///                 preedit renders in our candidate panel instead).
final class CompositionSession {
    enum Mode: String { case inline, placeholder }

    private let bufferGuardText = "\u{200B}"

    private(set) var markedTextActive = false
    private(set) var composing = false
    private var bufferGuardActive = false

    /// Per-app override table (bundleId -> "placeholder"). Empty by default;
    /// populate as hostile apps are found in the field.
    static func mode(for bundleId: String) -> Mode {
        let overrides = UserDefaults.standard
            .dictionary(forKey: "compositionModeOverrides") as? [String: String]
        return overrides?[bundleId] == Mode.placeholder.rawValue ? .placeholder : .inline
    }

    /// Reflect the current Rime preedit into the client's marked text.
    /// `cursorPosUTF8` is librime's byte offset into the UTF-8 preedit.
    func update(preedit: String, cursorPosUTF8: Int, client: IMKTextInput, mode: Mode) {
        guard !preedit.isEmpty else {
            clear(client: client)
            return
        }
        let replacement = NSRange(location: NSNotFound, length: 0)
        switch mode {
        case .inline:
            let attr = NSMutableAttributedString(string: preedit)
            attr.addAttribute(.underlineStyle,
                              value: NSUnderlineStyle.single.rawValue,
                              range: NSRange(location: 0, length: attr.length))
            let caret = Self.utf16Offset(ofUTF8 : cursorPosUTF8, in: preedit)
            client.setMarkedText(attr,
                                 selectionRange: NSRange(location: caret, length: 0),
                                 replacementRange: replacement)
        case .placeholder:
            client.setMarkedText("　" as NSString,
                                 selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: replacement)
        }
        markedTextActive = true
        composing = true
        bufferGuardActive = false
    }

    /// Keep the host field connected to IMK while buffer mode owns visible
    /// editing. The marked text is intentionally invisible; buffer UI renders
    /// the real preedit/caret.
    func updateBufferGuard(active: Bool, client: IMKTextInput) {
        guard active else {
            clear(client: client)
            return
        }
        // setMarkedText can synchronously enter the host and trigger expensive
        // focus probes. Keep one guard for the whole composition/chord instead
        // of replacing it after every physical key.
        if !bufferGuardActive {
            client.setMarkedText(bufferGuardText as NSString,
                                 selectionRange: NSRange(location: (bufferGuardText as NSString).length,
                                                         length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            markedTextActive = true
            bufferGuardActive = true
        }
        composing = true
    }

    /// End the session explicitly (escape / focus loss / commit without insert).
    func clear(client: IMKTextInput) {
        guard markedTextActive else { return }
        client.setMarkedText("" as NSString,
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        markedTextActive = false
        composing = false
        bufferGuardActive = false
    }

    /// insertText replaces the marked text atomically and closes the session —
    /// record that without sending another setMarkedText.
    func commitDidInsert() {
        markedTextActive = false
        composing = false
        bufferGuardActive = false
    }

    /// Session died with its client (focus already gone); just drop the flag.
    func markCleared() {
        markedTextActive = false
        composing = false
        bufferGuardActive = false
    }

    private static func utf16Offset(ofUTF8 byteOffset: Int, in s: String) -> Int {
        if byteOffset <= 0 { return 0 }
        let bytes = Array(s.utf8.prefix(byteOffset))
        if bytes.count >= s.utf8.count { return (s as NSString).length }
        return String(decoding: bytes, as: UTF8.self).utf16.count
    }
}
