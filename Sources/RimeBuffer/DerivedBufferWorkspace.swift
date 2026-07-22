import Foundation

extension Notification.Name {
    static let derivedBufferWorkspaceDidChange = Notification.Name(
        "RimeBuffer.DerivedBufferWorkspace.didChange"
    )
}

/// Shared presentation/lifecycle surface for trusted two-rail workspaces. The
/// concrete workspace remains the delivery source so ObjectIdentifier-based
/// generation checks never depend on short-lived adapters.
protocol DerivedBufferWorkspace: BufferDeliveryContentSource {
    var workspacePluginKey: PluginKey { get }
    var workbenchDisplayName: String { get }
    var railSnapshot: TranslationRailSnapshot { get }
    var statusText: String { get }

    func setProtected(_ protected: Bool)
    @discardableResult func requestRefresh() -> Bool
    func workbenchWillPause()
}

extension DerivedBufferWorkspace {
    func workbenchWillPause() {}
}

/// Optional controls are capabilities of a selected derived workspace, not
/// hard-coded cases in the workbench window.
protocol DerivedLanguagePairControls: AnyObject {
    var languageOptions: [TranslationLanguageOption] { get }
    var sourceLanguageID: String { get }
    var targetLanguageID: String { get }
    var canSwapLanguages: Bool { get }
    func setSourceLanguage(_ identifier: String)
    func setTargetLanguage(_ identifier: String)
    @discardableResult func swapLanguages() -> Bool
}

enum DerivedManualGenerationPrimaryAction: Equatable {
    case disabled
    case requestGeneration
    case generating
    case deliver

    var beginsDeliveryGesture: Bool { self == .deliver }
}

enum DerivedManualGenerationPrimaryActionRules {
    static func resolve(isGenerating: Bool,
                        hasReadyDelivery: Bool,
                        canGenerate: Bool) -> DerivedManualGenerationPrimaryAction {
        if isGenerating { return .generating }
        if hasReadyDelivery { return .deliver }
        if canGenerate { return .requestGeneration }
        return .disabled
    }
}

protocol DerivedManualGenerationControls: AnyObject {
    var canGenerate: Bool { get }
    var isGenerating: Bool { get }
    var generationProviderName: String { get }
    var primaryAction: DerivedManualGenerationPrimaryAction { get }
    @discardableResult func generate() -> Bool
}

extension AppleTranslationWorkspace: DerivedBufferWorkspace,
                                     DerivedLanguagePairControls {
    var workspacePluginKey: PluginKey { Self.pluginKey }
    var workbenchDisplayName: String { "苹果本地翻译" }

    @discardableResult
    func requestRefresh() -> Bool {
        resetAndRefresh()
        return true
    }
}

extension AITextPluginWorkspace: DerivedBufferWorkspace,
                                 DerivedManualGenerationControls {
    var workspacePluginKey: PluginKey { pluginKey }
    var workbenchDisplayName: String { "AI 生成 · \(kind.displayName)" }
    var isGenerating: Bool { phase == .running }
    var generationProviderName: String { kind.displayName }
    var primaryAction: DerivedManualGenerationPrimaryAction {
        DerivedManualGenerationPrimaryActionRules.resolve(
            isGenerating: isGenerating,
            hasReadyDelivery: phase == .ready && !deliveryPendingBlocks.isEmpty,
            canGenerate: canGenerate
        )
    }

    @discardableResult
    func requestRefresh() -> Bool { resetAndRefresh() }

    func workbenchWillPause() { reset() }
}

/// The array stores the stable singleton objects themselves. Returning a new
/// adapter on each lookup would make BufferDeliveryCoordinator reject a valid
/// in-flight generation as changed content.
enum DerivedBufferWorkspaceRouter {
    private static var all: [any DerivedBufferWorkspace] {
        [
            AppleTranslationWorkspace.shared,
            AITextPluginRuntimeRegistry.shared.workspace,
            StreamInputWorkspace.shared,
        ]
    }

    static var selectedWorkspace: (any DerivedBufferWorkspace)? {
        guard let activeKey = BufferPluginSelectionStore.shared.activeKey else {
            return nil
        }
        if activeKey == StreamInputWorkspace.pluginKey,
           InputConfigurationStore.shared.configuration
                != StreamInputCaptureRules.requiredConfiguration {
            // An incompatible schema must immediately restore the ordinary
            // BufferModel rail. StreamInputWorkspace will clear the stale
            // owner selection asynchronously, but routing cannot wait for that
            // notification round-trip without hiding regular buffered text.
            return nil
        }
        return all.first { $0.workspacePluginKey == activeKey }
    }

    static func setProtectedOnAll(_ protected: Bool) {
        all.forEach { $0.setProtected(protected) }
    }
}
