import Foundation

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
        InputSchemaOption(id: "my_combo", name: "并击", detail: "高速并击输入"),
        InputSchemaOption(id: "double_pinyin", name: "自然码双拼", detail: "雾凇词库 · 自然码键位"),
        InputSchemaOption(id: "rime_ice", name: "雾凇拼音", detail: "全拼输入"),
        InputSchemaOption(id: "english", name: "英文", detail: "候选、补全、生词兜底与用户学习"),
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
