import Foundation
import Darwin

// MARK: - Plugin management model

struct ManagedActionPlugin: Identifiable, Equatable {
    let plugin: InstalledActionPlugin
    let isEnabled: Bool

    var id: String { plugin.manifest.id }
    var name: String { plugin.manifest.name }
    var version: String? { plugin.manifest.version }
    var actions: [ActionPluginDefinition] { plugin.manifest.actions }
    var enabled: Bool { isEnabled }
    var manifest: ActionPluginManifest { plugin.manifest }
    var directory: URL { plugin.directory }
}

enum ActionPluginManagementError: LocalizedError {
    case pluginNotFound(String)
    case alreadyInstalled(String)
    case invalidManifest
    case invalidSource
    case unsafeSource(String)
    case destinationConflict(String)
    case sourceTooLarge
    case downloadRequiresHTTPS
    case downloadFailed
    case downloadStatus(Int)
    case staleDownload
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case let .pluginNotFound(id):
            return "未找到插件：\(id)"
        case let .alreadyInstalled(id):
            return "插件已安装：\(id)"
        case .invalidManifest:
            return "插件清单无效或版本不受支持"
        case .invalidSource:
            return "请选择 manifest.json 或包含它的插件目录"
        case let .unsafeSource(path):
            return "插件包含不安全的文件：\(path)"
        case let .destinationConflict(path):
            return "目标目录属于另一个插件，已拒绝覆盖：\(path)"
        case .sourceTooLarge:
            return "插件超过安装大小或文件数量限制"
        case .downloadRequiresHTTPS:
            return "插件下载地址必须是 HTTPS manifest.json 地址"
        case .downloadFailed:
            return "插件清单下载失败"
        case let .downloadStatus(code):
            return "插件服务器返回 HTTP \(code)"
        case .staleDownload:
            return "下载期间插件状态已变化，请重试安装"
        case let .fileOperation(message):
            return "插件文件操作失败：\(message)"
        }
    }
}

protocol ActionPluginManifestDownloading: AnyObject {
    func downloadManifest(from url: URL,
                          completion: @escaping (Result<Data, Error>) -> Void)
}

