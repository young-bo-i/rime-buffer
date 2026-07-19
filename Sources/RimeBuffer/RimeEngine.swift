import Foundation
import CRimeBridge

extension Notification.Name {
    /// Sent synchronously on the main thread before librime closes every
    /// session for a user-dictionary export/import. Controllers must settle
    /// marked text, destroy their session, and set the cached id to zero.
    static let rimeUserDictionaryMaintenanceWillBegin = Notification.Name(
        "RimeBuffer.RimeUserDictionaryMaintenance.willBegin"
    )

    /// Sent synchronously after the operation. Controllers recreate sessions
    /// lazily through their ordinary ensureSessionReady path.
    static let rimeUserDictionaryMaintenanceDidEnd = Notification.Name(
        "RimeBuffer.RimeUserDictionaryMaintenance.didEnd"
    )
}

/// Thin, INSTANTIABLE wrapper over the C bridge. Deliberately NOT a singleton
/// and holds NO shared session — each IMK controller owns its own session so
/// composition never bleeds across fields. (The prototype's `.shared` +
/// `sharedSession` cache are gone.)
final class RimeEngine {
    private var started = false

    private static let squirrelShared = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
    private static let squirrelFrameworks = "/Library/Input Methods/Squirrel.app/Contents/Frameworks"

    // Prefer the app's OWN bundled data + librime (self-contained install, no
    // Squirrel needed); fall back to a system Squirrel install for dev builds
    // run outside the .app. RIMEBUFFER_SHARED_DIR/RIMEBUFFER_FRAMEWORKS_DIR let
    // the CLI smoke harness point at a staged bundle without a full .app.
    private let sharedDataDir: String = {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_SHARED_DIR"],
           !override.isEmpty {
            return override
        }
        if let ss = Bundle.main.sharedSupportPath,
           FileManager.default.fileExists(atPath: ss + "/default.yaml") {
            return ss
        }
        return RimeEngine.squirrelShared
    }()
    private let frameworksDir: String = {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_FRAMEWORKS_DIR"],
           !override.isEmpty {
            return override
        }
        if let fw = Bundle.main.privateFrameworksPath,
           FileManager.default.fileExists(atPath: fw + "/librime.1.dylib") {
            return fw
        }
        return RimeEngine.squirrelFrameworks
    }()

    // Its OWN user dir (~/Library/RimeBuffer). Separate from Squirrel's so the
    // two never fight over the same userdb LevelDB lock — that lock conflict
    // silently kills candidates. First run deploys into it from sharedDataDir.
    // RIMEBUFFER_USER_DIR overrides it (used by the CLI smoke harness).
    private static let defaultUserDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/RimeBuffer").path
    private let userDataDir = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        ?? RimeEngine.defaultUserDir
    private let logDir = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        ?? RimeEngine.defaultUserDir

    /// dlopen + setup + initialize + smoke session. Retries on a later call if
    /// it failed (started stays false), so a transient failure isn't permanent.
    @discardableResult
    func start() -> Bool {
        if started { return true }
        // Ensure the user dir exists so the first-run deploy has a build target.
        try? FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
        started = BBRimeStart(sharedDataDir, userDataDir, logDir, frameworksDir)
        if started {
            IMELog.write("rime start OK shared=\(sharedDataDir) fw=\(frameworksDir) user=\(userDataDir)")
        } else {
            IMELog.write("rime start FAILED: \(lastError())")
        }
        return started
    }

    var isHealthy: Bool { BBRimeIsHealthy() }

    func createSession() -> UInt64 { BBRimeCreateSession() }
    func destroySession(_ session: UInt64) {
        guard session != 0 else { return }
        BBRimeDestroySession(session)
    }
    func sessionExists(_ session: UInt64) -> Bool {
        session != 0 && BBRimeSessionExists(session)
    }

    func processKey(_ keycode: Int32, mask: Int32 = 0, session: UInt64) -> Bool {
        BBRimeProcessKey(session, keycode, mask)
    }
    func commitComposition(session: UInt64) -> Bool { BBRimeCommitComposition(session) }
    func clearComposition(session: UInt64) { BBRimeClearComposition(session) }
    func selectCandidate(onPage index: Int, session: UInt64) -> Bool {
        BBRimeSelectCandidateOnCurrentPage(session, UInt64(index))
    }

    func getOption(_ name: String, session: UInt64) -> Bool {
        name.withCString { BBRimeGetOption(session, $0) }
    }
    func setOption(_ name: String, _ value: Bool, session: UInt64) {
        name.withCString { BBRimeSetOption(session, $0, value) }
    }
    func selectSchema(_ id: String, session: UInt64) -> Bool {
        id.withCString { BBRimeSelectSchema(session, $0) }
    }

    func takeCommit(session: UInt64) -> String? { takeString(BBRimeCopyCommit(session)) }
    func currentSchema(session: UInt64) -> String? { takeString(BBRimeCopySchema(session)) }
    func lastError() -> String { takeString(BBRimeCopyLastError()) ?? "" }

    /// Read a double from a deployed config, e.g. ("squirrel", "chord_duration").
    func configDouble(_ configId: String, _ key: String) -> Double? {
        var value = 0.0
        let ok = configId.withCString { c in
            key.withCString { k in BBRimeConfigGetDouble(c, k, &value) }
        }
        return ok ? value : nil
    }

