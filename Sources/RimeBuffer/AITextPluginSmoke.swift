import Darwin
import Foundation

private final class AITextSmokeCancellation: AITextCancellable {
    private(set) var wasCancelled = false
    func cancel() { wasCancelled = true }
}

private final class AITextSmokeProvider: AITextProvider {
    let kind: AITextProviderKind
    var availability: AITextProviderAvailability = .ready
    private(set) var requests: [AITextProviderRequest] = []
    private(set) var cancellations: [AITextSmokeCancellation] = []
    private var eventCallbacks: [(AITextProviderEvent) -> Void] = []
    private var completions: [(Result<[AITextProviderBlock], AITextProviderError>) -> Void] = []

    init(kind: AITextProviderKind = .codexCLI) {
        self.kind = kind
    }

    @discardableResult
    func generate(_ request: AITextProviderRequest,
                  onEvent: @escaping (AITextProviderEvent) -> Void,
                  completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void)
        -> any AITextCancellable {
        requests.append(request)
        eventCallbacks.append(onEvent)
        completions.append(completion)
        let cancellation = AITextSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func emit(_ block: AITextProviderBlock, request index: Int) {
        eventCallbacks[index](.blockSnapshot(block))
    }

    func finish(_ result: Result<[AITextProviderBlock], AITextProviderError>,
                request index: Int) {
        completions[index](result)
    }
}

private final class AITextSmokeSelection {
    var selected = true
}

private final class AITextSmokeRunner: AITextCLIProcessRunning {
    private(set) var specs: [AITextCLIProcessSpec] = []
    private(set) var cancellations: [AITextSmokeCancellation] = []
    private var outputs: [(Data) -> Void] = []
    private var completions: [(AITextCLIProcessResult) -> Void] = []

    @discardableResult
    func run(_ spec: AITextCLIProcessSpec,
             onStandardOutput: @escaping (Data) -> Void,
             completion: @escaping (AITextCLIProcessResult) -> Void) -> any AITextCancellable {
        specs.append(spec)
        outputs.append(onStandardOutput)
        completions.append(completion)
        let cancellation = AITextSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func succeed(request index: Int, chunks: [Data]) {
        chunks.forEach(outputs[index])
        completions[index](AITextCLIProcessResult(terminationStatus: 0,
                                                  standardOutput: chunks.reduce(into: Data()) { $0.append($1) },
                                                  timedOut: false,
                                                  cancelled: false,
                                                  outputTooLarge: false))
    }
}

private enum AITextPluginSmoke {
    static func run() -> Bool {
        guard Thread.isMainThread else { return false }
        return resultDecoder()
            && streamParsers()
            && fakeCLIRunners()
            && configurationStorageAndRequest()
            && workspaceGatesAndDelivery()
            && remoteMirrorAndActionReview()
    }

    private static func resultDecoder() -> Bool {
        let structured = """
        {"blocks":[{"text":"第一块","title":"A"},{"text":"第二块","title":null}]}
        """
        guard let blocks = try? AITextResultDecoder.decodeFinalText(structured),
              blocks.count == 2,
              blocks[0].index == 0,
              blocks[0].text == "第一块",
              blocks[1].index == 1 else { return false }
        guard let fenced = try? AITextResultDecoder.decodeFinalText("```json\n\(structured)\n```"),
              fenced == blocks else { return false }
        guard let fallback = try? AITextResultDecoder.decodeFinalText("甲\n\n乙"),
              fallback.map(\.text) == ["甲", "乙"] else { return false }
        let partial = AITextPartialJSONBlocks.decode(
            "{\"blocks\":[{\"text\":\"首块\\n正在生"
        )
        guard partial.count == 1,
              partial[0].index == 0,
              partial[0].text == "首块\n正在生" else { return false }
        let twoPartial = AITextPartialJSONBlocks.decode(
            "{\"blocks\":[{\"text\":\"第一块\"},{\"text\":\"第二"
        )
        guard twoPartial.map(\.text) == ["第一块", "第二"] else { return false }
        return (try? AITextResultDecoder.decodeFinalText("   ")) == nil
    }

