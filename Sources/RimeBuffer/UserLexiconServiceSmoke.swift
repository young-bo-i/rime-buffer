import Foundation

private final class UserLexiconFakeEngine: UserLexiconEngine {
    var isHealthy = true
    var existing = Set<String>()
    var exportedText = "# Rime user dictionary export\nni hao \t你好\t100\n"
    private(set) var importedDictionary: String?
    private(set) var importedText = ""

    func hasUserDictionary(named name: String) -> Bool { existing.contains(name) }

    func exportUserDictionary(named name: String, to fileURL: URL) -> Int {
        do {
            try Data(exportedText.utf8).write(to: fileURL)
            return 1
        } catch {
            return -1
        }
    }

    func importUserDictionary(named name: String, from fileURL: URL) -> Int {
        importedDictionary = name
        importedText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return importedText.contains("\t") ? 1 : -1
    }

    func restoreUserDictionarySnapshot(from fileURL: URL) -> Bool {
        importedDictionary = "snapshot"
        importedText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return importedText.contains("#@/db_name")
    }
}

@discardableResult
func runUserLexiconServiceSmokeTest() -> Bool {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("rimebuffer-user-lexicon-smoke-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    do {
        try fm.createDirectory(at: root,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let engine = UserLexiconFakeEngine()
        engine.existing.insert(UserLexiconKind.chinese.dictionaryName)
        let service = UserLexiconService(engine: engine,
                                         temporaryDirectory: root.appendingPathComponent("private"))

        guard service.status(for: .chinese).hasLearningDatabase,
              !service.status(for: .english).hasLearningDatabase else {
            print("user-lexicon-smoke: status mapping failed")
            return false
        }

        let exportedURL = root.appendingPathComponent("chinese.tsv")
        let exportResult = try service.exportLearningData(.chinese, to: exportedURL)
        let exported = try String(contentsOf: exportedURL, encoding: .utf8)
        let attrs = try fm.attributesOfItem(atPath: exportedURL.path)
        guard exportResult.entryCount == 1,
              exported.contains("#@/db_name\trime_ice"),
              exported.contains("你好"),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            print("user-lexicon-smoke: self-describing export failed")
            return false
        }

        let importResult = try service.importLearningData(.chinese, from: exportedURL)
        guard importResult.entryCount == 1,
              importResult.sourceWasSelfDescribing,
              engine.importedDictionary == "rime_ice",
              engine.importedText.contains("你好") else {
            print("user-lexicon-smoke: import routing failed")
            return false
        }

        engine.exportedText = "# Rime user dictionary export\n"
        do {
            _ = try service.exportLearningData(
                .chinese,
                to: root.appendingPathComponent("empty-learning.tsv")
            )
            print("user-lexicon-smoke: empty userdb was presented as learned entries")
            return false
        } catch UserLexiconServiceError.noLearningEntries {
            // A userdb can exist before it has any learned row.
        }

        let snapshotURL = root.appendingPathComponent("english.userdb.txt")
        let snapshot = """
        # Rime user dictionary
        #@/db_name\tenglish
        #@/db_type\tuserdb
        #@/tick\t9
        codex \tcodex\tc=4 d=1 t=9

        """
        try snapshot.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let snapshotResult = try service.importLearningData(.english, from: snapshotURL)
        guard snapshotResult.entryCount == 1,
              snapshotResult.sourceWasSelfDescribing,
              engine.importedDictionary == "snapshot" else {
            print("user-lexicon-smoke: lossless snapshot routing failed")
            return false
        }

        do {
            _ = try service.importLearningData(.english, from: exportedURL)
            print("user-lexicon-smoke: cross-dictionary import was accepted")
            return false
        } catch UserLexiconServiceError.wrongDictionary {
            // expected
        }

        let malformed = root.appendingPathComponent("dictionary.yaml")
        try "---\nname: not-a-userdb\n".write(to: malformed,
                                                    atomically: true,
                                                    encoding: .utf8)
        do {
            _ = try service.importLearningData(.chinese, from: malformed)
            print("user-lexicon-smoke: schema YAML was accepted as learning data")
            return false
        } catch UserLexiconServiceError.malformedLine {
            // expected
        }

        let link = root.appendingPathComponent("linked.tsv")
        try fm.createSymbolicLink(at: link, withDestinationURL: exportedURL)
        do {
            _ = try service.importLearningData(.chinese, from: link)
            print("user-lexicon-smoke: symlink import was accepted")
            return false
        } catch UserLexiconServiceError.sourceIsSymbolicLink {
            // expected
        }

        print("user-lexicon-smoke: PASS")
        return true
    } catch {
        print("user-lexicon-smoke: FAIL \(error.localizedDescription)")
        return false
    }
}

/// Real levers/LevelDB proof. Run in a dedicated process with an isolated
/// RIMEBUFFER_USER_DIR; it never touches the installed input method or asks it
/// to restart.
@discardableResult
func runRimeUserLexiconBridgeSmokeTest() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let isolatedPath = environment["RIMEBUFFER_USER_DIR"], !isolatedPath.isEmpty else {
        print("user-lexicon-bridge-smoke: REFUSED (set isolated RIMEBUFFER_USER_DIR)")
        return false
    }
    let root = URL(fileURLWithPath: isolatedPath, isDirectory: true)
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard rimeEngine.start(), rimeEngine.isHealthy else {
            print("user-lexicon-bridge-smoke: engine start failed: \(rimeEngine.lastError())")
            return false
        }
        let service = UserLexiconService(engine: rimeEngine,
                                         temporaryDirectory: root.appendingPathComponent("tmp/lexicon"))
        let input = root.appendingPathComponent("bridge-import.tsv")
        let output = root.appendingPathComponent("bridge-export.tsv")
        let fixture = "# Rime user dictionary export\ncodex \tcodex\t100\n"
        try fixture.write(to: input, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)

        let imported = try service.importLearningData(.english, from: input)
        guard imported.entryCount == 1,
              rimeEngine.hasUserDictionary(named: "english") else {
            print("user-lexicon-bridge-smoke: official import failed")
            return false
        }
        let exported = try service.exportLearningData(.english, to: output)
        let outputText = try String(contentsOf: output, encoding: .utf8)
        guard exported.entryCount >= 1,
              outputText.contains("#@/db_name\tenglish"),
              outputText.contains("\tcodex\t") else {
            print("user-lexicon-bridge-smoke: official export failed")
            return false
        }

        // The bridge deliberately invalidates all old sessions. A fresh one
        // must still be constructible immediately after maintenance.
        let fresh = rimeEngine.createSession()
        guard fresh != 0, rimeEngine.sessionExists(fresh) else {
            print("user-lexicon-bridge-smoke: session recovery failed")
            return false
        }
        rimeEngine.destroySession(fresh)
        print("user-lexicon-bridge-smoke: PASS imported=\(imported.entryCount) exported=\(exported.entryCount)")
        return true
    } catch {
        print("user-lexicon-bridge-smoke: FAIL \(error.localizedDescription)")
        return false
    }
}
