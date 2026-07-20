import Foundation

enum InputEncoding: String, CaseIterable, Codable {
    case naturalDoublePinyin
    case fullPinyin
    case english

    var title: String {
        switch self {
        case .naturalDoublePinyin: return "自然码双拼"
        case .fullPinyin: return "全拼"
        case .english: return "英文"
        }
    }
}

enum KeyingMode: String, CaseIterable, Codable {
    case sequential
    case chord
    case mutual

    var title: String {
        switch self {
        case .sequential: return "串击"
        case .chord: return "并击"
        case .mutual: return "互击"
        }
    }

    var implementationName: String? {
        switch self {
        case .chord: return "飞耀并击"
        case .mutual: return "飞耀互击"
        case .sequential: return nil
        }
    }
}

struct InputConfiguration: Equatable, Codable {
    var encoding: InputEncoding
    var keyingMode: KeyingMode

    static let defaultValue = InputConfiguration(encoding: .fullPinyin,
                                                 keyingMode: .mutual)
}

struct RuntimeInputProfile: Equatable {
    enum LexiconFamily: String {
        case chinese
        case english
    }

    let configuration: InputConfiguration
    let schemaID: String
    let lexiconFamily: LexiconFamily
}

enum InputConfigurationResolver {
    static let profiles: [RuntimeInputProfile] = [
        RuntimeInputProfile(
            configuration: .init(encoding: .naturalDoublePinyin,
                                 keyingMode: .sequential),
            schemaID: "double_pinyin",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .sequential),
            schemaID: "rime_ice",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .chord),
            schemaID: "my_combo",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .mutual),
            schemaID: "my_combo",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .english,
                                 keyingMode: .sequential),
            schemaID: "english",
            lexiconFamily: .english
        ),
    ]

    static func profile(for configuration: InputConfiguration) -> RuntimeInputProfile? {
        profiles.first { $0.configuration == configuration }
    }

    static func profile(schemaID: String) -> RuntimeInputProfile? {
        // F4 can identify the Rime schema but cannot encode the host-side
        // same-batch/cross-batch settlement policy. FlyYao is now canonically
        // the mutual scheme; callers that are already on my_combo preserve
        // their complete configuration in InputConfigurationStore.adoptRuntimeSchema.
        if schemaID == "my_combo" {
            return profile(for: .init(encoding: .fullPinyin, keyingMode: .mutual))
        }
        return profiles.first { $0.schemaID == schemaID }
    }

    static func selecting(_ encoding: InputEncoding,
                          from current: InputConfiguration) -> InputConfiguration {
        var next = current
        next.encoding = encoding
        if encoding != .fullPinyin, next.keyingMode != .sequential {
            next.keyingMode = .sequential
        }
        return next
    }

    static func selecting(_ keyingMode: KeyingMode,
                          from current: InputConfiguration) -> InputConfiguration? {
        var next = current
        next.keyingMode = keyingMode
        if keyingMode == .chord || keyingMode == .mutual {
            next.encoding = .fullPinyin
        }
        return profile(for: next) == nil ? nil : next
    }
}

extension Notification.Name {
    static let inputConfigurationDidChange = Notification.Name(
        "RimeBuffer.InputConfiguration.didChange"
    )
}

final class InputConfigurationStore {
    static let shared = InputConfigurationStore()

    private enum Key {
        static let encoding = "input.configuration.encoding.v1"
        static let keyingMode = "input.configuration.keyingMode.v1"
        static let preferredSchema = "preferredSchema"
        static let semanticsVersion = "input.configuration.keyingMode.semantics.v2"
    }

    private static let currentSemanticsVersion = 2

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: InputConfiguration {
        if let encodingRaw = defaults.string(forKey: Key.encoding),
           let keyingRaw = defaults.string(forKey: Key.keyingMode),
           let encoding = InputEncoding(rawValue: encodingRaw),
           let keyingMode = KeyingMode(rawValue: keyingRaw) {
            let stored = InputConfiguration(encoding: encoding, keyingMode: keyingMode)
            if InputConfigurationResolver.profile(for: stored) != nil {
                let semanticsVersion = defaults.integer(forKey: Key.semanticsVersion)
                // Before 互击 existed, every FlyYao user was necessarily saved
                // as `.chord` even though the runtime already allowed one-sided
                // keys.  Reclassify that one legacy state exactly once; a user
                // selecting same-batch 并击 after this version is then preserved.
                if semanticsVersion < Self.currentSemanticsVersion,
                   stored == .init(encoding: .fullPinyin, keyingMode: .chord) {
                    let migrated = InputConfiguration(
                        encoding: .fullPinyin,
                        keyingMode: .mutual
                    )
                    persist(migrated, notify: false)
                    return migrated
                }
                if semanticsVersion < Self.currentSemanticsVersion {
                    defaults.set(Self.currentSemanticsVersion,
                                 forKey: Key.semanticsVersion)
                }
                return stored
            }
        }

        let migrated = defaults.string(forKey: Key.preferredSchema)
            .flatMap(InputConfigurationResolver.profile(schemaID:))?
            .configuration ?? .defaultValue
        persist(migrated, notify: false)
        return migrated
    }