    private static func streamParsers() -> Bool {
        let codexObject: [String: Any] = [
            "type": "item.completed",
            "item": [
                "type": "agent_message",
                "text": "{\"blocks\":[{\"text\":\"codex result\"}]}",
            ],
        ]
        guard let codexLine = try? JSONSerialization.data(withJSONObject: codexObject) else {
            return false
        }
        var codex = AITextCodexJSONStreamParser()
        let split = max(1, codexLine.count / 2)
        guard (try? codex.append(Data(codexLine[..<split])))?.isEmpty == true else {
            return false
        }
        var secondHalf = Data(codexLine[split...])
        secondHalf.append(0x0A)
        guard let snapshots = try? codex.append(secondHalf),
              snapshots.last == "{\"blocks\":[{\"text\":\"codex result\"}]}" else {
            return false
        }

        let claudeDelta: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"],
            ],
        ]
        let claudeResult: [String: Any] = [
            "type": "result",
            "structured_output": ["blocks": [["text": "claude result"]]],
        ]
        guard let deltaData = try? JSONSerialization.data(withJSONObject: claudeDelta),
              let resultData = try? JSONSerialization.data(withJSONObject: claudeResult) else {
            return false
        }
        var claude = AITextClaudeJSONStreamParser()
        var fixture = Data()
        fixture.append(deltaData)
        fixture.append(0x0A)
        fixture.append(resultData)
        fixture.append(0x0A)
        guard let claudeSnapshots = try? claude.append(fixture),
              claudeSnapshots == ["partial"],
              let final = claude.finalText,
              let finalBlocks = try? AITextResultDecoder.decodeFinalText(final),
              finalBlocks.first?.text == "claude result" else { return false }

        let eventOne = "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
        let eventTwo = "data: {\"choices\":[{\"delta\":{\"content\":\" two\"}}]}\r\n\r\n"
        let bytes = Data((eventOne + eventTwo).utf8)
        var sse = AITextSSEDecoder()
        let boundary = bytes.count / 3
        guard (try? sse.append(Data(bytes[..<boundary])))?.isEmpty == true,
              let payloads = try? sse.append(Data(bytes[boundary...])),
              payloads.count == 2,
              (try? AITextOpenAIResponseDecoder.streamDelta(from: payloads[0])) == "one",
              (try? AITextOpenAIResponseDecoder.streamDelta(from: payloads[1])) == " two" else {
            return false
        }
        return true
    }

