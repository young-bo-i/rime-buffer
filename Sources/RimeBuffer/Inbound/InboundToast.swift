import Cocoa

/// A small non-activating popup at the top-right of the screen, shown when new
/// external content lands in the inbound bus. Clicking it opens the inbox.
/// Non-activating so it never steals focus from what the user is typing into
/// (unlike auto-raising a real window). Auto-dismisses after a few seconds.
final class InboundToast: NSObject {
    static let shared = InboundToast()

    private var panel: NSPanel?
    private let countLabel = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    /// Called on every inbound change. Shows/updates the toast when there are
    /// pending items and the inbox isn't already open; hides it otherwise.
    func update(pendingCount: Int, trayVisible: Bool) {
        guard pendingCount > 0, !trayVisible else { hide(); return }
        countLabel.stringValue = "收到 \(pendingCount) 条外部内容 · 点击查看"
        show()
    }

    private func show() {
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        let button = ToastButton()
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(openInbox)
        button.wantsLayer = true
        button.layer?.backgroundColor = RimeUI.surface2.cgColor
        button.layer?.cornerRadius = 10
        button.layer?.borderColor = RimeUI.border.cgColor
        button.layer?.borderWidth = 1
        button.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = RimeUI.color(0xF59E0B).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = RimeUI.textPrimary

        let row = NSStackView(views: [dot, countLabel])
        row.spacing = 8; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        p.contentView = NSView()
        p.contentView?.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
            button.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
            button.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor),
        ])
        panel = p
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16))
    }

    @objc private func openInbox() {
        hide()
        InboundTrayWindow.shared.show()
    }

    /// Button that works without activating the app (nonactivating panel).
    private final class ToastButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
