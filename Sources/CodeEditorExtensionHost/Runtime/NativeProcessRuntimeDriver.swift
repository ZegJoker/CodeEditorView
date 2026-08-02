import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import Foundation

public struct NativeProcessRuntimeDriver: ExtensionRuntimeDriver {
    public let kind: ExtensionRuntimeKind = .nativeProcess
    public var platformProfile: PlatformCapabilityProfile

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
    }

    public func prepare(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) async throws -> PreparedExtension {
        let decision = NativeHelperLaunchPolicy.evaluate(
            trustClass: package.trustClass,
            origin: package.origin,
            policy: policy
        )
        guard decision.allowed else {
            throw RuntimeSelectionError.profileDenied(decision.reasons.joined(separator: "; "))
        }
        try ExtensionPackageVerifier.assertNativeLaunchAllowed(
            trust: package.trustClass,
            policy: policy.trust
        )
        guard package.nativeExecutable != nil else {
            throw RuntimeSelectionError.missingArtifact
        }
        guard policy.platformAllowsNativeProcess else {
            throw RuntimeSelectionError.nativeNotAllowed
        }
        // Align driver profile with shipping policy matrix.
        if !policy.platformProfile.availability(for: .nativeExtensionProcess).isLocallyAvailable {
            throw RuntimeSelectionError.nativeNotAllowed
        }
        return PreparedExtension(package: package, kind: .nativeProcess)
    }

    public func start(
        prepared: PreparedExtension,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) async throws -> any ExtensionInstance {
        guard let executable = prepared.package.nativeExecutable else {
            throw RuntimeSelectionError.missingArtifact
        }
        let transport = try NativeHelperProcessTransport(
            executable: executable,
            arguments: [],
            currentDirectory: prepared.package.packageRoot,
            platformProfile: platformProfile
        )
        let instance = NativeProcessExtensionInstance(
            package: prepared.package,
            transport: transport,
            handshake: handshake,
            broker: broker
        )
        try await instance.start()
        return instance
    }

    /// Start against an existing duplex transport (tests / mock peer).
    public func startWithTransport(
        package: PreparedExtensionPackage,
        transport: any ExtensionWireTransport,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) async throws -> NativeProcessExtensionInstance {
        let instance = NativeProcessExtensionInstance(
            package: package,
            transport: transport,
            handshake: handshake,
            broker: broker
        )
        try await instance.start()
        return instance
    }
}

