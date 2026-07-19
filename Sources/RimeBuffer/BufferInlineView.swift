import Cocoa
import QuartzCore

/// Compact block rail used by the independent workbench window. It never holds
/// an IMK client or action buttons; it only renders staged blocks.
final class BufferInlineView: NSView {
    static let standardPreferredHeight: CGFloat = 34
    static let translationPreferredHeight: CGFloat = 68

    private struct RenderedBlock: Equatable {
        let id: UUID
        let text: String
        let origin: Origin
        let pluginMetadata: BufferModel.PluginMetadata?
    }

    private struct RenderSignature: Equatable {
        let blocks: [RenderedBlock]
        let insertionIndex: Int
        let active: Bool
        let preedit: String
        let loadingMessage: String?
        let loadingActive: Bool
        let translation: TranslationRailSnapshot?
        let shielded: Bool
        let isNight: Bool
    }

    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let normalRailContainer = NSStackView()
    private let translationContainer = NSStackView()
    private let translationSourceScroll = NSScrollView()
    private let translationSourceRow = NSStackView()
    private let translationTargetScroll = NSScrollView()
    private let translationTargetRow = NSStackView()
    private let leadingSpacer = NSView()
    private let translationSourceSpacer = NSView()
    private let translationTargetSpacer = NSView()
    private let caretView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "等待暂存内容")
    private let translationSourceEmptyLabel = NSTextField(labelWithString: "等待原文")
    private let translationTargetEmptyLabel = NSTextField(labelWithString: "等待译文")
    private let loadingIndicator = NSProgressIndicator()
    private let enterHoldProgressLayer = CALayer()
    private var renderedBlockIDs: [UUID] = []
    private var lastRenderSignature: RenderSignature?
    private var contentShielded = false
    private var enterHoldProgress: CGFloat?
    private(set) var renderPassCount = 0
    var renderedBlockCount: Int { renderedBlockIDs.count }
    var isEnterHoldProgressVisible: Bool { enterHoldProgress != nil }
    var renderedTextFragments: [String] {
        func collect(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(chipRow)
            + collect(translationSourceRow)
            + collect(translationTargetRow)
    }

    var preferredHeight: CGFloat {
        translationContainer.isHidden
            ? Self.standardPreferredHeight
            : Self.translationPreferredHeight
    }

    var usesStackedTranslationLayout: Bool { !translationContainer.isHidden }
    var translationRailCount: Int { usesStackedTranslationLayout ? 2 : 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        enterHoldProgressLayer.cornerRadius = 1
        enterHoldProgressLayer.zPosition = 50
        enterHoldProgressLayer.opacity = 0
        layer?.addSublayer(enterHoldProgressLayer)
        updateHairlineWidth()

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail
        for label in [translationSourceEmptyLabel, translationTargetEmptyLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
        }

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingIndicator.widthAnchor.constraint(equalToConstant: 12),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        chipRow.orientation = .horizontal
        chipRow.spacing = 5
        chipRow.alignment = .centerY
        chipRow.distribution = .fill
        for spacer in [leadingSpacer, translationSourceSpacer, translationTargetSpacer] {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        caretView.wantsLayer = true
        caretView.layer?.cornerRadius = 1
        caretView.translatesAutoresizingMaskIntoConstraints = false
        caretView.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caretView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        configureHorizontalRail(chipScroll, row: chipRow)
        chipScroll.heightAnchor.constraint(equalToConstant: 24).isActive = true

        normalRailContainer.addArrangedSubview(chipScroll)
        normalRailContainer.orientation = .horizontal
        normalRailContainer.alignment = .centerY
        normalRailContainer.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        normalRailContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(normalRailContainer)

        configureHorizontalRail(translationSourceScroll, row: translationSourceRow)
        configureHorizontalRail(translationTargetScroll, row: translationTargetRow)
        translationContainer.orientation = .vertical
        translationContainer.alignment = .width
        translationContainer.distribution = .fillEqually
        translationContainer.spacing = 4
        translationContainer.translatesAutoresizingMaskIntoConstraints = false
        translationContainer.addArrangedSubview(translationSourceScroll)
        translationContainer.addArrangedSubview(translationTargetScroll)
        translationContainer.isHidden = true
        addSubview(translationContainer)
        NSLayoutConstraint.activate([
            normalRailContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            normalRailContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            normalRailContainer.topAnchor.constraint(equalTo: topAnchor),
            normalRailContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            translationContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            translationContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            translationContainer.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            translationContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureHorizontalRail(_ scroll: NSScrollView, row: NSStackView) {
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.distribution = .fill
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.masksToBounds = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHairlineWidth()
    }

    override func layout() {
        super.layout()
        updateHairlineWidth()
        updateEnterHoldProgressLayer()
    }

    private func updateHairlineWidth() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.borderWidth = 1 / max(scale, 1)
    }

    func setEnterHoldProgress(_ progress: Double?) {
        enterHoldProgress = progress.map { CGFloat(min(max($0, 0), 1)) }
        updateEnterHoldProgressLayer()
    }

    private func updateEnterHoldProgressLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let enterHoldProgress {
            enterHoldProgressLayer.opacity = 1
            enterHoldProgressLayer.frame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width * enterHoldProgress,
                height: 2
            )
        } else {
            enterHoldProgressLayer.opacity = 0
            enterHoldProgressLayer.frame = .zero
        }
        CATransaction.commit()
    }

    @discardableResult
    func refresh(preedit: String = "", shielded: Bool = false) -> Bool {
        let model = BufferModel.shared
        let preeditText = preedit.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = model.active
        let translation: TranslationRailSnapshot?
        if AppleTranslationWorkspace.shared.isSelected {
            translation = AppleTranslationWorkspace.shared.railSnapshot
        } else {
            translation = AITextWorkspaceRouter.railSnapshot
        }
        contentShielded = shielded
        if shielded {
            setEnterHoldProgress(nil)
        }

        let signature = RenderSignature(
            blocks: model.blocks.map {
                RenderedBlock(id: $0.id,
                              text: $0.text,
                              origin: $0.origin,
                              pluginMetadata: $0.pluginMetadata)
            },
            insertionIndex: min(max(model.insertionIndex, 0), model.blocks.count),
            active: active,
            preedit: preeditText,
            loadingMessage: model.loadingMessage,
            loadingActive: model.transientLoadingActive,
            translation: translation,
            shielded: shielded,
            isNight: RimeUI.isNight
        )
        if signature == lastRenderSignature {
            isHidden = shielded
            applyAppearance()
            return false
        }
        lastRenderSignature = signature
        renderPassCount += 1

        resetRailContents()

        if shielded {
            normalRailContainer.isHidden = false
            translationContainer.isHidden = true
            emptyLabel.stringValue = "内容已隐藏"
            chipRow.addArrangedSubview(emptyLabel)
            stopCaretBlinking()
            isHidden = true
            applyAppearance()
            return true
        }


        if let translation {
            normalRailContainer.isHidden = true
            translationContainer.isHidden = false
            renderTranslation(translation, active: active)
            applyAppearance()
            layoutSubtreeIfNeeded()
            updateTranslationDocumentSizes()
            scrollTranslationRailsToEnd()
            isHidden = false
            return true
        }

        normalRailContainer.isHidden = false
        translationContainer.isHidden = true

        let insertionIndex = signature.insertionIndex
        if model.blocks.isEmpty, preeditText.isEmpty {
            emptyLabel.stringValue = model.loadingMessage ?? "等待暂存内容"
            if model.transientLoadingActive {
                chipRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
            }
            chipRow.addArrangedSubview(emptyLabel)
            if active {
                chipRow.addArrangedSubview(caretView)
            }
        } else if active {
            for index in 0...model.blocks.count {
                if index == insertionIndex {
                    if !preeditText.isEmpty {
                        chipRow.addArrangedSubview(preeditChip(text: preeditText))
                    }
                    chipRow.addArrangedSubview(caretView)
                }
                if index < model.blocks.count {
                    chipRow.addArrangedSubview(chip(for: model.blocks[index], index: index))
                }
            }
        } else {
            for (index, block) in model.blocks.enumerated() {
                chipRow.addArrangedSubview(chip(for: block, index: index))
            }
            if !preeditText.isEmpty {
                chipRow.addArrangedSubview(preeditChip(text: preeditText))
            }
        }
        if let message = model.loadingMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty,
           !(model.blocks.isEmpty && preeditText.isEmpty) {
            if model.transientLoadingActive {
                chipRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
            }
            chipRow.addArrangedSubview(messageChip(text: message))
        }

        active ? startCaretBlinking() : stopCaretBlinking()
        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToInsertionPoint()
        isHidden = false
        return true
    }

    /// Dev-only render seam used by the CLI smoke and visual previews. Runtime
    /// Runtime derived rails still come exclusively from their selected,
    /// trusted workspace.
    @discardableResult
    func renderTranslationForPreview(_ snapshot: TranslationRailSnapshot,
                                     active: Bool = true) -> Bool {
        lastRenderSignature = nil
        contentShielded = false
        resetRailContents()
        normalRailContainer.isHidden = true
        translationContainer.isHidden = false
        renderTranslation(snapshot, active: active)
        applyAppearance()
        layoutSubtreeIfNeeded()
        updateTranslationDocumentSizes()
        scrollTranslationRailsToEnd()
        isHidden = false
        return usesStackedTranslationLayout && translationRailCount == 2
    }

    private func renderTranslation(_ snapshot: TranslationRailSnapshot,
                                   active: Bool) {
        renderedBlockIDs.removeAll(keepingCapacity: true)
        translationSourceRow.addArrangedSubview(
            translationRoleLabel(snapshot.sourceRole, target: false)
        )
        if snapshot.sourceText.isEmpty {
            translationSourceEmptyLabel.stringValue = snapshot.sourceEmptyText
            translationSourceRow.addArrangedSubview(translationSourceEmptyLabel)
        } else {
            translationSourceRow.addArrangedSubview(translationChip(text: snapshot.sourceText,
                                                                     target: false))
        }
        if active { translationSourceRow.addArrangedSubview(caretView) }
        translationSourceRow.addArrangedSubview(translationSourceSpacer)

        translationTargetRow.addArrangedSubview(
            translationRoleLabel(snapshot.targetRole, target: true)
        )
        if snapshot.outputBlocks.isEmpty {
            switch snapshot.phase {
            case .waiting, .translating:
                translationTargetRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
                translationTargetRow.addArrangedSubview(messageChip(
                    text: snapshot.message ?? (snapshot.phase == .waiting
                        ? snapshot.waitingText
                        : snapshot.processingText)
                ))
            case .failed:
                translationTargetRow.addArrangedSubview(messageChip(
                    text: snapshot.message ?? "处理失败"
                ))
            case .unavailable:
                translationTargetRow.addArrangedSubview(messageChip(
                    text: snapshot.message ?? "插件不可用"
                ))
            case .idle, .ready:
                translationTargetEmptyLabel.stringValue = snapshot.targetEmptyText
                translationTargetRow.addArrangedSubview(translationTargetEmptyLabel)
            }
        } else {
            let targetIsCurrent = snapshot.phase == .ready
            for block in snapshot.outputBlocks {
                renderedBlockIDs.append(block.id)
                translationTargetRow.addArrangedSubview(translationChip(text: block.text,
                                                                         target: true,
                                                                         stale: !targetIsCurrent))
            }
            if snapshot.phase == .waiting || snapshot.phase == .translating {
                translationTargetRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
                translationTargetRow.addArrangedSubview(messageChip(
                    text: snapshot.message ?? snapshot.updatingText
                ))
            }
        }
        translationTargetRow.addArrangedSubview(translationTargetSpacer)
        active ? startCaretBlinking() : stopCaretBlinking()
    }

    private func translationRoleLabel(_ role: String, target: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: role)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = target ? RimeUI.accentBlue : RimeUI.textSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 14).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func translationChip(text: String,
                                 target: Bool,
                                 stale: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = RimeUI.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: target ? 900 : 1200).isActive = true

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 7)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = (target
            ? RimeUI.accentBlue.withAlphaComponent(RimeUI.isNight ? 0.22 : 0.14)
            : RimeUI.surface2).cgColor
        row.layer?.borderColor = RimeUI.border.cgColor
        row.layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.alphaValue = stale ? 0.55 : 1
        return row
    }

    /// Colored provenance dot for a non-local block. Rime commits (local typing)
    /// stay unbadged so ordinary use looks exactly as before; external origins
    /// get a 6pt dot whose color matches the source family.
    private func originBadge(for origin: Origin) -> NSView? {
        let color: NSColor
        switch origin {
        case .rime: return nil
        case .remotePeer: color = RimeUI.color(0x9B8CFF)        // paired Mac — violet
        case .marine, .plugin, .processor, .mcp:
            color = RimeUI.color(0xF59E0B) // local action/transform/agent — amber
        case .http, .sse, .ssh: color = RimeUI.color(0x4A9FD8)  // network feed — blue
        }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return dot
    }

    private func chip(for block: BufferModel.Block, index: Int) -> NSView {
        if renderedBlockIDs.count <= index {
            renderedBlockIDs.append(block.id)
        } else {
            renderedBlockIDs[index] = block.id
        }
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = RimeUI.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = blockToolTip(block)

        let row = NSStackView(views: [label])
        if let badge = originBadge(for: block.origin) {
            row.insertArrangedSubview(badge, at: 0)
            row.setCustomSpacing(5, after: badge)
        }
        if block.pluginMetadata?.incomplete == true {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.toolTip = "插件正在生成，当前内容不可发送或编辑"
            progress.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                progress.widthAnchor.constraint(equalToConstant: 10),
                progress.heightAnchor.constraint(equalToConstant: 10),
            ])
            row.addArrangedSubview(progress)
            progress.startAnimation(nil)
        }
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = RimeUI.accentBlue.withAlphaComponent(
            RimeUI.isNight ? 0.22 : 0.14
        ).cgColor
        box.layer?.cornerRadius = 6
        box.toolTip = blockToolTip(block)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func blockToolTip(_ block: BufferModel.Block) -> String {
        guard let metadata = block.pluginMetadata else { return block.text }
        var lines = [metadata.title, metadata.targetSummary]
            .compactMap { value -> String? in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
        if metadata.stale { lines.append("原投放目标已失效，接受前请重新确认") }
        if metadata.incomplete { lines.append("正在生成，完成并复核目标前不能发送") }
        if metadata.reviewedAsPlainText {
            lines.append("已人工确认并降级为普通文本；发送时不再绑定原目标")
        }
        lines.append(block.text)
        return lines.joined(separator: "\n")
    }

    private func preeditChip(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text
        label.textColor = RimeUI.textPrimary

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = RimeUI.accentBlue.withAlphaComponent(
            RimeUI.isNight ? 0.34 : 0.22
        ).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = RimeUI.accentBlue.withAlphaComponent(0.45).cgColor
        box.layer?.cornerRadius = 6
        box.toolTip = text
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func messageChip(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .systemOrange
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        box.layer?.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     symbolName: String,
                                     toolTip: String) {
        button.image = RimeUI.symbol(symbolName, pointSize: 13, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.toolTip = toolTip
        button.contentTintColor = RimeUI.textSecondary
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func clearArrangedSubviews(of row: NSStackView) {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func resetRailContents() {
        clearArrangedSubviews(of: chipRow)
        clearArrangedSubviews(of: translationSourceRow)
        clearArrangedSubviews(of: translationTargetRow)
        loadingIndicator.stopAnimation(nil)
        renderedBlockIDs.removeAll(keepingCapacity: true)
        chipRow.addArrangedSubview(leadingSpacer)
    }

    private func updateChipDocumentSize() {
        let fit = chipRow.fittingSize
        let documentWidth = max(fit.width, chipScroll.contentSize.width)
        chipRow.setFrameSize(NSSize(width: documentWidth, height: 24))
        chipRow.needsLayout = true
        chipRow.layoutSubtreeIfNeeded()
    }

    private func updateTranslationDocumentSizes() {
        updateDocumentSize(for: translationSourceRow, in: translationSourceScroll)
        updateDocumentSize(for: translationTargetRow, in: translationTargetScroll)
    }

    private func updateDocumentSize(for row: NSStackView, in scroll: NSScrollView) {
        let fit = row.fittingSize
        let documentWidth = max(fit.width, scroll.contentSize.width)
        let documentHeight = max(fit.height, scroll.contentSize.height)
        row.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
    }

    private func scrollTranslationRailsToEnd() {
        scrollToEnd(row: translationSourceRow, in: translationSourceScroll)
        scrollToEnd(row: translationTargetRow, in: translationTargetScroll)
    }

    private func scrollToEnd(row: NSView, in scroll: NSScrollView) {
        let maxX = max(0, row.frame.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollChipsToInsertionPoint() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        if BufferModel.shared.loadingMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            chipScroll.reflectScrolledClipView(chipScroll.contentView)
            return
        }
        guard BufferModel.shared.active else {
            chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            chipScroll.reflectScrolledClipView(chipScroll.contentView)
            return
        }

        let visible = chipScroll.contentView.bounds
        let caretFrame = caretView.frame.insetBy(dx: -14, dy: 0)
        var targetX = visible.minX
        if caretFrame.minX < visible.minX {
            targetX = max(0, caretFrame.minX)
        } else if caretFrame.maxX > visible.maxX {
            targetX = max(0, min(maxX, caretFrame.maxX - chipScroll.contentSize.width))
        } else {
            targetX = min(max(0, visible.minX), maxX)
        }

        chipScroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.borderColor = RimeUI.borderStrong.cgColor
        translationSourceScroll.layer?.backgroundColor = RimeUI.surface2
            .withAlphaComponent(RimeUI.isNight ? 0.70 : 0.78).cgColor
        translationTargetScroll.layer?.backgroundColor = RimeUI.accentBlue
            .withAlphaComponent(RimeUI.isNight ? 0.13 : 0.08).cgColor
        caretView.layer?.backgroundColor = RimeUI.accentBlue.cgColor
        enterHoldProgressLayer.backgroundColor = RimeUI.accentBlue.cgColor
        emptyLabel.textColor = RimeUI.isNight ? RimeUI.textSecondary : RimeUI.textMuted
        translationSourceEmptyLabel.textColor = RimeUI.textSecondary
        translationTargetEmptyLabel.textColor = RimeUI.textSecondary
    }

    private func startCaretBlinking() {
        guard caretView.layer?.animation(forKey: "bufferCaretBlink") == nil else { return }
        caretView.layer?.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.15
        animation.duration = 0.58
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caretView.layer?.add(animation, forKey: "bufferCaretBlink")
    }

    private func stopCaretBlinking() {
        caretView.layer?.removeAnimation(forKey: "bufferCaretBlink")
        caretView.layer?.opacity = 1
    }

}

/// A button that works on the first click inside a never-key panel.
class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HoldProgressButton: FirstMouseButton {
    var holdDuration: TimeInterval = 1.2

    private var holdStartedAt: CFAbsoluteTime = 0
    private var completed = false
    private var externalProgressActive = false
    private var progressAmount: CGFloat = 0
    private var progressVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupProgressDrawing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupProgressDrawing()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIconFillProgress()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        externalProgressActive = false
        beginHold()

        var tracking = true
        while tracking {
            if !completed {
                updateHoldProgress()
            }

            guard let window,
                  let next = window.nextEvent(
                    matching: NSEvent.EventTypeMask([.leftMouseDragged, .leftMouseUp]),
                    until: Date(timeIntervalSinceNow: 1.0 / 60.0),
                    inMode: .eventTracking,
                    dequeue: true
                  ) else {
                continue
            }

            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !bounds.insetBy(dx: -8, dy: -8).contains(point), !completed {
                    cancelHold()
                    tracking = false
                }
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }

        resetProgressAfterTracking()
    }

    func setExternalProgress(_ progress: Double?) {
        guard let progress else {
            guard externalProgressActive else { return }
            externalProgressActive = false
            setIconProgress(0, visible: false)
            return
        }

        externalProgressActive = true
        let clamped = CGFloat(min(max(progress, 0), 1))
        setIconProgress(clamped, visible: clamped > 0)
    }

    private func setupProgressDrawing() {
        wantsLayer = true
    }

    private func beginHold() {
        completed = false
        holdStartedAt = CFAbsoluteTimeGetCurrent()
        setIconProgress(0, visible: true)
    }

    private func updateHoldProgress() {
        let elapsed = CFAbsoluteTimeGetCurrent() - holdStartedAt
        let progress = min(max(elapsed / max(holdDuration, 0.1), 0), 1)
        setIconProgress(CGFloat(progress), visible: true)
        if progress >= 1 {
            completed = true
            sendAction(action, to: target)
        }
    }

    private func cancelHold() {
        completed = false
        setIconProgress(0, visible: false)
    }

    private func resetProgressAfterTracking() {
        if completed {
            setIconProgress(1, visible: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.externalProgressActive else { return }
            self.setIconProgress(0, visible: false)
            self.completed = false
        }
    }

    private func setIconProgress(_ progress: CGFloat, visible: Bool) {
        progressAmount = min(max(progress, 0), 1)
        progressVisible = visible
        needsDisplay = true
    }

    private func drawIconFillProgress() {
        guard progressVisible,
              progressAmount > 0,
              let symbol = image,
              let tinted = tintedSymbolImage(symbol, color: RimeUI.accentBlue) else {
            return
        }

        let rect = iconRect(for: symbol)
        guard rect.width > 0, rect.height > 0 else { return }

        let fillHeight = rect.height * progressAmount
        let clipRect = isFlipped
            ? NSRect(x: rect.minX, y: rect.maxY - fillHeight, width: rect.width, height: fillHeight)
            : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillHeight)

        NSGraphicsContext.saveGraphicsState()
        clipRect.clip()
        tinted.draw(in: rect,
                    from: NSRect(origin: .zero, size: tinted.size),
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func iconRect(for symbol: NSImage) -> NSRect {
        let maxSide = max(1, min(bounds.width, bounds.height) - 8)
        let imageSize = symbol.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let scale = min(1, maxSide / max(imageSize.width, imageSize.height))
        let drawSize = NSSize(width: imageSize.width * scale,
                              height: imageSize.height * scale)
        return NSRect(x: bounds.midX - drawSize.width / 2,
                      y: bounds.midY - drawSize.height / 2,
                      width: drawSize.width,
                      height: drawSize.height)
    }

    private func tintedSymbolImage(_ symbol: NSImage, color: NSColor) -> NSImage? {
        let image = NSImage(size: symbol.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: nil)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
