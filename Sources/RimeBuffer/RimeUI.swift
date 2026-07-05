import Cocoa
import QuartzCore

enum RimeAppearanceMode: String, CaseIterable {
    case night
    case day

    var title: String {
        switch self {
        case .night: return "夜间模式"
        case .day: return "日间模式"
        }
    }
}

extension Notification.Name {
    static let rimeAppearanceDidChange = Notification.Name("RimeAppearanceDidChange")
}

enum RimeUI {
    private static let appearanceKey = "appearanceMode"

    static var appearance: RimeAppearanceMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: appearanceKey),
               let mode = RimeAppearanceMode(rawValue: raw) {
                return mode
            }
            return .night
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
            NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
        }
    }

    static var isNight: Bool { appearance == .night }

    static let accentBlue = color(0x3B82F6)
    static let accentGreen = color(0x22C55E)
    static var bufferBg: NSColor { isNight ? color(0x0C1E33) : .windowBackgroundColor }
    static var bufferBg2: NSColor { isNight ? color(0x123458) : .controlBackgroundColor }
    static var bufferBorder: NSColor { isNight ? color(0x2C5A8C) : .separatorColor }
    static var surface: NSColor { isNight ? color(0x101318) : .controlBackgroundColor }
    static var surface2: NSColor { isNight ? color(0x171B22) : .windowBackgroundColor }
    static var surface3: NSColor { isNight ? color(0x1E232C) : .underPageBackgroundColor }
    static var border: NSColor { isNight ? color(0x252A33) : .separatorColor }
    static var borderStrong: NSColor { isNight ? color(0x333A45) : .gridColor }
    static var textPrimary: NSColor { isNight ? color(0xF3F5F8) : .labelColor }
    static var textSecondary: NSColor { isNight ? color(0x9AA2AE) : .secondaryLabelColor }
    static var textMuted: NSColor { isNight ? color(0x646B77) : .tertiaryLabelColor }

    static var selectedCandidateColor: NSColor {
        isNight ? accentGreen : .controlAccentColor
    }

    static var candidateBackgroundColor: NSColor {
        isNight ? NSColor.black.withAlphaComponent(0.78)
                : NSColor.windowBackgroundColor.withAlphaComponent(0.96)
    }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
    }
}

final class GradientPanelView: NSView {
    private let gradient = CAGradientLayer()
    private let radius: CGFloat

    init(colors: [NSColor], cornerRadius: CGFloat, borderColor: NSColor? = nil, borderWidth: CGFloat = 0) {
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.cornerRadius = cornerRadius
        gradient.masksToBounds = true
        gradient.borderColor = borderColor?.cgColor
        gradient.borderWidth = borderWidth
        layer = gradient
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        gradient.cornerRadius = radius
    }
}