public actor NativeProcessExtensionInstance: ExtensionInstance {
    public nonisolated let identity: ExtensionID
    public nonisolated let generation: UInt64
    public nonisolated let runtimeKind: ExtensionRuntimeKind = .nativeProcess

    private let package: PreparedExtensionPackage
    private let transport: any ExtensionWireTransport
    private let handshake: ExtensionHostHandshake
    private let broker: CapabilityBroker
    private var connection: ExtensionWireConnection?
    private var _state: ExtensionInstanceState = .ready
    private let tracer = ConformanceTracer()
    private var eventContinuation: AsyncStream<ExtensionInstanceEvent>.Continuation?
    public nonisolated let events: AsyncStream<ExtensionInstanceEvent>
    private var nativeTransport: NativeHelperProcessTransport?
    private var activated = false

    public init(
        package: PreparedExtensionPackage,
        transport: any ExtensionWireTransport,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) {
        self.package = package
        self.transport = transport
        self.handshake = handshake
        self.broker = broker
        self.identity = package.packageID
        self.generation = handshake.generation
        self.nativeTransport = transport as? NativeHelperProcessTransport
        var cont: AsyncStream<ExtensionInstanceEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public var state: ExtensionInstanceState { _state }

    public func start() async throws {
        _state = .activating
        eventContinuation?.yield(.state(.activating))

        let connection = ExtensionWireConnection(
            transport: transport,
            maxPayloadBytes: handshake.limits.maxPayloadBytes,
            maxFrameBytes: handshake.limits.maxFrameBytes,
            defaultTimeout: .milliseconds(handshake.limits.requestTimeoutMS),
            generation: handshake.generation,
            streamWindow: handshake.limits.streamWindow
        )
        self.connection = connection

        // Install handshake waiter BEFORE starting the reader so early frames are not lost.
        let handshakeBox = HandshakeBox()
        await connection.setEnvelopeHandler { envelope in
            if case .handshake(let h) = envelope {
                await handshakeBox.complete(h)
            }
        }
        await connection.start()

        let guestHandshake: ExtensionWireHandshake = try await withThrowingTaskGroup(of: ExtensionWireHandshake.self) {
            group in
            group.addTask {
                try await handshakeBox.wait()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ExtensionWireError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if handshake.requireSchemaMatch,
            guestHandshake.schemaHash != ExtensionMethodCatalog.schemaHash
        {
            let reject = ExtensionWireHandshakeResult(
                accepted: false,
                rejectReason: "schema hash mismatch"
            )
            try await connection.send(.handshakeResult(reject))
            await stop(reason: .error)
            throw ExtensionWireError.schemaMismatch
        }
        if !guestHandshake.protocolVersion.isCompatible(with: .current) {
            let reject = ExtensionWireHandshakeResult(
                accepted: false,
                rejectReason: "incompatible protocol"
            )
            try await connection.send(.handshakeResult(reject))
            await stop(reason: .error)
            throw ExtensionWireError.incompatibleProtocol
        }

        let granted = package.manifest.requestedPermissions.intersection(handshake.environment.grantedPermissions)
        await broker.registerExtension(id: identity, generation: generation, granted: granted)

        let result = ExtensionWireHandshakeResult(
            accepted: true,
            hostCapabilities: handshake.environment.capabilities.map(\.rawValue).sorted(),
            grantedPermissions: granted.map(\.rawValue).sorted(),
            limits: handshake.limits,
            generation: generation
        )
        try await connection.send(.handshakeResult(result))
        await connection.setGeneration(generation)

        // Activate extension
        _ = try await connection.request(.activate, payload: Data(), timeout: .seconds(3))
        activated = true
        tracer.record(method: .activate, direction: "host→guest", payload: Data(), generation: generation)
        _state = .active
        eventContinuation?.yield(.state(.active))
        if let last = tracer.snapshot().last {
            eventContinuation?.yield(.trace(last))
        }

        // Ongoing handler for notifications
        await connection.setEnvelopeHandler { [weak self] envelope in
            await self?.handleAsync(envelope)
        }
    }

    private func handleAsync(_ envelope: ExtensionEnvelope) async {
        switch envelope {
        case .notification(let kind, let payload):
            if kind == "crashed" {
                _state = .failed
                eventContinuation?.yield(.crashed(String(data: payload, encoding: .utf8) ?? "crash"))
            }
        default:
            break
        }
    }

    public func send(_ envelope: ExtensionEnvelope) async throws {
        try await connection?.send(envelope)
    }

    public func request(_ method: ExtensionMethodID, payload: Data) async throws -> Data {
        guard let connection else { throw ExtensionWireError.transportClosed }
        tracer.record(method: method, direction: "host→guest", payload: payload, generation: generation)
        do {
            let result = try await connection.request(method, payload: payload)
            tracer.record(method: method, direction: "guest→host", payload: result, generation: generation)
            return result
        } catch let err as ExtensionWireError {
            tracer.record(
                method: method,
                direction: "guest→host",
                payload: Data(),
                errorCode: err.code,
                generation: generation
            )
            throw err
        }
    }

    public func cancel(_ requestID: ExtensionRequestID) async {
        await connection?.cancel(id: requestID)
    }

    public func stop(reason: ExtensionStopReason) async {
        _state = .deactivating
        if let connection {
            if activated {
                _ = try? await connection.request(.deactivate, payload: Data(), timeout: .milliseconds(500))
            }
            await connection.close()
        }
        self.connection = nil
        activated = false
        if let native = nativeTransport {
            await native.close()
        } else {
            await transport.close()
        }
        await broker.revokeExtension(id: identity)
        _state = .stopped
        eventContinuation?.yield(.state(.stopped))
        eventContinuation?.finish()
    }

    public func conformanceTrace() -> [ConformanceEvent] {
        tracer.snapshot()
    }

    public func processIdentifier() -> Int32? {
        nativeTransport?.processIdentifier
    }
}

/// One-shot handshake capture safe for race with reader start.
private actor HandshakeBox {
    private var value: ExtensionWireHandshake?
    private var waiters: [CheckedContinuation<ExtensionWireHandshake, Error>] = []

    func complete(_ h: ExtensionWireHandshake) {
        if value != nil { return }
        value = h
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume(returning: h) }
    }

    func wait() async throws -> ExtensionWireHandshake {
        if let value { return value }
        return try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
        }
    }
}
