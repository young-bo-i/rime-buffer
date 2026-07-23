import AppKit
import Foundation

enum BuiltInPluginID {
    static let statistics = "builtin.statistics"
    static let typingSpeed = "builtin.typing-speed"
    static let flyChordLearning = "builtin.fly-chord-learning"
    static let appleTranslation = "builtin.apple-translation"
    static let streamInput = "builtin.stream-input"
    static let aiText = AITextBuiltInPluginID.aiText
    // Provider-specific IDs are retained for preference/source compatibility.
    static let codexCLI = AITextBuiltInPluginID.codexCLI
    static let claudeCodeCLI = AITextBuiltInPluginID.claudeCodeCLI
    static let openAICompatible = AITextBuiltInPluginID.openAICompatible
}

enum BuiltInPlugins {
    static func makeAll() -> [any InternalPlugin] {
        [
            StatisticsInternalPlugin(),
            TypingSpeedInternalPlugin(),
            FlyChordLearningInternalPlugin(),
            AppleTranslationInternalPlugin(),
            StreamInputInternalPlugin(),
            AITextInternalPlugin(),
        ]
    }
}

/// Synchronously flushes the aggregate-only metrics owned by built-in
/// extensions. Direct `exit(0)` paths do not deliver AppKit termination
/// notifications, so restart/update actions call this explicitly.
enum InputMetricsPersistence {
    static func saveNow() {
        KeyFrequencyStore.shared.saveNow()
        TypingSpeedStore.shared.saveNow()
    }
}

private final class StatisticsInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.statistics),
        wireID: nil,
        name: "统计",
        symbolName: "chart.bar.xaxis",
        version: "1.0",
        summary: "按日查看键盘热力图与全部历史趋势；仅保存本地计数。",
        source: .builtIn,
        capabilities: [.settingsPage, .keyMetrics, .localStorage],
        settings: PluginSettingsContribution(
            id: "statistics",
            title: "统计",
            symbolName: "chart.bar.xaxis",
            subpages: [
                PluginSettingsSubpage(id: "daily", title: "每日"),
                PluginSettingsSubpage(id: "history", title: "历史"),
            ]
        ),
        canUninstall: false
    )

    private var observation: InputTelemetryObservation?

    func start() {
        guard observation == nil else { return }
        observation = InputTelemetryBus.shared.observe { event in
            guard case let .key(key) = event else { return }
            KeyFrequencyStore.shared.record(
                keyID: key.keyID,
                at: Date(timeIntervalSince1970: key.timestamp)
            )
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        KeyFrequencyStore.shared.saveNow()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeStatistics(subpageID: subpageID)
    }
}

private final class TypingSpeedInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.typingSpeed),
        wireID: nil,
        name: "打字测速",
        symbolName: "speedometer",
        version: "1.0",
        summary: "按活跃输入时间计算按键和成文字符速度；成文字符按 Rime commit 计数，不保存输入正文。",
        source: .builtIn,
        capabilities: [.settingsPage, .keyMetrics, .commitMetrics, .localStorage],
        settings: PluginSettingsContribution(
            id: "typing-speed",
            title: "打字测速",
            symbolName: "speedometer",
            subpages: [
                PluginSettingsSubpage(id: "overview", title: "概览"),
                PluginSettingsSubpage(id: "history", title: "历史"),
            ]
        ),
        canUninstall: false
    )

    private var observation: InputTelemetryObservation?

    func start() {
        guard observation == nil else { return }
        observation = InputTelemetryBus.shared.observe { event in
            TypingSpeedStore.shared.consume(event)
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        TypingSpeedStore.shared.saveNow()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeTypingSpeed(subpageID: subpageID)
    }
}

private final class FlyChordLearningInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.flyChordLearning),
        wireID: nil,
        name: "飞耀互击学习",
        symbolName: "hands.sparkles",
        version: "1.0",
        summary: "从飞耀互击方案生成课程与专项练习，进度只保存在本机。",
        source: .builtIn,
        capabilities: [.settingsPage, .chordLearning, .localStorage],
        settings: PluginSettingsContribution(
            id: "fly-chord-learning",
            title: "飞耀互击学习",
            symbolName: "hands.sparkles",
            subpages: [
                PluginSettingsSubpage(id: "lessons", title: "课程"),
                PluginSettingsSubpage(id: "practice", title: "练习"),
                PluginSettingsSubpage(id: "progress", title: "进度"),
            ]
        ),
        canUninstall: false
    )

    func start() {}
    func stop() {}

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeFlyChordLearning(subpageID: subpageID)
    }
}

private final class AppleTranslationInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.appleTranslation),
        wireID: nil,
        name: "苹果本地翻译",
        symbolName: "character.book.closed",
        version: "1.0",
        summary: "把源缓冲区全文在本机翻译到独立目标缓冲区。",
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        AppleTranslationWorkspace.shared.start()
    }

    func stop() {
        AppleTranslationWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }
}

private final class AITextInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: AITextBuiltInPluginID.key,
        wireID: nil,
        name: "AI 生成",
        symbolName: "sparkles",
        version: "2.0",
        summary: "使用设置中选定的 Codex、Claude Code 或通用 Open API（OpenAI 兼容）连接器生成独立目标缓冲区。",
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        migrateLegacyProviderSelectionIfNeeded()
        AITextPluginRuntimeRegistry.shared.workspace.start()
    }

    func stop() {
        AITextPluginRuntimeRegistry.shared.workspace.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    private func migrateLegacyProviderSelectionIfNeeded() {
        let bufferSelection = BufferPluginSelectionStore.shared
        guard let legacyKind = AITextProviderKind.legacyKind(
            for: bufferSelection.activeKey
        ) else { return }
        AITextConnectorSelectionStore.shared.select(legacyKind)
        _ = bufferSelection.select(
            descriptor.key,
            among: [RegisteredPlugin(descriptor: descriptor, isEnabled: true)]
        )
    }
}

private final class StreamInputInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: StreamInputWorkspace.pluginKey,
        wireID: nil,
        name: "意识流输入",
        symbolName: "waveform",
        version: "1.0",
        summary: "连续输入不分词的全拼，由已配置的低延迟 OpenAI 兼容模型实时给出 1–3 个完整猜测。",
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        StreamInputWorkspace.shared.start()
    }

    func stop() {
        StreamInputWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }
}

/// Kept behind a tiny factory so the plugin model has no knowledge of the
/// settings window's routing shell. Each call returns a page-owned controller.
enum BuiltInPluginPageFactory {
    static func makeStatistics(subpageID: String) -> NSViewController {
        StatisticsSettingsViewController(subpageID: subpageID)
    }

    static func makeTypingSpeed(subpageID: String) -> NSViewController {
        TypingSpeedSettingsViewController(subpageID: subpageID)
    }

    static func makeFlyChordLearning(subpageID: String) -> NSViewController {
        FlyChordLearningSettingsViewController(subpageID: subpageID)
    }
}