    /// Schemas Rime has actually deployed (id + display name). Empty if the
    /// engine isn't up.
    func schemaList() -> [(id: String, name: String)] {
        var buf = [BBRimeSchema](repeating: BBRimeSchema(), count: 64)
        let count = Int(BBRimeGetSchemaList(&buf, 64))
        guard count > 0 else { return [] }
        return (0..<count).compactMap { i in
            guard let idPtr = buf[i].id else { return nil }
            let id = String(cString: idPtr)
            guard !id.isEmpty else { return nil }
            let name = buf[i].name.map { String(cString: $0) } ?? id
            return (id, name.isEmpty ? id : name)
        }
    }

    // MARK: User dictionary maintenance

    /// True when librime currently has a LevelDB for this `user_dict` name.
    /// Listing does not open or mutate the database and is safe while typing.
    func hasUserDictionary(named name: String) -> Bool {
        guard started, !name.isEmpty else { return false }
        return name.withCString { BBRimeHasUserDictionary($0) }
    }

    /// Export learned entries in librime's portable TSV format. This operation
    /// necessarily closes every Rime session so the LevelDB can be opened by
    /// the official levers manager. Call only on main: notification observers
    /// must first settle IMK marked text and invalidate their cached sessions.
    func exportUserDictionary(named name: String, to fileURL: URL) -> Int {
        performUserDictionaryMaintenance {
            name.withCString { dict in
                fileURL.path.withCString { path in
                    Int(BBRimeExportUserDictionary(dict, path))
                }
            }
        }
    }

    /// Merge portable TSV entries into the selected librime user dictionary.
    /// Existing frequencies are preserved/raised according to librime's own
    /// UserDbImporter rules; the LevelDB is never copied or replaced.
    func importUserDictionary(named name: String, from fileURL: URL) -> Int {
        performUserDictionaryMaintenance {
            name.withCString { dict in
                fileURL.path.withCString { path in
                    Int(BBRimeImportUserDictionary(dict, path))
                }
            }
        }
    }

    /// Merge a lossless `*.userdb.txt` snapshot. The snapshot itself declares
    /// its database name; UserLexiconService validates it before this call.
    func restoreUserDictionarySnapshot(from fileURL: URL) -> Bool {
        performUserDictionaryMaintenance {
            fileURL.path.withCString { path in
                BBRimeRestoreUserDictionarySnapshot(path) ? 0 : -1
            }
        } >= 0
    }

    private func performUserDictionaryMaintenance(_ operation: () -> Int) -> Int {
        guard Thread.isMainThread, started else { return -1 }
        NotificationCenter.default.post(name: .rimeUserDictionaryMaintenanceWillBegin,
                                        object: self)
        let result = operation()
        NotificationCenter.default.post(name: .rimeUserDictionaryMaintenanceDidEnd,
                                        object: self,
                                        userInfo: ["succeeded": result >= 0])
        return result
    }

    // MARK: Context / status

    func getContext(session: UInt64) -> RimeContextModel {
        var ctx = BBRimeContext()
        guard BBRimeGetContext(session, &ctx) else { return RimeContextModel() }

        var model = RimeContextModel()
        model.active = ctx.active
        model.preedit = ctx.preedit.map { String(cString: $0) } ?? ""
        model.input = ctx.input.map { String(cString: $0) } ?? ""
        model.cursorPos = Int(ctx.cursorPos)
        model.selStart = Int(ctx.selStart)
        model.selEnd = Int(ctx.selEnd)
        model.pageSize = Int(ctx.pageSize)
        model.pageNo = Int(ctx.pageNo)
        model.isLastPage = ctx.isLastPage
        model.highlightedIndex = Int(ctx.highlightedIndex)

        let count = Int(ctx.numCandidates)
        if count > 0 {
            let cap = Int(BB_MAX_CANDIDATES)
            withUnsafePointer(to: &ctx.candidates) { tuplePtr in
                tuplePtr.withMemoryRebound(to: BBRimeCandidate.self, capacity: cap) { arr in
                    for i in 0..<min(count, cap) {
                        let c = arr[i]
                        model.candidates.append(RimeCandidateModel(
                            text: c.text.map { String(cString: $0) } ?? "",
                            comment: c.comment.map { String(cString: $0) } ?? "",
                            label: c.label.map { String(cString: $0) } ?? ""))
                    }
                }
            }
        }
        return model
    }

    func getStatus(session: UInt64) -> RimeStatusModel {
        var st = BBRimeStatus()
        guard BBRimeGetStatus(session, &st) else { return RimeStatusModel() }
        var m = RimeStatusModel()
        m.schemaId = st.schemaId.map { String(cString: $0) } ?? ""
        m.schemaName = st.schemaName.map { String(cString: $0) } ?? ""
        m.asciiMode = st.asciiMode
        m.fullShape = st.fullShape
        m.simplified = st.simplified
        m.traditional = st.traditional
        m.asciiPunct = st.asciiPunct
        m.composing = st.composing
        m.disabled = st.disabled
        return m
    }

    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        BBRimeFreeString(pointer)
        return value.isEmpty ? nil : value
    }
}
