import CodeEditorExtensions
import Foundation

public actor RemoteExtensionProcess {
    public let descriptor: RemoteExtensionDescriptor
    public private(set) var state: ExtensionProcessState = .idle
    public private(set) var health = ExtensionProcessHealth()
    public private(set) var grantedPermissions: Set<ExtensionPermission> = []
    public private(set) var lastError: String?

    private let environment: HostEnvironment
    private let policy: RemoteExtensionHostPolicy
    private var connection: ExtensionRPCConnection?
    private var transport: (any RemoteExtensionTransport)?
    private var transportFactory: (@Sendable () async throws -> any RemoteExtensionTransport)?
    private var onCrashed: (@Sendable () async -> Void)?

    public init(
        descriptor: RemoteExtensionDescriptor,
        environment: HostEnvironment,
        policy: RemoteExtensionHostPolicy = .default,
        transportFactory: (@Sendable () async throws -> any RemoteExtensionTransport)? = nil
    ) {
        self.descriptor = descriptor
        self.environment = environment
        self.policy = policy
        self.transportFactory = transportFactory
    }

    public func setCrashHandler(_ handler: @escaping @Sendable () async -> Void) {
        onCrashed = handler
    }

    public func start() async throws {
        guard state == .idle || state == .stopped || state == .crashed else {
            if state == .running { return }
            throw ExtensionHostError.alreadyRunning
        }
        state = .starting
        lastError = nil
        do {
            let transport = try await makeTransport()
            self.transport = transport
            let connection = ExtensionRPCConnection(
                transport: transport,
                maxPayloadBytes: policy.maxResponseBytes,
                defaultTimeout: policy.requestTimeout
            )
            self.connection = connection
            await connection.start()
            await connection.setEnvelopeHandler { [weak self] envelope in
                await self?.handleInbound(envelope)
            }

            // Wait for remote handshake (server initiates) or send host readiness by reading first message.
            // Protocol: remote sends handshake first; host replies with handshakeResult.
            // For mock servers that wait for host, we also accept host-driven handshake by sending nothing and waiting.
            try await waitForHandshakeAndAccept()
            state = .running
        } catch {
            state = .crashed
            lastError = String(describing: error)
            await cleanup()
            throw error
        }
    }

    public func shutdown() async {
        if let connection {
            _ = try? await connection.request(.deactivate, payload: Data(), timeout: .seconds(2))
        }
        await cleanup()
        state = .stopped
    }

    public func restart() async throws {
        state = .restarting
        await cleanup()
        try await start()
    }

    public func ping() async throws {
        _ = try await call(.ping, payload: Data())
        health.lastPong = Date()
        health.consecutiveTimeouts = 0
    }

    public func call(_ method: ExtensionRPCMethod, payload: Data = Data()) async throws -> Data {
        guard state == .running, let connection else { throw ExtensionHostError.notRunning }
        do {
            return try await connection.request(method, payload: payload, timeout: policy.requestTimeout)
        } catch ExtensionHostError.timeout {
            health.consecutiveTimeouts += 1
            if health.consecutiveTimeouts >= 3 {
                state = .unhealthy
            }
            throw ExtensionHostError.timeout
        } catch ExtensionHostError.transportClosed {
            await markCrashed(reason: "transport closed")
            throw ExtensionHostError.transportClosed
        }
    }

    public func markCrashed(reason: String) async {
        guard state != .crashed && state != .stopped else { return }
        state = .crashed
        lastError = reason
        await cleanup()
        await onCrashed?()
    }

    // MARK: - Private

    private func makeTransport() async throws -> any RemoteExtensionTransport {
        if let transportFactory {
            return try await transportFactory()
        }
        switch descriptor.launch {
        case .process(let executable, let arguments):
            return try ProcessRemoteExtensionTransport(executable: executable, arguments: arguments)
        case .testFactory:
            throw ExtensionHostError.notFound("test factory requires transportFactory")
        case .extensionKit:
            throw ExtensionHostError.notFound("ExtensionKit launch requires host-provided transport")
        }
    }

    private var handshakeContinuation: CheckedContinuation<ExtensionRPCHandshake, Error>?

    private func waitForHandshakeAndAccept() async throws {
        let handshake: ExtensionRPCHandshake = try await withThrowingTaskGroup(of: ExtensionRPCHandshake.self) {
            group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExtensionRPCHandshake, Error>) in
                    Task { await self.setHandshakeContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ExtensionHostError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guard handshake.protocolVersion.isCompatible(with: .current) else {
            let result = ExtensionRPCHandshakeResult(
                accepted: false,
                protocolVersion: .current,
                rejectReason:
                    "incompatible protocol \(handshake.protocolVersion.major).\(handshake.protocolVersion.minor)"
            )
            try await connection?.send(.handshakeResult(result))
            throw ExtensionHostError.incompatibleProtocol(result.rejectReason ?? "")
        }

        let grants = handshake.extensionManifest.requestedPermissions.intersection(environment.grantedPermissions)
        let missingCaps = handshake.extensionManifest.requiredHostCapabilities.subtracting(environment.capabilities)
        if !missingCaps.isEmpty {
            let result = ExtensionRPCHandshakeResult(
                accepted: false,
                protocolVersion: .current,
                rejectReason: "missing capabilities"
            )
            try await connection?.send(.handshakeResult(result))
            throw ExtensionHostError.rejected("missing capabilities")
        }
        if !handshake.extensionManifest.requiredAPIVersion.contains(environment.apiVersion) {
            let result = ExtensionRPCHandshakeResult(
                accepted: false,
                protocolVersion: .current,
                rejectReason: "incompatible API version"
            )
            try await connection?.send(.handshakeResult(result))
            throw ExtensionHostError.rejected("incompatible API version")
        }

        grantedPermissions = grants
        let result = ExtensionRPCHandshakeResult(
            accepted: true,
            protocolVersion: .current,
            hostCapabilities: environment.capabilities,
            grantedPermissions: grants
        )
        try await connection?.send(.handshakeResult(result))
        // Activate remote
        _ = try await connection?.request(.activate, payload: Data(), timeout: policy.requestTimeout)
    }

    private func setHandshakeContinuation(_ cont: CheckedContinuation<ExtensionRPCHandshake, Error>) {
        if closedHandshake {
            cont.resume(throwing: ExtensionHostError.transportClosed)
            return
        }
        if let early = earlyHandshake {
            earlyHandshake = nil
            cont.resume(returning: early)
            return
        }
        handshakeContinuation = cont
    }

    private var earlyHandshake: ExtensionRPCHandshake?
    private var closedHandshake = false

    private func handleInbound(_ envelope: ExtensionRPCEnvelope) async {
        switch envelope {
        case .handshake(let hs):
            if let cont = handshakeContinuation {
                handshakeContinuation = nil
                cont.resume(returning: hs)
            } else {
                earlyHandshake = hs
            }
        case .notification(.crashed(let reason)):
            await markCrashed(reason: reason)
        case .notification(.health(let h)):
            health = h
        default:
            break
        }
    }

    private func cleanup() async {
        closedHandshake = true
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: ExtensionHostError.transportClosed)
        }
        await connection?.close()
        connection = nil
        transport = nil
    }
}
