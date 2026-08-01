import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorExtensions
import CodeEditorWasmEngine
import Foundation

public struct SwiftWasmRuntimeDriver: ExtensionRuntimeDriver {
    public let kind: ExtensionRuntimeKind = .swiftWasm
    public let engine: any CodeEditorWasmEngine
    public let limits: WasmResourceLimits

    public init(
        engine: any CodeEditorWasmEngine = WasmEngineFactory.wasmKit(),
        limits: WasmResourceLimits = .default
    ) {
        self.engine = engine
        self.limits = limits
    }

    public func prepare(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) async throws -> PreparedExtension {
        guard let wasm = package.wasmModuleData ?? package.wasmModuleURL.flatMap({ try? Data(contentsOf: $0) }) else {
            throw RuntimeSelectionError.missingArtifact
        }
        try engine.validate(module: wasm, limits: limits)
        return PreparedExtension(package: package, kind: .swiftWasm)
    }

    public func start(
        prepared: PreparedExtension,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) async throws -> any ExtensionInstance {
        guard
            let wasm = prepared.package.wasmModuleData
                ?? prepared.package.wasmModuleURL.flatMap({ try? Data(contentsOf: $0) })
        else {
            throw RuntimeSelectionError.missingArtifact
        }
        let session = CoreWasmABISession(
            engine: engine,
            module: wasm,
            limits: limits,
            generation: handshake.generation
        )
        try await session.start()
        // Activate via CBOR
        _ = try await session.request(.activate, payload: Data(), timeout: .seconds(2))
        await broker.registerExtension(
            id: prepared.package.packageID,
            generation: handshake.generation,
            granted: prepared.package.manifest.requestedPermissions.intersection(
                handshake.environment.grantedPermissions)
        )
        return SwiftWasmExtensionInstance(
            identity: prepared.package.packageID,
            generation: handshake.generation,
            session: session,
            broker: broker
        )
    }
}

public actor SwiftWasmExtensionInstance: ExtensionInstance {
    public nonisolated let identity: ExtensionID
    public nonisolated let generation: UInt64
    public nonisolated let runtimeKind: ExtensionRuntimeKind = .swiftWasm

    private let session: CoreWasmABISession
    private let broker: CapabilityBroker
    private var _state: ExtensionInstanceState = .active
    private var eventContinuation: AsyncStream<ExtensionInstanceEvent>.Continuation?
    public nonisolated let events: AsyncStream<ExtensionInstanceEvent>

    public init(
        identity: ExtensionID,
        generation: UInt64,
        session: CoreWasmABISession,
        broker: CapabilityBroker
    ) {
        self.identity = identity
        self.generation = generation
        self.session = session
        self.broker = broker
        var cont: AsyncStream<ExtensionInstanceEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public var state: ExtensionInstanceState { _state }

    public func send(_ envelope: ExtensionEnvelope) async throws {
        if case .request(_, let method, let payload, _, _) = envelope {
            _ = try await request(method, payload: payload)
        }
    }

    public func request(_ method: ExtensionMethodID, payload: Data) async throws -> Data {
        try await session.request(method, payload: payload)
    }

    public func cancel(_ requestID: ExtensionRequestID) async {
        await session.cancel(requestID)
    }

    public func stop(reason: ExtensionStopReason) async {
        _state = .deactivating
        await session.stop()
        await broker.revokeExtension(id: identity)
        _state = .stopped
        eventContinuation?.yield(.state(.stopped))
        eventContinuation?.finish()
    }

    public func conformanceTrace() async -> [ConformanceEvent] {
        await session.conformanceTrace()
    }
}
