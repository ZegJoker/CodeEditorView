import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import Foundation

/// Multi-driver host orchestrator: selection, start/stop, restart, quarantine.
///
/// When a store `ExtensionPackageManager` is attached, activation is **fail-closed**:
/// revoked / quarantined / verify-failed packages never start a driver.
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
    private var storeManager: ExtensionPackageManager?
    private var activationTelemetry: StoreTelemetrySink?
    private var lastErrors: [ExtensionID: String] = [:]

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

    /// Attach the versioned store manager for install/revocation/quarantine activation gates.
    public func attachPackageManager(_ manager: ExtensionPackageManager, telemetry: StoreTelemetrySink? = nil) {
        storeManager = manager
        activationTelemetry = telemetry
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

        // Phase 14 activation gate — no soft path that skips store/verify when attached/strict.
        try await enforceActivationGate(package: package)

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
            lastErrors[id] = nil
            publish()
            return
        case .swiftWasm:
            let driver = SwiftWasmRuntimeDriver()
            prepared = try await driver.prepare(package: package, policy: policy)
            instance = try await driver.start(prepared: prepared, handshake: handshake, broker: broker)
        case .remote:
            throw RuntimeSelectionError.noPermittedRuntime
        }
        instances[id] = instance
        states[id] = .active
        crashCounts[id] = 0
        lastErrors[id] = nil
        publish()
    }

    /// Fail-closed activation: store assert + package-root verify under current trust policy.
    private func enforceActivationGate(package: PreparedExtensionPackage) async throws {
        let id = package.packageID

        if let manager = storeManager {
            do {
                try await manager.assertCanActivate(id: id)
            } catch {
                let reason = String(describing: error)
                lastErrors[id] = reason
                activationTelemetry?.append(
                    StoreTelemetryEvent(
                        event: "activation.denied",
                        packageID: id.rawValue,
                        success: false,
                        reason: reason
                    ))
                states[id] = .quarantined
                publish()
                throw ExtensionWireError.quarantined
            }
        }

        // Always re-verify on-disk packages when a package root is present (built-in pure in-memory may omit root).
        if let root = package.packageRoot, package.builtInExtension == nil {
            do {
                let report = try ExtensionPackageVerifier.verifyDetailed(
                    packageRoot: root,
                    policy: policy.trust
                )
                try ExtensionPackageVerifier.assertNativeLaunchAllowed(
                    trust: report.trustClass,
                    policy: policy.trust
                )
                // Sync trust class from live verify
                if var updated = packages[id] {
                    updated.trustClass = report.trustClass
                    packages[id] = updated
                }
            } catch {
                let reason = String(describing: error)
                lastErrors[id] = reason
                activationTelemetry?.append(
                    StoreTelemetryEvent(
                        event: "activation.denied",
                        packageID: id.rawValue,
                        success: false,
                        reason: reason
                    ))
                await quarantine(id: id, reason: reason)
                throw ExtensionWireError.quarantined
            }
        }
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
                lastError: lastErrors[id]
            )
        }
    }

    /// Host-facing trust status items from the attached store (empty if none).
    public func trustStatusItems() async -> [ExtensionTrustStatusItem] {
        guard let manager = storeManager else { return [] }
        return await manager.trustStatusItems()
    }

    public func trustPromptIfNeeded(for id: ExtensionID) async -> TrustPromptDescriptor? {
        guard let manager = storeManager else { return nil }
        return await manager.trustPromptIfNeeded(for: id)
    }

    private func publish() {
        statusContinuation?.yield(allStatuses())
    }
}
