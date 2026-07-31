import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions

/// Multi-driver host orchestrator: selection, start/stop, restart, quarantine.
public actor ExtensionHostOrchestrator {
    public let policy: ExtensionExecutionPolicy
    public let environment: HostEnvironment
    public let services: ExtensionHostServices
    public let broker: CapabilityBroker

    private var packages: [ExtensionID: PreparedExtensionPackage] = [:]
    private var instances: [ExtensionID: any ExtensionInstance] = [:]
    private var states: [ExtensionID: ExtensionInstanceState] = [:]
    private var crashCounts: [ExtensionID: Int] = [:]
    private var restartCounts: [ExtensionID: Int] = [:]
    private var generationCounter: UInt64 = 0

    private var statusContinuation: AsyncStream<[OrchestratorStatus]>.Continuation?
    public let statusStream: AsyncStream<[OrchestratorStatus]>

    public struct OrchestratorStatus: Sendable, Hashable {
        public var id: ExtensionID
        public var state: ExtensionInstanceState
        public var runtime: ExtensionRuntimeKind?
        public var lastError: String?
    }

    public init(
        services: ExtensionHostServices,
        broker: CapabilityBroker,
        environment: HostEnvironment = .full,
        policy: ExtensionExecutionPolicy = .testing
    ) {
        self.services = services
        self.broker = broker
        self.environment = environment
        self.policy = policy
        var cont: AsyncStream<[OrchestratorStatus]>.Continuation!
        self.statusStream = AsyncStream { cont = $0 }
        self.statusContinuation = cont
    }

    public func register(package: PreparedExtensionPackage) {
        packages[package.packageID] = package
        if states[package.packageID] == nil {
            states[package.packageID] = .ready
        }
        publish()
    }

    public func start(id: ExtensionID) async throws {
        if states[id] == .quarantined {
            throw ExtensionWireError.quarantined
        }
        if let existing = instances[id] {
            let st = await existing.state
            if st == .active { return }
        }
        guard let package = packages[id] else {
            throw ExtensionHostError.notFound(id.rawValue)
        }
        let kind = try RuntimeSelector.select(package: package, policy: policy)
        generationCounter &+= 1
        let handshake = ExtensionHostHandshake(
            environment: environment,
            generation: generationCounter
        )

        let prepared: PreparedExtension
        let instance: any ExtensionInstance
        switch kind {
        case .builtIn:
            let driver = BuiltInSwiftRuntimeDriver(services: services, environment: environment)
            prepared = try await driver.prepare(package: package, policy: policy)
            instance = try await driver.start(prepared: prepared, handshake: handshake, broker: broker)
        case .nativeProcess:
            let driver = NativeProcessRuntimeDriver()
            prepared = try await driver.prepare(package: package, policy: policy)
            instance = try await driver.start(prepared: prepared, handshake: handshake, broker: broker)
        case .dataOnly:
            states[id] = .active
            publish()
            return
        case .swiftWasm:
            throw RuntimeSelectionError.wasmNotAvailable
        case .remote:
            throw RuntimeSelectionError.noPermittedRuntime
        }
        instances[id] = instance
        states[id] = .active
        crashCounts[id] = 0
        publish()
    }

    /// Test helper: start native path over mock transport with guest already running.
    public func startNativeMock(
        package: PreparedExtensionPackage,
        transport: any ExtensionWireTransport
    ) async throws -> NativeProcessExtensionInstance {
        packages[package.packageID] = package
        generationCounter &+= 1
        let handshake = ExtensionHostHandshake(
            environment: environment,
            generation: generationCounter
        )
        let driver = NativeProcessRuntimeDriver()
        let instance = try await driver.startWithTransport(
            package: package,
            transport: transport,
            handshake: handshake,
            broker: broker
        )
        instances[package.packageID] = instance
        states[package.packageID] = .active
        publish()
        return instance
    }

    public func stop(id: ExtensionID, reason: ExtensionStopReason = .user) async {
        if let instance = instances.removeValue(forKey: id) {
            await instance.stop(reason: reason)
        }
        states[id] = .stopped
        publish()
    }

    public func restart(id: ExtensionID) async throws {
        let count = restartCounts[id, default: 0]
        if count >= policy.maxRestarts {
            await quarantine(id: id, reason: "restart limit")
            throw ExtensionWireError.quarantined
        }
        restartCounts[id] = count + 1
        await stop(id: id, reason: .crash)
        let backoff = policy.restartBackoffMS[min(count, policy.restartBackoffMS.count - 1)]
        try await Task.sleep(for: .milliseconds(backoff))
        try await start(id: id)
    }

    public func noteCrash(id: ExtensionID, reason: String) async {
        let n = crashCounts[id, default: 0] + 1
        crashCounts[id] = n
        await stop(id: id, reason: .crash)
        if n >= policy.quarantineCrashThreshold {
            await quarantine(id: id, reason: reason)
        } else {
            try? await restart(id: id)
        }
    }

    public func quarantine(id: ExtensionID, reason: String) async {
        await stop(id: id, reason: .quarantine)
        states[id] = .quarantined
        publish()
    }

    public func clearQuarantine(id: ExtensionID) {
        if states[id] == .quarantined {
            states[id] = .ready
            crashCounts[id] = 0
            restartCounts[id] = 0
            publish()
        }
    }

    public func instance(id: ExtensionID) -> (any ExtensionInstance)? {
        instances[id]
    }

    public func state(id: ExtensionID) -> ExtensionInstanceState? {
        states[id]
    }

    public func allStatuses() -> [OrchestratorStatus] {
        packages.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            OrchestratorStatus(
                id: id,
                state: states[id] ?? .discovered,
                runtime: nil,
                lastError: nil
            )
        }
    }

    private func publish() {
        statusContinuation?.yield(allStatuses())
    }
}
