import Foundation

private final class ActionPluginManagerSmokeDownloader: ActionPluginManifestDownloading {
    let result: Result<Data, Error>
    private let holdCompletion: Bool
    private let lock = NSLock()
    private var storedURLs: [URL] = []
    private var pendingCompletion: ((Result<Data, Error>) -> Void)?

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }

    init(result: Result<Data, Error>, holdCompletion: Bool = false) {
        self.result = result
        self.holdCompletion = holdCompletion
    }

    func downloadManifest(from url: URL,
                          completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        storedURLs.append(url)
        if holdCompletion {
            pendingCompletion = completion
            lock.unlock()
        } else {
            lock.unlock()
            completion(result)
        }
    }

    func completeHeldDownload() {
        lock.lock()
        let completion = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        completion?(result)
    }
}

private final class ActionPluginManagerSmokeTransport: ActionPluginTransport {
    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void) {
        completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
    }

    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> ActionPluginInvocationCancellable? {
        completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
        return nil
    }
}

/// Executable coverage for the plugin-management filesystem and host boundary.
/// Kept outside main.swift so the normal IME entrypoint stays small.
func runActionPluginManagerSmokeTest() -> Bool {
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-plugin-manager-smoke-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let root = sandbox.appendingPathComponent("installed", isDirectory: true)

    func fail(_ message: String) -> Bool {
        print("FAILED: plugin manager \(message)")
        return false
    }

    func manifestData(id: String, version: String) throws -> Data {
        let displayName = id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "id": id,
            "name": displayName,
            "version": version,
            "runtimeConfigPaths": ["runtime.json"],
            "actions": [[
                "id": "\(id).run",
                "title": "Run",
                "symbol": "bolt",
                "statusPath": "/status",
                "invokePath": "/invoke",
                "modes": [],
            ]],
        ], options: [.sortedKeys])
    }

    do {
        try fileManager.createDirectory(at: sandbox,
                                        withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let manager = ActionPluginManager(rootURL: root)
        let directorySource = sandbox.appendingPathComponent("directory-source",
                                                              isDirectory: true)
        try fileManager.createDirectory(at: directorySource,
                                        withIntermediateDirectories: true)
        try manifestData(id: "directory-plugin", version: "1.0.0")
            .write(to: directorySource.appendingPathComponent("manifest.json"),
                   options: .atomic)
        try Data("asset".utf8).write(
            to: directorySource.appendingPathComponent("asset.txt"),
            options: .atomic
        )

        let directoryPlugin = try manager.installLocal(url: directorySource)
        guard directoryPlugin.id == "directory-plugin",
              directoryPlugin.name == "Directory Plugin",
              directoryPlugin.version == "1.0.0",
              directoryPlugin.actions.map(\.id) == ["directory-plugin.run"],
              directoryPlugin.enabled,
              fileManager.fileExists(
                atPath: root.appendingPathComponent("directory-plugin/asset.txt").path
              ) else {
            return fail("local directory install")
        }

        let standaloneManifest = sandbox.appendingPathComponent("standalone.json")
        try manifestData(id: "manifest-plugin", version: "1.0.0")
            .write(to: standaloneManifest, options: .atomic)
        guard try manager.installLocal(url: standaloneManifest).id == "manifest-plugin",
              manager.listInstalledPlugins().count == 2 else {
            return fail("standalone manifest install")
        }

        try manager.setEnabled(id: "directory-plugin", enabled: false)
        guard manager.listInstalledPlugins()
                .first(where: { $0.id == "directory-plugin" })?.enabled == false,
              ActionPluginManager.enabledPlugins(from: root).map(\.manifest.id)
                == ["manifest-plugin"] else {
            return fail("disable filtering")
        }

        let restartedManager = ActionPluginManager(rootURL: root)
        guard restartedManager.listInstalledPlugins()
                .first(where: { $0.id == "directory-plugin" })?.enabled == false else {
            return fail("disabled-state persistence")
        }
        try restartedManager.setEnabled(id: "directory-plugin", enabled: true)
        guard Set(ActionPluginManager.enabledPlugins(from: root).map(\.manifest.id))
                == Set(["directory-plugin", "manifest-plugin"]) else {
            return fail("re-enable")
        }

        let replacementManifest = sandbox.appendingPathComponent("replacement.json")
        try manifestData(id: "directory-plugin", version: "2.0.0")
            .write(to: replacementManifest, options: .atomic)
        guard try manager.installLocal(url: replacementManifest).version == "2.0.0",
              !fileManager.fileExists(
                atPath: root.appendingPathComponent("directory-plugin/asset.txt").path
              ) else {
            return fail("atomic replacement")
        }

        let occupiedDestination = root.appendingPathComponent("collision",
                                                               isDirectory: true)
        try fileManager.createDirectory(at: occupiedDestination,
                                        withIntermediateDirectories: true)
        try manifestData(id: "directory-owner", version: "1")
            .write(to: occupiedDestination.appendingPathComponent("manifest.json"),
                   options: .atomic)
        let collisionManifest = sandbox.appendingPathComponent("collision.json")
        try manifestData(id: "collision", version: "1")
            .write(to: collisionManifest, options: .atomic)
        do {
            _ = try manager.installLocal(url: collisionManifest)
            return fail("occupied destination with a different manifest id was overwritten")
        } catch ActionPluginManagementError.destinationConflict {
        }

        let caseDestination = root.appendingPathComponent("caseplugin",
                                                           isDirectory: true)
        try fileManager.createDirectory(at: caseDestination,
                                        withIntermediateDirectories: true)
        try manifestData(id: "caseplugin", version: "1")
            .write(to: caseDestination.appendingPathComponent("manifest.json"),
                   options: .atomic)
        let caseCollisionManifest = sandbox.appendingPathComponent("case-collision.json")
        try manifestData(id: "CasePlugin", version: "1")
            .write(to: caseCollisionManifest, options: .atomic)
        do {
            _ = try manager.installLocal(url: caseCollisionManifest)
            return fail("case-folded plugin directory collision was accepted")
        } catch ActionPluginManagementError.destinationConflict {
        }

        let invalidManifest = sandbox.appendingPathComponent("invalid.json")
        try Data(#"{"schemaVersion":2}"#.utf8)
            .write(to: invalidManifest, options: .atomic)
        do {
            _ = try manager.installLocal(url: invalidManifest)
            return fail("invalid manifest accepted")
        } catch ActionPluginManagementError.invalidManifest {
        }

        let unsafeDirectory = sandbox.appendingPathComponent("unsafe",
                                                              isDirectory: true)
        try fileManager.createDirectory(at: unsafeDirectory,
                                        withIntermediateDirectories: true)
        try manifestData(id: "unsafe", version: "1")
            .write(to: unsafeDirectory.appendingPathComponent("manifest.json"),
                   options: .atomic)
        try fileManager.createSymbolicLink(
            at: unsafeDirectory.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        do {
            _ = try manager.installLocal(url: unsafeDirectory)
            return fail("symbolic link accepted")
        } catch ActionPluginManagementError.unsafeSource {
        }

        let corruptRoot = sandbox.appendingPathComponent("corrupt-state",
                                                          isDirectory: true)
        let corruptManager = ActionPluginManager(rootURL: corruptRoot)
        let firstCorruptManifest = sandbox.appendingPathComponent("corrupt-one.json")
        let secondCorruptManifest = sandbox.appendingPathComponent("corrupt-two.json")
        try manifestData(id: "corrupt-one", version: "1")
            .write(to: firstCorruptManifest, options: .atomic)
        try manifestData(id: "corrupt-two", version: "1")
            .write(to: secondCorruptManifest, options: .atomic)
        _ = try corruptManager.installLocal(url: firstCorruptManifest)
        _ = try corruptManager.installLocal(url: secondCorruptManifest)
        try Data("not-json".utf8).write(to: corruptManager.stateURL,
                                            options: .atomic)
        guard corruptManager.listInstalledPlugins().allSatisfy({ !$0.enabled }),
              ActionPluginManager.enabledPlugins(from: corruptRoot).isEmpty,
              !corruptManager.isEnabled(pluginID: "corrupt-one") else {
            return fail("corrupt state did not fail closed")
        }
        try corruptManager.setEnabled(id: "corrupt-one", enabled: true)
        let repairedState = Dictionary(
            uniqueKeysWithValues: corruptManager.listInstalledPlugins().map { ($0.id, $0.enabled) }
        )
        guard repairedState["corrupt-one"] == true,
              repairedState["corrupt-two"] == false else {
            return fail("explicit enable did not safely repair corrupt state")
        }

        let rollbackRoot = sandbox.appendingPathComponent("rollback-state",
                                                           isDirectory: true)
        let rollbackManager = ActionPluginManager(rootURL: rollbackRoot)
        let rollbackManifest = sandbox.appendingPathComponent("rollback.json")
        try manifestData(id: "rollback", version: "1")
            .write(to: rollbackManifest, options: .atomic)
        _ = try rollbackManager.installLocal(url: rollbackManifest)
        try fileManager.createDirectory(at: rollbackManager.stateURL,
                                        withIntermediateDirectories: false)
        do {
            try rollbackManager.uninstall(id: "rollback")
            return fail("uninstall unexpectedly ignored state persistence failure")
        } catch {
        }
        guard fileManager.fileExists(
                atPath: rollbackRoot.appendingPathComponent("rollback/manifest.json").path
              ),
              rollbackManager.listInstalledPlugins().first?.enabled == false else {
            return fail("failed uninstall did not restore the disabled plugin directory")
        }

        let realAncestor = sandbox.appendingPathComponent("real-ancestor",
                                                           isDirectory: true)
        let symlinkAncestor = sandbox.appendingPathComponent("linked-ancestor",
                                                              isDirectory: true)
        try fileManager.createDirectory(at: realAncestor,
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkAncestor,
                                           withDestinationURL: realAncestor)
        let ancestorManager = ActionPluginManager(
            rootURL: symlinkAncestor.appendingPathComponent("plugins", isDirectory: true)
        )
        do {
            _ = try ancestorManager.installLocal(url: standaloneManifest)
            return fail("plugin root through a symlink ancestor was accepted")
        } catch ActionPluginManagementError.unsafeSource {
        }
        guard !fileManager.fileExists(
            atPath: realAncestor.appendingPathComponent("plugins").path
        ) else {
            return fail("unsafe ancestor redirected plugin installation")
        }

        let remoteData = try manifestData(id: "remote", version: "1")
        let downloader = ActionPluginManagerSmokeDownloader(result: .success(remoteData))
        let remoteManager = ActionPluginManager(rootURL: root,
                                                downloader: downloader,
                                                completionQueue: .global())
        let remoteSemaphore = DispatchSemaphore(value: 0)
        var remotePluginID: String?
        remoteManager.installRemote(
            url: URL(string: "https://example.test/manifest.json")!
        ) { result in
            remotePluginID = try? result.get().id
            remoteSemaphore.signal()
        }
        guard remoteSemaphore.wait(timeout: .now() + 2) == .success,
              remotePluginID == "remote",
              downloader.requestedURLs.count == 1 else {
            return fail("injected HTTPS download")
        }

        let rejectedSemaphore = DispatchSemaphore(value: 0)
        var rejectedHTTP = false
        remoteManager.installRemote(
            url: URL(string: "http://example.test/manifest.json")!
        ) { result in
            do {
                _ = try result.get()
            } catch ActionPluginManagementError.downloadRequiresHTTPS {
                rejectedHTTP = true
            } catch {
            }
            rejectedSemaphore.signal()
        }
        guard rejectedSemaphore.wait(timeout: .now() + 2) == .success,
              rejectedHTTP,
              downloader.requestedURLs.count == 1,
              ActionPluginHTTPSManifestDownloader.isAllowedDownloadURL(
                URL(string: "https://example.test/manifest.json?version=1")!
              ),
              !ActionPluginHTTPSManifestDownloader.isAllowedDownloadURL(
                URL(string: "https://user@example.test/manifest.json")!
              ),
              !ActionPluginHTTPSManifestDownloader.isAllowedDownloadURL(
                URL(string: "https://example.test/manifest.json#fragment")!
              ) else {
            return fail("HTTPS URL guard")
        }

        let raceRoot = sandbox.appendingPathComponent("mutation-race",
                                                       isDirectory: true)
        let raceManager = ActionPluginManager(rootURL: raceRoot)
        let raceManifest = sandbox.appendingPathComponent("race.json")
        try manifestData(id: "race", version: "1")
            .write(to: raceManifest, options: .atomic)
        _ = try raceManager.installLocal(url: raceManifest)

        let delayedUpdate = ActionPluginManagerSmokeDownloader(
            result: .success(try manifestData(id: "race", version: "2")),
            holdCompletion: true
        )
        let delayedManager = ActionPluginManager(rootURL: raceRoot,
                                                 downloader: delayedUpdate,
                                                 completionQueue: .global())
        let delayedCompletion = DispatchSemaphore(value: 0)
        var disableInvalidatedDownload = false
        delayedManager.installRemote(
            url: URL(string: "https://example.test/race.json")!
        ) { result in
            do {
                _ = try result.get()
            } catch ActionPluginManagementError.staleDownload {
                disableInvalidatedDownload = true
            } catch {
            }
            delayedCompletion.signal()
        }
        let disableCompletion = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? raceManager.setEnabled(id: "race", enabled: false)
            disableCompletion.signal()
        }
        guard disableCompletion.wait(timeout: .now() + 2) == .success else {
            return fail("concurrent disable deadlocked")
        }
        delayedUpdate.completeHeldDownload()
        guard delayedCompletion.wait(timeout: .now() + 2) == .success,
              disableInvalidatedDownload,
              raceManager.listInstalledPlugins().first?.version == "1",
              raceManager.listInstalledPlugins().first?.enabled == false else {
            return fail("late remote update survived a newer disable mutation")
        }

        try raceManager.setEnabled(id: "race", enabled: true)
        let delayedReinstall = ActionPluginManagerSmokeDownloader(
            result: .success(try manifestData(id: "race", version: "3")),
            holdCompletion: true
        )
        let reinstallManager = ActionPluginManager(rootURL: raceRoot,
                                                   downloader: delayedReinstall,
                                                   completionQueue: .global())
        let reinstallCompletion = DispatchSemaphore(value: 0)
        var uninstallInvalidatedDownload = false
        reinstallManager.installRemote(
            url: URL(string: "https://example.test/race.json")!
        ) { result in
            do {
                _ = try result.get()
            } catch ActionPluginManagementError.staleDownload {
                uninstallInvalidatedDownload = true
            } catch {
            }
            reinstallCompletion.signal()
        }
        let uninstallCompletion = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? raceManager.uninstall(id: "race")
            uninstallCompletion.signal()
        }
        guard uninstallCompletion.wait(timeout: .now() + 2) == .success else {
            return fail("concurrent uninstall deadlocked")
        }
        delayedReinstall.completeHeldDownload()
        guard reinstallCompletion.wait(timeout: .now() + 2) == .success,
              uninstallInvalidatedDownload,
              raceManager.listInstalledPlugins().isEmpty else {
            return fail("late remote update resurrected an uninstalled plugin")
        }

        let hostManifest = sandbox.appendingPathComponent("host.json")
        try manifestData(id: "host-plugin", version: "1")
            .write(to: hostManifest, options: .atomic)
        var notificationCount = 0
        var changedPluginIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: ActionPluginManager.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[ActionPluginManager.rootPathUserInfoKey]
                    as? String == root.path else { return }
            notificationCount += 1
            if let pluginID = notification.userInfo?[ActionPluginManager.changedPluginIDUserInfoKey]
                as? String {
                changedPluginIDs.append(pluginID)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try manager.installLocal(url: hostManifest)
        var focusEpochs = FocusEpochState()
        let token = focusEpochs.activate()
        let focus = ActionPluginFocusAccess(
            currentToken: { token },
            isValid: { $0 == token },
            secureInputEnabled: { false }
        )
        let host = ActionPluginHost(rootURL: root,
                                    client: ActionPluginManagerSmokeTransport(),
                                    focus: focus,
                                    bufferModel: BufferModel(),
                                    inboundBus: InboundBus())
        guard host.presentations.contains(where: { $0.key.pluginId == "host-plugin" }) else {
            return fail("host did not discover installed plugin")
        }
        try manager.setEnabled(id: "host-plugin", enabled: false)
        guard notificationCount == 2,
              changedPluginIDs == ["host-plugin", "host-plugin"],
              !host.presentations.contains(where: { $0.key.pluginId == "host-plugin" }) else {
            return fail("notification did not invalidate host immediately")
        }

        try restartedManager.uninstall(id: "directory-plugin")
        guard !restartedManager.listInstalledPlugins().contains(where: {
            $0.id == "directory-plugin"
        }),
        !fileManager.fileExists(
            atPath: root.appendingPathComponent("directory-plugin").path
        ) else {
            return fail("uninstall")
        }

        print("plugin manager smoke OK")
        return true
    } catch {
        return fail("threw \(error.localizedDescription)")
    }
}