/// HTTPS-only, redirect-safe downloader for a single manifest. A remote
/// install deliberately cannot unpack archives or execute installer code.
final class ActionPluginHTTPSManifestDownloader: NSObject,
                                                 ActionPluginManifestDownloading,
                                                 URLSessionDataDelegate,
                                                 URLSessionTaskDelegate {
    static let maximumManifestBytes = 1_048_576

    private struct PendingDownload {
        var data = Data()
        let completion: (Result<Data, Error>) -> Void
    }

    private let lock = NSLock()
    private var pending: [Int: PendingDownload] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration,
                          delegate: self,
                          delegateQueue: nil)
    }()

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
            && (url.port.map { (1...65_535).contains($0) } ?? true)
    }

    func downloadManifest(from url: URL,
                          completion: @escaping (Result<Data, Error>) -> Void) {
        guard Self.isAllowedDownloadURL(url) else {
            completion(.failure(ActionPluginManagementError.downloadRequiresHTTPS))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let task = session.dataTask(with: request)
        lock.lock()
        pending[task.taskIdentifier] = PendingDownload(completion: completion)
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              Self.isAllowedDownloadURL(url) else {
            finish(taskIdentifier: task.taskIdentifier,
                   result: .failure(ActionPluginManagementError.downloadRequiresHTTPS))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              Self.isAllowedDownloadURL(finalURL) else {
            finish(taskIdentifier: dataTask.taskIdentifier,
                   result: .failure(ActionPluginManagementError.downloadFailed))
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            finish(taskIdentifier: dataTask.taskIdentifier,
                   result: .failure(ActionPluginManagementError.downloadStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(Self.maximumManifestBytes) else {
            finish(taskIdentifier: dataTask.taskIdentifier,
                   result: .failure(ActionPluginManagementError.sourceTooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        var overflow: PendingDownload?
        lock.lock()
        if var item = pending[dataTask.taskIdentifier] {
            if item.data.count <= Self.maximumManifestBytes,
               data.count <= Self.maximumManifestBytes - item.data.count {
                item.data.append(data)
                pending[dataTask.taskIdentifier] = item
            } else {
                overflow = pending.removeValue(forKey: dataTask.taskIdentifier)
            }
        }
        lock.unlock()
        if let overflow {
            dataTask.cancel()
            overflow.completion(.failure(ActionPluginManagementError.sourceTooLarge))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let item: PendingDownload?
        lock.lock()
        item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let item else { return }
        if let error {
            item.completion(.failure(error))
        } else {
            item.completion(.success(item.data))
        }
    }

    private func finish(taskIdentifier: Int, result: Result<Data, Error>) {
        let item: PendingDownload?
        lock.lock()
        item = pending.removeValue(forKey: taskIdentifier)
        lock.unlock()
        item?.completion(result)
    }
}

/// Owns installation state and filesystem transactions. The host remains the
/// authority for execution; this model only manages declarative plugin files
/// and whether the host is allowed to discover them.
final class ActionPluginManager {
    static let shared = ActionPluginManager()
    static let didChangeNotification = Notification.Name(
        "RimeBuffer.ActionPluginManager.didChange"
    )
    static let rootPathUserInfoKey = "rootPath"
    static let changedPluginIDUserInfoKey = "pluginID"

    static let maximumPluginBytes: Int64 = 64 * 1_048_576
    static let maximumPluginEntries = 4_096
    private static let mutationLock = NSRecursiveLock()
    private static var mutationGenerations: [String: UInt64] = [:]

    private enum EnablementState {
        case missing
        case valid(Set<String>)
        case corrupt
    }

    private struct PersistedState: Codable {
        let schemaVersion: Int
        let disabledPluginIDs: [String]
    }

    let rootURL: URL
    let stateURL: URL
    private let fileManager: FileManager
    private let downloader: any ActionPluginManifestDownloading
    private let completionQueue: DispatchQueue

    init(rootURL: URL = ActionPluginManifestLoader.defaultRootURL,
         stateURL: URL? = nil,
         fileManager: FileManager = .default,
         downloader: any ActionPluginManifestDownloading = ActionPluginHTTPSManifestDownloader(),
         completionQueue: DispatchQueue = .main) {
        self.rootURL = rootURL.standardizedFileURL
        self.stateURL = (stateURL
            ?? rootURL.appendingPathComponent(".plugin-state.json"))
            .standardizedFileURL
        self.fileManager = fileManager
        self.downloader = downloader
        self.completionQueue = completionQueue
    }

    func listInstalledPlugins() -> [ManagedActionPlugin] {
        Self.withMutationLock {
            listInstalledPluginsLocked()
        }
    }

    func isEnabled(pluginID: String) -> Bool {
        Self.withMutationLock {
            guard Self.pathHasNoUntrustedSymlink(rootURL) else { return false }
            switch Self.loadEnablementState(stateURL: stateURL,
                                            fileManager: fileManager) {
            case .missing:
                return true
            case let .valid(disabled):
                return !disabled.contains(pluginID)
            case .corrupt:
                return false
            }
        }
    }

    func setEnabled(_ enabled: Bool, pluginID: String) throws {
        let changed = try Self.withMutationLock { () -> Bool in
            try ensureSafeRoot()
            let installed = ActionPluginManifestLoader.load(from: rootURL,
                                                            fileManager: fileManager)
            guard installed.contains(where: { $0.manifest.id == pluginID }) else {
                throw ActionPluginManagementError.pluginNotFound(pluginID)
            }
            let installedIDs = Set(installed.map(\.manifest.id))
            let state = Self.loadEnablementState(stateURL: stateURL,
                                                 fileManager: fileManager)
            var disabled: Set<String>
            let stateNeedsRepair: Bool
            switch state {
            case .missing:
                disabled = []
                stateNeedsRepair = false
            case let .valid(value):
                disabled = value
                stateNeedsRepair = false
            case .corrupt:
                // Fail closed: until the user explicitly repairs one switch,
                // every currently installed plugin remains disabled.
                disabled = installedIDs
                stateNeedsRepair = true
            }
            let membershipChanged: Bool
            if enabled {
                membershipChanged = disabled.remove(pluginID) != nil
            } else {
                membershipChanged = disabled.insert(pluginID).inserted
            }
            guard membershipChanged || stateNeedsRepair else { return false }
            try persist(disabledPluginIDs: disabled)
            advanceMutationGenerationLocked()
            return true
        }
        if changed { notifyChange(pluginID: pluginID) }
    }

    func setEnabled(id: String, enabled: Bool) throws {
        try setEnabled(enabled, pluginID: id)
    }

    /// Installs either a standalone manifest JSON file or a complete local
    /// plugin directory. Directories are copied without following symlinks.
    @discardableResult
    func install(fromLocalURL sourceURL: URL,
                 replacingExisting: Bool = true) throws -> ManagedActionPlugin {
        let source = sourceURL.standardizedFileURL
        guard Self.pathHasNoUntrustedSymlink(source) else {
            throw ActionPluginManagementError.unsafeSource(source.path)
        }
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw ActionPluginManagementError.invalidSource
        }
        guard values.isSymbolicLink != true else {
            throw ActionPluginManagementError.unsafeSource(source.path)
        }

        if values.isDirectory == true {
            let manifestURL = source.appendingPathComponent("manifest.json")
            let data = try readManifestData(at: manifestURL)
            let manifest = try Self.decodeAndValidateManifest(data)
            return try install(manifest: manifest,
                               sourceDirectory: source,
                               manifestData: nil,
                               replacingExisting: replacingExisting)
        }
        guard values.isRegularFile == true else {
            throw ActionPluginManagementError.invalidSource
        }
        let data = try readManifestData(at: source)
        let manifest = try Self.decodeAndValidateManifest(data)
        return try install(manifest: manifest,
                           sourceDirectory: nil,
                           manifestData: data,
                           replacingExisting: replacingExisting)
    }

    @discardableResult
    func installLocal(url: URL,
                      replacingExisting: Bool = true) throws -> ManagedActionPlugin {
        try install(fromLocalURL: url, replacingExisting: replacingExisting)
    }

    /// Downloads and installs a single manifest. Remote archives are not
    /// accepted: the host never unpacks or executes network-provided code.
    func install(fromHTTPSURL url: URL,
                 replacingExisting: Bool = true,
                 completion: @escaping (Result<ManagedActionPlugin, Error>) -> Void) {
        guard ActionPluginHTTPSManifestDownloader.isAllowedDownloadURL(url) else {
            completionQueue.async {
                completion(.failure(ActionPluginManagementError.downloadRequiresHTTPS))
            }
            return
        }
        let requestedGeneration = Self.withMutationLock {
            currentMutationGenerationLocked()
        }
        downloader.downloadManifest(from: url) { [weak self] result in
            guard let self else { return }
            let installation: Result<ManagedActionPlugin, Error>
            do {
                let data = try result.get()
                let manifest = try Self.decodeAndValidateManifest(data)
                let record = try self.install(manifest: manifest,
                                              sourceDirectory: nil,
                                              manifestData: data,
                                              replacingExisting: replacingExisting,
                                              expectedGeneration: requestedGeneration)
                installation = .success(record)
            } catch {
                installation = .failure(error)
            }
            self.completionQueue.async { completion(installation) }
        }
    }

    func installRemote(url: URL,
                       replacingExisting: Bool = true,
                       completion: @escaping (Result<ManagedActionPlugin, Error>) -> Void) {
        install(fromHTTPSURL: url,
                replacingExisting: replacingExisting,
                completion: completion)
    }

    func uninstall(pluginID: String) throws {
        try Self.withMutationLock {
            try ensureSafeRoot()
            let installed = ActionPluginManifestLoader.load(from: rootURL,
                                                            fileManager: fileManager)
            guard let plugin = installed.first(where: { $0.manifest.id == pluginID }),
                  isDirectChild(plugin.directory, of: rootURL) else {
                throw ActionPluginManagementError.pluginNotFound(pluginID)
            }

            let state = Self.loadEnablementState(stateURL: stateURL,
                                                 fileManager: fileManager)
            var disabledAfterRemoval: Set<String>
            let mustPersistState: Bool
            switch state {
            case .missing:
                disabledAfterRemoval = []
                mustPersistState = false
            case let .valid(disabled):
                disabledAfterRemoval = disabled
                mustPersistState = disabled.contains(pluginID)
            case .corrupt:
                // Repair corrupt state without enabling any remaining plugin.
                disabledAfterRemoval = Set(installed.map(\.manifest.id))
                mustPersistState = true
            }
            disabledAfterRemoval.remove(pluginID)

            let tombstone = rootURL.appendingPathComponent(
                ".uninstall-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            do {
                try fileManager.moveItem(at: plugin.directory, to: tombstone)
            } catch {
                throw ActionPluginManagementError.fileOperation(error.localizedDescription)
            }

            if mustPersistState {
                do {
                    try persist(disabledPluginIDs: disabledAfterRemoval)
                } catch {
                    do {
                        try fileManager.moveItem(at: tombstone, to: plugin.directory)
                    } catch let rollbackError {
                        IMELog.write(
                            "plugin uninstall rollback failed plugin=\(pluginID) "
                                + "path=\(plugin.directory.path) error=\(rollbackError.localizedDescription)"
                        )
                    }
                    throw error
                }
            }

            do {
                try fileManager.removeItem(at: tombstone)
            } catch {
                // The hidden tombstone is already outside discovery. Cleanup
                // failure must not resurrect the plugin.
                IMELog.write("plugin tombstone cleanup failed path=\(tombstone.path) error=\(error.localizedDescription)")
            }
            advanceMutationGenerationLocked()
        }
        notifyChange(pluginID: pluginID)
    }

    func uninstall(id: String) throws {
        try uninstall(pluginID: id)
    }

    static func decodeAndValidateManifest(_ data: Data) throws -> ActionPluginManifest {
        guard !data.isEmpty,
              data.count <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(ActionPluginManifest.self, from: data),
              ActionPluginManifestLoader.validate(manifest) else {
            throw ActionPluginManagementError.invalidManifest
        }
        return manifest
    }

    static func decodeDisabledPluginIDs(_ data: Data) throws -> Set<String> {
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        guard state.schemaVersion == 1,
              state.disabledPluginIDs.count <= 4_096,
              state.disabledPluginIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
            throw ActionPluginManagementError.invalidManifest
        }
        return Set(state.disabledPluginIDs)
    }

    static func encodeDisabledPluginIDs(_ ids: Set<String>) throws -> Data {
        let state = PersistedState(schemaVersion: 1,
                                   disabledPluginIDs: ids.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    static func enabledPlugins(from rootURL: URL,
                               stateURL: URL? = nil,
                               fileManager: FileManager = .default) -> [InstalledActionPlugin] {
        withMutationLock {
            guard pathHasNoUntrustedSymlink(rootURL) else {
                IMELog.write("plugin root rejected due to symlink ancestor path=\(rootURL.path)")
                return []
            }
            let resolvedStateURL = stateURL
                ?? rootURL.appendingPathComponent(".plugin-state.json")
            let installed = ActionPluginManifestLoader.load(from: rootURL,
                                                            fileManager: fileManager)
            switch loadEnablementState(stateURL: resolvedStateURL,
                                       fileManager: fileManager) {
            case .missing:
                return installed
            case let .valid(disabled):
                return installed.filter { !disabled.contains($0.manifest.id) }
            case .corrupt:
                return []
            }
        }
    }

    private static func loadEnablementState(stateURL: URL,
                                            fileManager: FileManager) -> EnablementState {
        guard pathHasNoUntrustedSymlink(stateURL) else {
            IMELog.write("plugin state rejected due to symlink ancestor path=\(stateURL.path)")
            return .corrupt
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stateURL.path,
                                     isDirectory: &isDirectory) else {
            // A dangling state symlink is still corrupt, not a missing file.
            var info = stat()
            if lstat(stateURL.path, &info) == 0 { return .corrupt }
            return .missing
        }
        guard !isDirectory.boolValue else {
            IMELog.write("plugin state is not a regular file path=\(stateURL.path)")
            return .corrupt
        }
        do {
            let values = try stateURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
                return .corrupt
            }
            return .valid(try decodeDisabledPluginIDs(Data(contentsOf: stateURL)))
        } catch {
            IMELog.write("plugin state read failed path=\(stateURL.path) error=\(error.localizedDescription)")
            return .corrupt
        }
    }

    private func listInstalledPluginsLocked() -> [ManagedActionPlugin] {
        guard Self.pathHasNoUntrustedSymlink(rootURL) else {
            IMELog.write("plugin root rejected due to symlink ancestor path=\(rootURL.path)")
            return []
        }
        let installed = ActionPluginManifestLoader.load(from: rootURL,
                                                        fileManager: fileManager)
        let state = Self.loadEnablementState(stateURL: stateURL,
                                             fileManager: fileManager)
        return installed.map { plugin in
            let enabled: Bool
            switch state {
            case .missing:
                enabled = true
            case let .valid(disabled):
                enabled = !disabled.contains(plugin.manifest.id)
            case .corrupt:
                enabled = false
            }
            return ManagedActionPlugin(plugin: plugin, isEnabled: enabled)
        }.sorted {
            let nameOrder = $0.manifest.name.localizedCaseInsensitiveCompare(
                $1.manifest.name
            )
            return nameOrder == .orderedSame
                ? $0.id < $1.id
                : nameOrder == .orderedAscending
        }
    }

    private static func withMutationLock<T>(_ body: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try body()
    }

    private func currentMutationGenerationLocked() -> UInt64 {
        Self.mutationGenerations[rootURL.path, default: 0]
    }

    private func advanceMutationGenerationLocked() {
        Self.mutationGenerations[rootURL.path, default: 0] &+= 1
    }

    /// Refuse user-controlled symlink ancestors. macOS exposes three immutable,
    /// root-owned compatibility aliases that are safe to traverse and are used
    /// by FileManager.temporaryDirectory during smoke tests.
    private static func pathHasNoUntrustedSymlink(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let trustedSystemLinks = [
            "/var": "/private/var",
            "/tmp": "/private/tmp",
            "/etc": "/private/etc",
        ]
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard let expectedTarget = trustedSystemLinks[current.path],
                          let rawTarget = try? FileManager.default
                            .destinationOfSymbolicLink(atPath: current.path) else {
                        return false
                    }
                    let targetURL = rawTarget.hasPrefix("/")
                        ? URL(fileURLWithPath: rawTarget)
                        : current.deletingLastPathComponent()
                            .appendingPathComponent(rawTarget)
                    guard targetURL.standardized.path == expectedTarget else {
                        return false
                    }
                }
                continue
            }
            if errno == ENOENT { break }
            return false
        }
        return true
    }

    private func readManifestData(at url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
                throw ActionPluginManagementError.invalidSource
            }
            let data = try Data(contentsOf: url,
                                options: [.mappedIfSafe, .uncached])
            guard data.count <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
                throw ActionPluginManagementError.sourceTooLarge
            }
            return data
        } catch let error as ActionPluginManagementError {
            throw error
        } catch {
            throw ActionPluginManagementError.invalidSource
        }
    }

    private func install(manifest: ActionPluginManifest,
                         sourceDirectory: URL?,
                         manifestData: Data?,
                         replacingExisting: Bool,
                         expectedGeneration: UInt64? = nil) throws -> ManagedActionPlugin {
        let installed = try Self.withMutationLock {
            if let expectedGeneration,
               expectedGeneration != currentMutationGenerationLocked() {
                throw ActionPluginManagementError.staleDownload
            }
            let record = try installLocked(manifest: manifest,
                                           sourceDirectory: sourceDirectory,
                                           manifestData: manifestData,
                                           replacingExisting: replacingExisting)
            advanceMutationGenerationLocked()
            return record
        }
        notifyChange(pluginID: installed.id)
        return installed
    }

    private func installLocked(manifest: ActionPluginManifest,
                               sourceDirectory: URL?,
                               manifestData: Data?,
                               replacingExisting: Bool) throws -> ManagedActionPlugin {
        try ensureSafeRoot()
        if let sourceDirectory {
            let sourcePath = sourceDirectory.standardizedFileURL.path
            let rootPath = rootURL.standardizedFileURL.path
            guard Self.pathHasNoUntrustedSymlink(sourceDirectory),
                  rootPath != sourcePath,
                  !rootPath.hasPrefix(sourcePath + "/") else {
                throw ActionPluginManagementError.unsafeSource(sourcePath)
            }
        }

        let existingPlugins = ActionPluginManifestLoader.load(from: rootURL,
                                                              fileManager: fileManager)
        let existing = existingPlugins.first { $0.manifest.id == manifest.id }
        if existing != nil, !replacingExisting {
            throw ActionPluginManagementError.alreadyInstalled(manifest.id)
        }
        let destination = existing?.directory
            ?? rootURL.appendingPathComponent(manifest.id, isDirectory: true)
        guard isDirectChild(destination, of: rootURL),
              Self.pathHasNoUntrustedSymlink(destination) else {
            throw ActionPluginManagementError.unsafeSource(destination.path)
        }

        if existing == nil,
           let siblings = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
           ),
           let collision = siblings.first(where: {
               $0.lastPathComponent.caseInsensitiveCompare(manifest.id) == .orderedSame
           }) {
            throw ActionPluginManagementError.destinationConflict(collision.path)
        }

        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw ActionPluginManagementError.unsafeSource(destination.path)
            }
            do {
                let destinationData = try readManifestData(
                    at: destination.appendingPathComponent("manifest.json")
                )
                let destinationManifest = try Self.decodeAndValidateManifest(destinationData)
                guard destinationManifest.id == manifest.id else {
                    throw ActionPluginManagementError.destinationConflict(destination.path)
                }
            } catch let error as ActionPluginManagementError {
                if case .destinationConflict = error { throw error }
                throw ActionPluginManagementError.destinationConflict(destination.path)
            } catch {
                throw ActionPluginManagementError.destinationConflict(destination.path)
            }
        }

        let staging = rootURL.appendingPathComponent(
            ".install-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: staging,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            if let sourceDirectory {
                try copyPluginDirectory(from: sourceDirectory, to: staging)
            } else if let manifestData {
                try manifestData.write(to: staging.appendingPathComponent("manifest.json"),
                                       options: .atomic)
            } else {
                throw ActionPluginManagementError.invalidSource
            }

            let stagedData = try readManifestData(
                at: staging.appendingPathComponent("manifest.json")
            )
            let stagedManifest = try Self.decodeAndValidateManifest(stagedData)
            guard stagedManifest == manifest else {
                throw ActionPluginManagementError.invalidManifest
            }

            if fileManager.fileExists(atPath: destination.path) {
                let backupName = ".backup-\(UUID().uuidString.lowercased())"
                _ = try fileManager.replaceItemAt(destination,
                                                  withItemAt: staging,
                                                  backupItemName: backupName,
                                                  options: [])
                let backupURL = rootURL.appendingPathComponent(backupName,
                                                               isDirectory: true)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch let error as ActionPluginManagementError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ActionPluginManagementError.fileOperation(error.localizedDescription)
        }

        let enabled: Bool
        switch Self.loadEnablementState(stateURL: stateURL,
                                        fileManager: fileManager) {
        case .missing:
            enabled = true
        case let .valid(disabled):
            enabled = !disabled.contains(manifest.id)
        case .corrupt:
            enabled = false
        }
        return ManagedActionPlugin(
            plugin: InstalledActionPlugin(manifest: manifest,
                                          directory: destination),
            isEnabled: enabled
        )
    }

    private func copyPluginDirectory(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw ActionPluginManagementError.unsafeSource(source.path)
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [],
            errorHandler: { url, error in
                enumerationError = error
                IMELog.write("plugin source enumerate failed path=\(url.path) error=\(error.localizedDescription)")
                return false
            }
        ) else {
            throw ActionPluginManagementError.invalidSource
        }

        let sourceComponents = source.standardizedFileURL.pathComponents
        var entryCount = 0
        var totalBytes: Int64 = 0
        for case let item as URL in enumerator {
            entryCount += 1
            guard entryCount <= Self.maximumPluginEntries else {
                throw ActionPluginManagementError.sourceTooLarge
            }
            let itemValues = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard itemValues.isSymbolicLink != true else {
                throw ActionPluginManagementError.unsafeSource(item.path)
            }
            let itemComponents = item.standardizedFileURL.pathComponents
            guard itemComponents.count > sourceComponents.count,
                  Array(itemComponents.prefix(sourceComponents.count)) == sourceComponents else {
                throw ActionPluginManagementError.unsafeSource(item.path)
            }
            let relativeComponents = itemComponents.dropFirst(sourceComponents.count)
            let target = relativeComponents.reduce(destination) {
                $0.appendingPathComponent($1)
            }

            if itemValues.isDirectory == true {
                try fileManager.createDirectory(at: target,
                                                withIntermediateDirectories: false,
                                                attributes: nil)
            } else if itemValues.isRegularFile == true {
                guard let fileSize = itemValues.fileSize,
                      fileSize >= 0 else {
                    throw ActionPluginManagementError.unsafeSource(item.path)
                }
                totalBytes += Int64(fileSize)
                guard totalBytes <= Self.maximumPluginBytes else {
                    throw ActionPluginManagementError.sourceTooLarge
                }
                try fileManager.copyItem(at: item, to: target)
            } else {
                throw ActionPluginManagementError.unsafeSource(item.path)
            }
        }
        if let enumerationError {
            throw ActionPluginManagementError.fileOperation(
                enumerationError.localizedDescription
            )
        }
    }

    private func ensureSafeRoot() throws {
        guard Self.pathHasNoUntrustedSymlink(rootURL) else {
            throw ActionPluginManagementError.unsafeSource(rootURL.path)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            do {
                let values = try rootURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard isDirectory.boolValue,
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    throw ActionPluginManagementError.unsafeSource(rootURL.path)
                }
            } catch let error as ActionPluginManagementError {
                throw error
            } catch {
                throw ActionPluginManagementError.fileOperation(error.localizedDescription)
            }
            return
        }
        do {
            try fileManager.createDirectory(at: rootURL,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            guard Self.pathHasNoUntrustedSymlink(rootURL) else {
                throw ActionPluginManagementError.unsafeSource(rootURL.path)
            }
        } catch let error as ActionPluginManagementError {
            throw error
        } catch {
            throw ActionPluginManagementError.fileOperation(error.localizedDescription)
        }
    }

    private func persist(disabledPluginIDs: Set<String>) throws {
        try ensureSafeRoot()
        guard Self.pathHasNoUntrustedSymlink(stateURL) else {
            throw ActionPluginManagementError.unsafeSource(stateURL.path)
        }
        do {
            let data = try Self.encodeDisabledPluginIDs(disabledPluginIDs)
            try data.write(to: stateURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: stateURL.path)
        } catch {
            throw ActionPluginManagementError.fileOperation(error.localizedDescription)
        }
    }

    private func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent().path
            == parent.standardizedFileURL.path
    }

    private func notifyChange(pluginID: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [
                Self.rootPathUserInfoKey: rootURL.path,
                Self.changedPluginIDUserInfoKey: pluginID,
            ]
        )
    }
}
