import Cocoa

final class KeyboardHeatmapView: NSView {
    var snapshot: KeyFrequencySnapshot = .empty {
        didSet {
            needsDisplay = true
            updateHover(at: lastMousePoint)
        }
    }

    private let layout = KeyboardLayout.macANSI
    private var tracking: NSTrackingArea?
    private var hoveredKeyId: String?
    private var lastMousePoint: NSPoint?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 820, height: 330)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredKeyId = nil
        lastMousePoint = nil
        toolTip = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let metrics = layoutMetrics()
        for key in layout.keys {
            drawKey(key, rect: keyRect(for: key, metrics: metrics))
        }

        if snapshot.total == 0 {
            drawEmptyState()
        }
    }

    private func drawKey(_ key: KeyboardKeySpec, rect: NSRect) {
        let count = snapshot.counts[key.keyId] ?? 0
        let fraction = snapshot.maxCount > 0 ? CGFloat(count) / CGFloat(snapshot.maxCount) : 0
        let path = NSBezierPath(roundedRect: rect, xRadius: min(7, rect.height * 0.22), yRadius: min(7, rect.height * 0.22))

        let fill = keyFill(fraction: fraction, highlighted: hoveredKeyId == key.keyId)
        fill.setFill()
        path.fill()

        RimeUI.border.withAlphaComponent(RimeUI.isNight ? 0.75 : 0.55).setStroke()
        path.lineWidth = hoveredKeyId == key.keyId ? 1.6 : 1
        path.stroke()

        let labelFontSize: CGFloat = rect.height < 24 ? 9 : 11
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelFontSize, weight: .semibold),
            .foregroundColor: labelColor(fraction: fraction)
        ]
        drawCentered(key.label, in: rect.insetBy(dx: 2, dy: rect.height * 0.28), attributes: labelAttrs)

        if count > 0, rect.width >= 28, rect.height >= 26 {
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: labelColor(fraction: fraction).withAlphaComponent(0.72)
            ]
            let value = "\(count)" as NSString
            let size = value.size(withAttributes: countAttrs)
            let countRect = NSRect(
                x: rect.midX - size.width / 2,
                y: rect.minY + 4,
                width: size.width,
                height: size.height
            )
            value.draw(in: countRect, withAttributes: countAttrs)
        }
    }

    private func drawEmptyState() {
        let text = "暂无按键统计" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: RimeUI.textMuted
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
            withAttributes: attrs
        )
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let value = text as NSString
        let size = value.size(withAttributes: attributes)
        let drawRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        value.draw(in: drawRect, withAttributes: attributes)
    }

    private func updateHover(at point: NSPoint?) {
        lastMousePoint = point
        guard let point else { return }
        let metrics = layoutMetrics()
        let key = layout.keys.first { keyRect(for: $0, metrics: metrics).contains(point) }
        hoveredKeyId = key?.keyId
        if let key {
            let count = snapshot.counts[key.keyId] ?? 0
            let ratio = snapshot.total > 0 ? Double(count) / Double(snapshot.total) * 100 : 0
            toolTip = "\(key.label) · \(count) 次 · \(String(format: "%.1f", ratio))%"
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    private struct LayoutMetrics {
        let scale: CGFloat
        let origin: CGPoint
    }

    private func layoutMetrics() -> LayoutMetrics {
        let padding: CGFloat = 16
        let available = bounds.insetBy(dx: padding, dy: padding)
        let scale = min(
            available.width / layout.size.width,
            available.height / layout.size.height
        )
        let width = layout.size.width * scale
        let height = layout.size.height * scale
        return LayoutMetrics(
            scale: scale,
            origin: CGPoint(x: available.midX - width / 2, y: available.midY - height / 2)
        )
    }

    private func keyRect(for key: KeyboardKeySpec, metrics: LayoutMetrics) -> NSRect {
        NSRect(
            x: metrics.origin.x + key.frame.minX * metrics.scale,
            y: metrics.origin.y + (layout.size.height - key.frame.maxY) * metrics.scale,
            width: key.frame.width * metrics.scale,
            height: key.frame.height * metrics.scale
        ).insetBy(dx: 2, dy: 2)
    }

    private func keyFill(fraction: CGFloat, highlighted: Bool) -> NSColor {
        let base = RimeUI.isNight
            ? RimeUI.surface2.withAlphaComponent(0.88)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        guard fraction > 0 else {
            return highlighted ? base.blended(withFraction: 0.20, of: RimeUI.accentBlue) ?? base : base
        }
        let eased = min(1, max(0.16, sqrt(fraction)))
        let heat = RimeUI.isNight ? RimeUI.accentGreen : RimeUI.accentBlue
        let mixed = base.blended(withFraction: eased * 0.86, of: heat) ?? heat
        return highlighted ? mixed.highlight(withLevel: 0.12) ?? mixed : mixed
    }

    private func labelColor(fraction: CGFloat) -> NSColor {
        if fraction > 0.58 { return .white }
        return RimeUI.textPrimary
    }
}