    private static func fakeCLIRunners() -> Bool {
        let codexRunner = AITextSmokeRunner()
        let fakeExecutable = URL(fileURLWithPath: "/usr/bin/true")
        let codex = CodexCLITextProvider(runner: codexRunner,
                                        environment: [
                                            "HOME": "/tmp",
                                            "CODEX_HOME": "/tmp/codex",
                                            "OPENAI_API_KEY": "openai-only",
                                            "CODEX_API_KEY": "codex-only",
                                            "ANTHROPIC_API_KEY": "must-not-leak",
                                            "CLAUDE_CODE_OAUTH_TOKEN": "must-not-leak",
                                        ],
                                        executableResolver: { fakeExecutable },
                                        compatibilityResolver: { _ in true })
        var codexResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = codex.generate(AITextProviderRequest(requestID: UUID(), sourceText: "private-source"),
                           onEvent: { _ in },
                           completion: { codexResult = $0 })
        guard codexRunner.specs.count == 1 else { return false }
        let codexSpec = codexRunner.specs[0]
        guard codexSpec.executableURL == fakeExecutable,
              codexSpec.arguments.first == "exec",
              !codexSpec.arguments.contains(where: { $0.contains("private-source") }),
              String(data: codexSpec.standardInput, encoding: .utf8)?.contains("private-source") == true,
              codexSpec.arguments.contains("--strict-config"),
              codexSpec.arguments.contains("default_permissions=\"rimebuffer\""),
              !codexSpec.arguments.contains("--sandbox"),
              codexSpec.arguments.contains("permissions.rimebuffer.network.enabled=false"),
              codexSpec.arguments.contains("tools.experimental_request_user_input={enabled=false}"),
              codexSpec.arguments.contains("web_search=\"disabled\""),
              codexSpec.arguments.contains(where: {
                  $0.hasPrefix("permissions.rimebuffer.filesystem=")
                      && $0.contains(codexSpec.currentDirectoryURL.path)
              }),
              codexSpec.environment["OPENAI_API_KEY"] == "openai-only",
              codexSpec.environment["CODEX_API_KEY"] == "codex-only",
              codexSpec.environment["CODEX_HOME"] == "/tmp/codex",
              codexSpec.environment["TMPDIR"] == codexSpec.currentDirectoryURL.path,
              codexSpec.environment["ANTHROPIC_API_KEY"] == nil,
              codexSpec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
              !["sh", "bash", "zsh"].contains(codexSpec.executableURL.lastPathComponent) else {
            return false
        }
        let codexObject: [String: Any] = [
            "type": "item.completed",
            "item": [
                "type": "agent_message",
                "text": "{\"blocks\":[{\"text\":\"ok\"}]}",
            ],
        ]
        guard var codexData = try? JSONSerialization.data(withJSONObject: codexObject) else {
            return false
        }
        codexData.append(0x0A)
        codexRunner.succeed(request: 0, chunks: [codexData])
        guard case let .success(blocks)? = codexResult,
              blocks.first?.text == "ok" else { return false }

        let unsupportedRunner = AITextSmokeRunner()
        let unsupportedCodex = CodexCLITextProvider(
            runner: unsupportedRunner,
            environment: ["HOME": "/tmp"],
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in false }
        )
        guard case .unavailable = unsupportedCodex.availability else { return false }
        var unsupportedResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = unsupportedCodex.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must-not-send"),
            onEvent: { _ in },
            completion: { unsupportedResult = $0 }
        )
        guard unsupportedRunner.specs.isEmpty,
              case .failure(.unavailable)? = unsupportedResult else { return false }

        let claudeRunner = AITextSmokeRunner()
        let claude = ClaudeCodeCLITextProvider(runner: claudeRunner,
                                               environment: [
                                                   "HOME": "/tmp",
                                                   "CLAUDE_CONFIG_DIR": "/tmp/claude",
                                                   "ANTHROPIC_API_KEY": "anthropic-only",
                                                   "CLAUDE_CODE_OAUTH_TOKEN": "claude-only",
                                                   "OPENAI_API_KEY": "must-not-leak",
                                                   "CODEX_HOME": "/tmp/codex-must-not-leak",
                                               ],
                                               executableResolver: { fakeExecutable })
        var claudeResultValue: Result<[AITextProviderBlock], AITextProviderError>?
        _ = claude.generate(AITextProviderRequest(requestID: UUID(), sourceText: "claude-source"),
                            onEvent: { _ in },
                            completion: { claudeResultValue = $0 })
        guard claudeRunner.specs.count == 1,
              !claudeRunner.specs[0].arguments.contains(where: { $0.contains("claude-source") }),
              String(data: claudeRunner.specs[0].standardInput, encoding: .utf8)?.contains("claude-source") == true,
              claudeRunner.specs[0].arguments.contains("--strict-mcp-config"),
              claudeRunner.specs[0].environment["ANTHROPIC_API_KEY"] == "anthropic-only",
              claudeRunner.specs[0].environment["CLAUDE_CODE_OAUTH_TOKEN"] == "claude-only",
              claudeRunner.specs[0].environment["CLAUDE_CONFIG_DIR"] == "/tmp/claude",
              claudeRunner.specs[0].environment["TMPDIR"] == claudeRunner.specs[0].currentDirectoryURL.path,
              claudeRunner.specs[0].environment["OPENAI_API_KEY"] == nil,
              claudeRunner.specs[0].environment["CODEX_HOME"] == nil else {
            return false
        }
        let claudeObject: [String: Any] = [
            "type": "result",
            "structured_output": ["blocks": [["text": "claude ok"]]],
        ]
        guard var claudeData = try? JSONSerialization.data(withJSONObject: claudeObject) else {
            return false
        }
        claudeData.append(0x0A)
        claudeRunner.succeed(request: 0, chunks: [claudeData])
        guard case let .success(blocks)? = claudeResultValue,
              blocks.first?.text == "claude ok" else { return false }
        return true
    }

    private static func configurationStorageAndRequest() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-AI-Smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenAICompatibleConfigurationStore(rootDirectory: root)
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://example.com/v1/",
                                                           model: "example-model",
                                                           apiKey: "secret-value")
        do {
            try store.save(configuration)
            guard try store.load() == configuration else { return false }
        } catch {
            return false
        }
        var info = stat()
        guard lstat(store.configurationURL.path, &info) == 0,
              (info.st_mode & 0o777) == 0o600 else { return false }
        guard let endpoint = try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "https://example.com/v1/"
        ), endpoint.absoluteString == "https://example.com/v1/chat/completions" else {
            return false
        }
        guard (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "http://example.com/v1"
        )) == nil,
        (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "http://127.0.0.1:8080/v1"
        )) != nil,
        (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "https://user:password@example.com/v1"
        )) == nil else { return false }

        guard let request = try? AITextOpenAIRequestBuilder.makeRequest(
            configuration: configuration,
            sourceText: "request-source"
        ),
        request.url == endpoint,
        request.httpMethod == "POST",
        request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value",
        let body = request.httpBody,
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        object["model"] as? String == "example-model",
        object["stream"] as? Bool == true else { return false }

        do {
            try store.delete()
            let target = root.appendingPathComponent("outside")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: store.configurationURL,
                                                       withDestinationURL: target)
            do {
                _ = try store.load()
                return false
            } catch {
                // A symlink must fail closed.
            }
        } catch {
            return false
        }
        return true
    }

    private static func workspaceGatesAndDelivery() -> Bool {
        let source = BufferModel()
        source.append("source")
        let provider = AITextSmokeProvider()
        let selection = AITextSmokeSelection()
        let workspace = AITextPluginWorkspace(provider: provider,
                                              sourceModel: source,
                                              isSelected: { selection.selected })
        workspace.start()
        defer { workspace.stop() }
        guard workspace.canGenerate, workspace.generate(), provider.requests.count == 1 else {
            return false
        }
        provider.emit(AITextProviderBlock(index: 0, text: "draft", title: nil), request: 0)
        guard let partialID = workspace.outputBlocks.first?.id,
              workspace.outputBlocks.first?.incomplete == true,
              workspace.deliveryPendingBlocks.isEmpty,
              workspace.hasIncompleteDeliveryBlocks else { return false }
        provider.emit(AITextProviderBlock(index: 0, text: "draft updated", title: nil), request: 0)
        guard workspace.outputBlocks.first?.id == partialID else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "final one", title: nil),
            AITextProviderBlock(index: 1, text: "final two", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 2,
              workspace.outputBlocks[0].id == partialID,
              workspace.railSnapshot.outputBlocks.count == 2 else { return false }

        let firstGeneration = workspace.deliveryGeneration
        let firstID = workspace.outputBlocks[0].id
        workspace.consumeDelivered(blockIDs: [firstID], generation: firstGeneration)
        guard source.stagedText == "source", workspace.outputBlocks.count == 1 else {
            return false
        }
        let secondGeneration = workspace.deliveryGeneration
        let secondID = workspace.outputBlocks[0].id
        workspace.consumeDelivered(blockIDs: [secondID], generation: secondGeneration)
        guard source.stagedText.isEmpty, workspace.outputBlocks.isEmpty else { return false }

        source.append("stale")
        guard workspace.generate(), provider.requests.count == 2 else { return false }
        workspace.reset()
        provider.emit(AITextProviderBlock(index: 0, text: "must-ignore", title: nil), request: 1)
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "must-ignore", title: nil),
        ]), request: 1)
        guard workspace.outputBlocks.isEmpty else { return false }

        guard workspace.generate(), provider.requests.count == 3 else { return false }
        source.append(" changed")
        guard provider.cancellations[2].wasCancelled,
              workspace.outputBlocks.isEmpty else { return false }
        guard workspace.generate(), provider.requests.count == 4 else { return false }
        workspace.setProtected(true)
        guard provider.cancellations[3].wasCancelled,
              !workspace.canGenerate,
              workspace.outputBlocks.isEmpty else { return false }
        workspace.setProtected(false)
        return workspace.canGenerate
    }

    private static func remoteMirrorAndActionReview() -> Bool {
        let remoteSource = BufferModel()
        remoteSource.stageExternal("remote", origin: .remotePeer(deviceID: "peer"))
        let remoteProvider = AITextSmokeProvider(kind: .claudeCodeCLI)
        let remoteWorkspace = AITextPluginWorkspace(provider: remoteProvider,
                                                    sourceModel: remoteSource,
                                                    isSelected: { true })
        remoteWorkspace.start()
        defer { remoteWorkspace.stop() }
        guard remoteWorkspace.generate() else { return false }
        remoteProvider.finish(.success([
            AITextProviderBlock(index: 0, text: "derived", title: nil),
        ]), request: 0)
        guard let derived = remoteWorkspace.deliveryPendingBlocks.first,
              !derived.origin.allowsRemoteMirror else { return false }

        let actionSource = BufferModel()
        var focus = FocusEpochState()
        let token = focus.activate()
        let unreviewed = BufferModel.PluginMetadata(
            pluginId: "example.action",
            actionId: "reply",
            requestId: "request",
            contextId: "context",
            focusToken: token,
            runtimeIdentity: "runtime",
            reviewedAsPlainText: false
        )
        actionSource.append("bound", origin: .plugin(id: "example.action"), pluginMetadata: unreviewed)
        let actionProvider = AITextSmokeProvider(kind: .openAICompatible)
        let actionWorkspace = AITextPluginWorkspace(provider: actionProvider,
                                                    sourceModel: actionSource,
                                                    isSelected: { true })
        actionWorkspace.start()
        defer { actionWorkspace.stop() }
        guard !actionWorkspace.canGenerate,
              !actionWorkspace.generate(),
              actionProvider.requests.isEmpty else { return false }

        let reviewedSource = BufferModel()
        reviewedSource.append("reviewed",
                              origin: .plugin(id: "example.action"),
                              pluginMetadata: unreviewed.markingReviewedAsPlainText())
        let reviewedWorkspace = AITextPluginWorkspace(provider: actionProvider,
                                                      sourceModel: reviewedSource,
                                                      isSelected: { true })
        reviewedWorkspace.start()
        defer { reviewedWorkspace.stop() }
        return reviewedWorkspace.canGenerate
    }
}

/// Pure/fake smoke: no URLSession is started and no executable is launched.
func runAITextPluginSmokeTest() -> Bool {
    let passed = AITextPluginSmoke.run()
    print(passed ? "AI text plugin smoke OK" : "FAILED: AI text plugin smoke")
    return passed
}