    var runtimeProfile: RuntimeInputProfile {
        InputConfigurationResolver.profile(for: configuration)
            ?? InputConfigurationResolver.profile(for: .defaultValue)!
    }

    @discardableResult
    func select(encoding: InputEncoding) -> Bool {
        set(InputConfigurationResolver.selecting(encoding, from: configuration))
    }

    /// Returns false for a mode that has no installed runtime implementation.
    /// The old valid selection is preserved, so settings can never leave the
    /// live IME pointing at a schema that does not exist.
    @discardableResult
    func select(keyingMode: KeyingMode) -> Bool {
        guard let next = InputConfigurationResolver.selecting(
            keyingMode,
            from: configuration
        ) else { return false }
        return set(next)
    }

    @discardableResult
    func adoptRuntimeSchema(_ schemaID: String) -> Bool {
        let current = configuration
        if InputConfigurationResolver.profile(for: current)?.schemaID == schemaID {
            return set(current)
        }
        guard let profile = InputConfigurationResolver.profile(schemaID: schemaID) else {
            return false
        }
        return set(profile.configuration)
    }

    @discardableResult
    func set(_ configuration: InputConfiguration) -> Bool {
        guard let profile = InputConfigurationResolver.profile(for: configuration) else {
            return false
        }
        let changed = self.configuration != configuration
            || defaults.string(forKey: Key.preferredSchema) != profile.schemaID
        persist(configuration, notify: changed)
        return true
    }

    private func persist(_ configuration: InputConfiguration, notify: Bool) {
        guard let profile = InputConfigurationResolver.profile(for: configuration) else {
            return
        }
        defaults.set(configuration.encoding.rawValue, forKey: Key.encoding)
        defaults.set(configuration.keyingMode.rawValue, forKey: Key.keyingMode)
        defaults.set(profile.schemaID, forKey: Key.preferredSchema)
        if defaults.integer(forKey: Key.semanticsVersion) < Self.currentSemanticsVersion {
            defaults.set(Self.currentSemanticsVersion, forKey: Key.semanticsVersion)
        }
        if notify {
            NotificationCenter.default.post(name: .inputConfigurationDidChange,
                                            object: self)
        }
    }
}

struct InputSchemaOption {
    let id: String
    let name: String
    let detail: String
}

/// The product-level schema catalog. Supporting schemas such as melt_eng and
/// radical_pinyin stay on disk as dependencies, but never appear here or in
/// the user's F4 switcher.
enum InputSchemaCatalog {
    static let options: [InputSchemaOption] = [
        InputSchemaOption(id: "my_combo", name: "飞耀互击", detail: "内部运行方案"),
        InputSchemaOption(id: "double_pinyin", name: "自然码双拼", detail: "内部运行方案"),
        InputSchemaOption(id: "rime_ice", name: "雾凇拼音", detail: "内部运行方案"),
        InputSchemaOption(id: "english", name: "英文", detail: "内部运行方案"),
    ]

    static var defaultEnabledIDs: [String] { options.map(\.id) }

    static func normalized(_ ids: [String]) -> [String] {
        let requested = Set(ids)
        return options.map(\.id).filter(requested.contains)
    }
}

/// Reads and rewrites only `patch.schema_list` while preserving the rest of
/// default.custom.yaml (menu size and future unrelated settings).
enum SchemaListStore {
    enum StoreError: LocalizedError {
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .emptySelection: return "至少保留一个输入方案。"
            }
        }
    }

    static func enabledIDs(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "schema_list:"
        }) else { return [] }

        let baseIndent = leadingSpaceCount(lines[start])
        var ids: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if leadingSpaceCount(line) <= baseIndent { break }
            guard trimmed.hasPrefix("- schema:") else { continue }
            let rawID = trimmed
                .dropFirst("- schema:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let id = String(rawID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !id.isEmpty { ids.append(id) }
        }
        return InputSchemaCatalog.normalized(ids)
    }

    static func writeEnabledIDs(_ requestedIDs: [String], to url: URL) throws {
        let ids = InputSchemaCatalog.normalized(requestedIDs)
        guard !ids.isEmpty else { throw StoreError.emptySelection }

        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "patch:\n  schema_list:\n  menu:\n    page_size: 9\n"
        var lines = text.components(separatedBy: .newlines)
        let itemLines = ids.map { "    - schema: \($0)" }

        if let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "schema_list:"
        }) {
            let baseIndent = leadingSpaceCount(lines[start])
            var end = start + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, leadingSpaceCount(lines[end]) <= baseIndent { break }
                end += 1
            }
            lines.replaceSubrange((start + 1)..<end, with: itemLines + [""])
        } else if let patchIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "patch:"
        }) {
            lines.insert(contentsOf: ["  schema_list:"] + itemLines + [""], at: patchIndex + 1)
        } else {
            if !lines.isEmpty, lines.last != "" { lines.append("") }
            lines.append(contentsOf: ["patch:", "  schema_list:"] + itemLines + [""])
        }

        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
