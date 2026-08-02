import CodeEditorCore
import CodeEditorDAP
import CodeEditorDocuments
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import CodeEditorLanguageServices
import Foundation

public struct BuiltInSwiftRuntimeDriver: ExtensionRuntimeDriver {
    public let kind: ExtensionRuntimeKind = .builtIn
    public let services: ExtensionHostServices
    public let environment: HostEnvironment

    public init(services: ExtensionHostServices, environment: HostEnvironment = .full) {
        self.services = services
        self.environment = environment
    }

    public func prepare(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) async throws -> PreparedExtension {
        guard package.builtInExtension != nil else {
            throw RuntimeSelectionError.missingArtifact
        }
        return PreparedExtension(package: package, kind: .builtIn)
    }

    public func start(
        prepared: PreparedExtension,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) async throws -> any ExtensionInstance {
        guard let ext = prepared.package.builtInExtension else {
            throw RuntimeSelectionError.missingArtifact
        }
        let instance = BuiltInExtensionInstance(
            ext: ext,
            services: services,
            environment: handshake.environment,
            generation: handshake.generation,
            broker: broker
        )
        try await instance.activate()
        return instance
    }
}

public actor BuiltInExtensionInstance: ExtensionInstance {
    public nonisolated let identity: ExtensionID
    public nonisolated let generation: UInt64
    public nonisolated let runtimeKind: ExtensionRuntimeKind = .builtIn

    private let ext: any CodeEditorExtension
    private let runtime: ExtensionRuntime
    private let broker: CapabilityBroker
    private let environment: HostEnvironment
    private let tracer = ConformanceTracer()
    private var _state: ExtensionInstanceState = .ready
    private var eventContinuation: AsyncStream<ExtensionInstanceEvent>.Continuation?
    public nonisolated let events: AsyncStream<ExtensionInstanceEvent>
    /// Optional procedural providers (Phase 12–13). Methods fail with methodNotFound when unset.
    private var languageServerProvider: (any LanguageServerProvider)?
    private var debugAdapterProvider: (any DebugAdapterProvider)?
    private var debugLocatorProvider: (any DebugLocatorProvider)?
    private var mcpServerProvider: (any MCPServerProvider)?
    private var slashCommandProvider: (any SlashCommandProvider)?
    private var documentationIndexProvider: (any DocumentationIndexProvider)?
    private var debugAdapterExecutor: DebugAdapterLaunchPlanExecutor?
    private var mcpLaunchExecutor: MCPLaunchPlanExecutor?
    private var slashCommandService: SlashCommandService?
    private var documentationIndexService: DocumentationIndexService?

    public init(
        ext: any CodeEditorExtension,
        services: ExtensionHostServices,
        environment: HostEnvironment,
        generation: UInt64,
        broker: CapabilityBroker,
        languageServerProvider: (any LanguageServerProvider)? = nil
    ) {
        self.ext = ext
        self.identity = ext.manifest.id
        self.generation = generation
        self.broker = broker
        self.environment = environment
        self.languageServerProvider = languageServerProvider
        self.runtime = ExtensionRuntime(environment: environment, services: services)
        var cont: AsyncStream<ExtensionInstanceEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public func setLanguageServerProvider(_ provider: (any LanguageServerProvider)?) {
        languageServerProvider = provider
    }

    public func setDebugAdapterProvider(_ provider: (any DebugAdapterProvider)?) {
        debugAdapterProvider = provider
    }

    public func setDebugLocatorProvider(_ provider: (any DebugLocatorProvider)?) {
        debugLocatorProvider = provider
    }

    public func setMCPServerProvider(_ provider: (any MCPServerProvider)?) {
        mcpServerProvider = provider
    }

    public func setSlashCommandProvider(_ provider: (any SlashCommandProvider)?) {
        slashCommandProvider = provider
    }

    public func setDocumentationIndexProvider(_ provider: (any DocumentationIndexProvider)?) {
        documentationIndexProvider = provider
    }

    public func setDebugAdapterExecutor(_ executor: DebugAdapterLaunchPlanExecutor?) {
        debugAdapterExecutor = executor
    }

    public func setMCPLaunchExecutor(_ executor: MCPLaunchPlanExecutor?) {
        mcpLaunchExecutor = executor
    }

    public func setSlashCommandService(_ service: SlashCommandService?) {
        slashCommandService = service
    }

    public func setDocumentationIndexService(_ service: DocumentationIndexService?) {
        documentationIndexService = service
    }

    public var state: ExtensionInstanceState { _state }

    public func activate() async throws {
        _state = .activating
        eventContinuation?.yield(.state(.activating))
        let perms = ext.manifest.requestedPermissions.intersection(environment.grantedPermissions)
        await broker.registerExtension(id: identity, generation: generation, granted: perms)
        await runtime.register(ext)
        try await runtime.activate(id: identity)
        _state = .active
        eventContinuation?.yield(.state(.active))
        tracer.record(method: .activate, direction: "local", payload: Data(), generation: generation)
        if let last = tracer.snapshot().last {
            eventContinuation?.yield(.trace(last))
        }
    }

    public func send(_ envelope: ExtensionEnvelope) async throws {
        if case .request(_, let method, let payload, _, _) = envelope {
            _ = try await request(method, payload: payload)
        }
    }

    public func request(_ method: ExtensionMethodID, payload: Data) async throws -> Data {
        tracer.record(method: method, direction: "local", payload: payload, generation: generation)
        switch method {
        case .ping:
            return Data(#"{"ok":true}"#.utf8)
        case .activate:
            return Data()
        case .deactivate:
            await runtime.deactivate(id: identity)
            return Data()
        case .completion:
            let list = CompletionList(items: [
                CompletionItem(label: "conformanceHello", kind: .function, insertText: "conformanceHello()")
            ])
            return try JSONEncoder().encode(list)
        case .hover:
            let hover = Hover(sections: [HoverSection(content: .markdown("**conformance** hover"))])
            return try JSONEncoder().encode(hover)
        case .definition:
            let uri = DocumentURI(rawValue: "inmemory:conformance")
            let range = TextRange(location: 0, length: 1)
            let links = [LocationLink(targetURI: uri, targetRange: range, targetSelectionRange: range)]
            return try JSONEncoder().encode(links)
        case .echo:
            return payload
        case .spawnChild:
            // Built-in can also spawn for symmetry tests
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["2"]
            try process.run()
            var data = Data()
            var pid = process.processIdentifier
            withUnsafeBytes(of: &pid) { data.append(contentsOf: $0) }
            return data
        case .lsResolveLaunchPlan, .lsInitializationOptions, .lsWorkspaceConfiguration,
            .lsTransformCompletionLabel, .lsTransformSymbolLabel, .lsStatus, .lsRestart:
            guard let provider = languageServerProvider else {
                throw ExtensionWireError.methodNotFound
            }
            return try await LanguageServerWireCodec.dispatch(
                method: method,
                payload: payload,
                provider: provider,
                extensionID: identity
            )
        case .dapResolveLaunchPlan, .dapResolveConfigurations, .dapLocate, .dapStatus, .dapRestart:
            guard let provider = debugAdapterProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let adapterID = Phase13WireCodec.parseID(payload, keys: ["adapterID", "id"])
            let status: DebugAdapterStatus?
            if let exec = debugAdapterExecutor, !adapterID.isEmpty {
                status = await exec.statusStore.status(adapterID: adapterID, extensionID: identity)
            } else {
                status = nil
            }
            return try await Phase13WireCodec.dispatchDAP(
                method: method,
                payload: payload,
                provider: provider,
                locator: debugLocatorProvider,
                extensionID: identity,
                status: status,
                onRestart: { [debugAdapterExecutor] id in
                    guard let exec = debugAdapterExecutor else {
                        throw ExtensionWireError(code: -32004, message: "DAP executor not wired")
                    }
                    try await exec.pool.restart(id: DebugAdapterID(rawValue: id))
                }
            )
        case .mcpResolveLaunchPlan, .mcpStatus, .mcpRestart:
            guard let provider = mcpServerProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let serverID = Phase13WireCodec.parseID(payload, keys: ["serverID", "id"])
            let status: MCPServerStatus?
            if let exec = mcpLaunchExecutor, !serverID.isEmpty {
                status = await exec.status(serverID: serverID, extensionID: identity)
            } else {
                status = nil
            }
            let extID = identity
            return try await Phase13WireCodec.dispatchMCP(
                method: method,
                payload: payload,
                provider: provider,
                extensionID: identity,
                status: status,
                onRestart: { [mcpLaunchExecutor] id in
                    guard let exec = mcpLaunchExecutor else {
                        throw ExtensionWireError(code: -32004, message: "MCP executor not wired")
                    }
                    _ = try await exec.restart(serverID: id, extensionID: extID)
                }
            )
        case .slashExecute:
            if let service = slashCommandService {
                let commandID = Phase13WireCodec.parseID(payload, keys: ["commandID", "id"])
                let arguments = Phase13WireCodec.parseArguments(payload)
                var chunks: [SlashCommandChunk] = []
                for try await chunk in await service.execute(
                    commandID: commandID,
                    arguments: arguments,
                    extensionID: identity
                ) {
                    chunks.append(chunk)
                }
                return try JSONEncoder().encode(chunks)
            }
            guard let provider = slashCommandProvider else {
                throw ExtensionWireError.methodNotFound
            }
            return try await Phase13WireCodec.dispatchSlash(
                method: method,
                payload: payload,
                provider: provider,
                extensionID: identity
            )
        case .docsSuggest, .docsBuildIndex, .docsInvalidate:
            if let service = documentationIndexService, method == .docsSuggest {
                let suggestions = try await service.suggest(
                    extensionID: identity,
                    context: LanguageServerResolveContext(extensionID: identity)
                )
                return try JSONEncoder().encode(suggestions)
            }
            if let service = documentationIndexService, method == .docsInvalidate {
                let packageID = Phase13WireCodec.parseID(payload, keys: ["packageID", "id"])
                await service.invalidate(
                    packageID: packageID.isEmpty ? nil : packageID,
                    extensionID: identity
                )
                return try JSONSerialization.data(withJSONObject: ["ok": true])
            }
            if let service = documentationIndexService, method == .docsBuildIndex {
                let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
                let packageID = obj["packageID"] as? String ?? obj["id"] as? String ?? ""
                guard !packageID.isEmpty else {
                    throw ExtensionWireError(code: -32602, message: "packageID required")
                }
                let suggestion = DocumentationPackageSuggestion(
                    id: packageID,
                    title: obj["title"] as? String ?? packageID,
                    languages: obj["languages"] as? [String] ?? [],
                    sourcePath: obj["sourcePath"] as? String
                )
                let roots = obj["workspaceRoot"] as? String
                let rootURL = roots.map { URL(fileURLWithPath: $0) }
                let entries = try await service.buildIndex(
                    package: suggestion,
                    extensionID: identity,
                    context: LanguageServerResolveContext(extensionID: identity),
                    worktreeRoot: rootURL
                )
                return try JSONEncoder().encode(entries)
            }
            guard let provider = documentationIndexProvider else {
                throw ExtensionWireError.methodNotFound
            }
            return try await Phase13WireCodec.dispatchDocs(
                method: method,
                payload: payload,
                provider: provider,
                extensionID: identity
            )
        default:
            if method.rawValue.hasPrefix("broker.") {
                return try await broker.dispatch(method: method, extensionID: identity, payload: payload)
            }
            throw ExtensionWireError.methodNotFound
        }
    }

    public func cancel(_ requestID: ExtensionRequestID) async {}

    public func stop(reason: ExtensionStopReason) async {
        _state = .deactivating
        await runtime.deactivate(id: identity)
        await broker.revokeExtension(id: identity)
        _state = .stopped
        eventContinuation?.yield(.state(.stopped))
        eventContinuation?.finish()
    }

    public func conformanceTrace() -> [ConformanceEvent] {
        tracer.snapshot()
    }
}
