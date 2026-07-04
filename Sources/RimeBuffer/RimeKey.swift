import AppKit

/// X11/ibus keysyms + modifier bit masks that librime's process_key expects.
/// Ported byte-identical from the proven prototype (values are load-bearing;
/// the 1<<30 release mask is how chord/串击 release is signalled to Rime).
enum RimeKey {
    static let shiftMask: Int32 = 1 << 0
    static let lockMask: Int32 = 1 << 1
    static let controlMask: Int32 = 1 << 2
    static let altMask: Int32 = 1 << 3
    static let superMask: Int32 = 1 << 6
    static let releaseMask: Int32 = 1 << 30

    static let backspace: Int32 = 0xff08
    static let tab: Int32 = 0xff09
    static let `return`: Int32 = 0xff0d
    static let escape: Int32 = 0xff1b
    static let deleteForward: Int32 = 0xffff
    static let home: Int32 = 0xff50
    static let left: Int32 = 0xff51
    static let up: Int32 = 0xff52
    static let right: Int32 = 0xff53
    static let down: Int32 = 0xff54
    static let pageUp: Int32 = 0xff55
    static let pageDown: Int32 = 0xff56
    static let end: Int32 = 0xff57
    static let f1: Int32 = 0xffbe   // XK_F1; F4 (user's switcher hotkey) = 0xffc1
    static let shiftL: Int32 = 0xffe1
    static let shiftR: Int32 = 0xffe2
    static let controlL: Int32 = 0xffe3
    static let controlR: Int32 = 0xffe4
    static let capsLock: Int32 = 0xffe5
    static let altL: Int32 = 0xffe9
    static let altR: Int32 = 0xffea
    static let superL: Int32 = 0xffeb
    static let superR: Int32 = 0xffec

    static func fromScalar(_ scalar: UnicodeScalar) -> Int32? {
        switch scalar.value {
        case 0x08, 0x7f: return backspace
        case 0x09: return tab
        case 0x0a, 0x0d: return `return`
        case 0x1b: return escape
        case 0x20...0x7e: return Int32(scalar.value)
        default: return nil
        }
    }

    static func fromVirtualKeyCode(_ keyCode: UInt16) -> Int32? {
        switch keyCode {
        case 0: return ascii("a")
        case 1: return ascii("s")
        case 2: return ascii("d")
        case 3: return ascii("f")
        case 4: return ascii("h")
        case 5: return ascii("g")
        case 6: return ascii("z")
        case 7: return ascii("x")
        case 8: return ascii("c")
        case 9: return ascii("v")
        case 11: return ascii("b")
        case 12: return ascii("q")
        case 13: return ascii("w")
        case 14: return ascii("e")
        case 15: return ascii("r")
        case 16: return ascii("y")
        case 17: return ascii("t")
        case 31: return ascii("o")
        case 32: return ascii("u")
        case 34: return ascii("i")
        case 35: return ascii("p")
        case 37: return ascii("l")
        case 38: return ascii("j")
        case 40: return ascii("k")
        case 43: return ascii(",")
        case 45: return ascii("n")
        case 46: return ascii("m")
        case 47: return ascii(".")
        // keyCode 50 (grave) is handled modifier-aware in the controller:
        // plain/Ctrl → grave 0x60, Shift-only → asciitilde 0x7e.
        // F-keys (X11 XK_F1=0xffbe .. XK_F12=0xffc9); F4 opens the user's schema switcher
        case 122: return f1 + 0     // F1
        case 120: return f1 + 1     // F2
        case 99:  return f1 + 2     // F3
        case 118: return f1 + 3     // F4
        case 96:  return f1 + 4     // F5
        case 97:  return f1 + 5     // F6
        case 98:  return f1 + 6     // F7
        case 100: return f1 + 7     // F8
        case 101: return f1 + 8     // F9
        case 109: return f1 + 9     // F10
        case 103: return f1 + 10    // F11
        case 111: return f1 + 11    // F12
        case 54: return superR
        case 55: return superL
        case 56: return shiftL
        case 57: return capsLock
        case 58: return altL
        case 59: return controlL
        case 60: return shiftR
        case 61: return altR
        case 62: return controlR
        default: return nil
        }
    }

    static func modifierMask(from flags: NSEvent.ModifierFlags) -> Int32 {
        var mask: Int32 = 0
        if flags.contains(.shift) { mask |= shiftMask }
        if flags.contains(.capsLock) { mask |= lockMask }
        if flags.contains(.control) { mask |= controlMask }
        if flags.contains(.option) { mask |= altMask }
        if flags.contains(.command) { mask |= superMask }
        return mask
    }

    static func changedModifierKeyCode(from changes: NSEvent.ModifierFlags) -> UInt16? {
        if changes.contains(.capsLock) { return 57 }
        if changes.contains(.shift) { return 56 }
        if changes.contains(.control) { return 59 }
        if changes.contains(.option) { return 58 }
        if changes.contains(.command) { return 55 }
        return nil
    }

    static func isChordingKey(_ keycode: Int32) -> Bool {
        switch keycode {
        case ascii("a")...ascii("z"), ascii(","), ascii("."):
            return true
        default:
            return false
        }
    }

    private static func ascii(_ character: Character) -> Int32 {
        Int32(String(character).unicodeScalars.first!.value)
    }
}
