import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import CodeEditorLanguageServices
import CodeEditorCore
import CodeEditorDocuments

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
    /// Optional procedural language-server provider (Phase 12).
    private var languageServerProvider: (any LanguageServerProvider)?

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
                CompletionItem(label: "conformanceHello", kind: .function, insertText: "conformanceHello()"),
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
