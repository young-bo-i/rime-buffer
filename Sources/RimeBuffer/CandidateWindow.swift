import Cocoa

/// In-process candidate window (borderless NSPanel). Renders the current Rime
/// page from a native RimeContextModel — no cross-process anything.
///
/// Positioning chain (§5.5): (1) the caret rect the controller read from the
/// client — reliable now that a marked-text session is always active; (2) the
/// last known-good rect for this bundleId; (3) bottom-center of the main
/// screen. Never defaults to a screen corner.
final class CandidateWindow {
    private let panel: NSPanel
    private let stack = NSStackView()
    private var lastGoodRect: [String: NSRect] = [:]

    /// Mouse selection: row index on the current page. Wired by the controller
    /// to select_candidate_on_current_page + the normal commit drain.
    var onSelect: ((Int) -> Void)?

    // Visual parity with the user's squirrel config (font_point 20,
    // label_font_point 14, stacked vertical layout).
    private let candidateFontSize: CGFloat = 20
    private let labelFontSize: CGFloat = 14

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let visual = NSVisualEffectView()
        visual.material = .menu
        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 7          // user's corner_radius: 7
        visual.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5                        // user's line_spacing: 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visual.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        panel.contentView = visual
    }

    /// `caretRect` is what the controller got from the client (screen coords,
    /// zero when unavailable). `showPreedit` is true only in placeholder mode —
    /// in inline mode the preedit is already visible in the field.
    func update(_ ctx: RimeContextModel, caretRect: NSRect, bundleId: String, showPreedit: Bool) {
        guard !ctx.candidates.isEmpty || (showPreedit && !ctx.preedit.isEmpty) else {
            hide()
            return
        }

        rebuildRows(ctx, showPreedit: showPreedit)

        panel.layoutIfNeeded()
        let fit = stack.fittingSize
        panel.setContentSize(NSSize(width: max(fit.width, 80), height: fit.height))
        panel.setFrameOrigin(origin(for: caretRect, bundleId: bundleId))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    // MARK: Positioning

    private func origin(for caretRect: NSRect, bundleId: String) -> NSPoint {
        var anchor = caretRect
        if isPlausible(anchor) {
            lastGoodRect[bundleId] = anchor
        } else if let cached = lastGoodRect[bundleId] {
            anchor = cached
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 120)
        }

        // Point containment, NOT intersects — caret rects are often zero-width
        // and NSRect.intersects returns false for empty rects.
        let screen = NSScreen.screens.first {
            $0.frame.insetBy(dx: -8, dy: -8).contains(anchor.origin)
        } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.minX
        var y = anchor.minY - panel.frame.height - 4       // below the line
        if y < vf.minY { y = anchor.maxY + 4 }             // flip above
        x = min(max(x, vf.minX + 4), vf.maxX - panel.frame.width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - panel.frame.height - 4)
        return NSPoint(x: x, y: y)
    }

    private func isPlausible(_ r: NSRect) -> Bool {
        guard r != .zero, r.height > 2, r.height < 300 else { return false }
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(r.origin) }
    }

    // MARK: Rendering

    private func rebuildRows(_ ctx: RimeContextModel, showPreedit: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if showPreedit, !ctx.preedit.isEmpty {
            let p = NSTextField(labelWithString: ctx.preedit)
            p.font = .monospacedSystemFont(ofSize: labelFontSize, weight: .regular)
            p.textColor = .secondaryLabelColor
            stack.addArrangedSubview(p)
        }

        for (i, c) in ctx.candidates.enumerated() {
            stack.addArrangedSubview(row(index: i, candidate: c,
                                         highlighted: i == ctx.highlightedIndex))
        }

        if ctx.pageNo > 0 || !ctx.isLastPage {
            let pager = NSTextField(labelWithString:
                "\(ctx.pageNo > 0 ? "◂ " : "")\(ctx.pageNo + 1)\(ctx.isLastPage ? "" : " ▸")")
            pager.font = .systemFont(ofSize: 10)
            pager.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(pager)
        }
    }

    private func row(index: Int, candidate c: RimeCandidateModel, highlighted: Bool) -> NSView {
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: "\(c.label) ",
            attributes: [.font: NSFont.systemFont(ofSize: labelFontSize),
                         .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.85)
                                                       : NSColor.secondaryLabelColor,
                         .baselineOffset: (candidateFontSize - labelFontSize) / 2]))
        line.append(NSAttributedString(
            string: c.text,
            attributes: [.font: NSFont.systemFont(ofSize: candidateFontSize),
                         .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor]))
        if !c.comment.isEmpty {
            line.append(NSAttributedString(
                string: "  \(c.comment)",
                attributes: [.font: NSFont.systemFont(ofSize: labelFontSize),
                             .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.7)
                                                           : NSColor.tertiaryLabelColor,
                             .baselineOffset: (candidateFontSize - labelFontSize) / 2]))
        }

        let label = ClickableRow(index: index) { [weak self] i in self?.onSelect?(i) }
        label.attributedStringValue = line
        guard highlighted else { return label }

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        box.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }
}

/// A label row that reports clicks with its page-local candidate index.
private final class ClickableRow: NSTextField {
    private let index: Int
    private let onClick: (Int) -> Void

    init(index: Int, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.onClick = onClick
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // The panel is nonactivating and never key, so every click is an "initial"
    // mouse-down — without this it would be swallowed by the window server.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick(index) }
}
