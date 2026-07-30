import Foundation
import CodeEditorExtensions
import CodeEditorLanguageServices

public actor RemoteExtensionHost {
    public let environment: HostEnvironment
    public let services: ExtensionHostServices
    public let policy: RemoteExtensionHostPolicy

    private var discovery: any RemoteExtensionDiscovery
    private var descriptors: [ExtensionID: RemoteExtensionDescriptor] = [:]
    private var processes: [ExtensionID: RemoteExtensionProcess] = [:]
    private var providerRegs: [ExtensionID: RemoteProviderRegistration] = [:]
    private var restartCounts: [ExtensionID: Int] = [:]
    private var testFactories: [String: @Sendable () async throws -> any RemoteExtensionTransport] = [:]

    private var statusContinuation: AsyncStream<[RemoteExtensionStatus]>.Continuation?
    public let statusStream: AsyncStream<[RemoteExtensionStatus]>

    public init(
        environment: HostEnvironment = .full,
        services: ExtensionHostServices,
        discovery: any RemoteExtensionDiscovery,
        policy: RemoteExtensionHostPolicy = .default
    ) {
        self.environment = environment
        self.services = services
        self.discovery = discovery
        self.policy = policy
        var cont: AsyncStream<[RemoteExtensionStatus]>.Continuation!
        self.statusStream = AsyncStream { cont = $0 }
        self.statusContinuation = cont
    }

    public func registerTestFactory(
        id: String,
        factory: @escaping @Sendable () async throws -> any RemoteExtensionTransport
    ) {
        testFactories[id] = factory
    }

    public func refreshDiscovery() async throws {
        let found = try await discovery.discover()
        descriptors = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        publishStatuses()
    }

    public func startAllCompatible() async {
        for id in descriptors.keys {
            try? await start(id: id)
        }
    }

    public func start(id: ExtensionID) async throws {
        guard let descriptor = descriptors[id] else {
            throw ExtensionHostError.notFound(id.rawValue)
        }
        if let existing = processes[id] {
            let state = await existing.state
            if state == .running { return }
        }

        let factory: (@Sendable () async throws -> any RemoteExtensionTransport)?
        switch descriptor.launch {
        case .testFactory(let factoryID):
            guard let f = testFactories[factoryID] else {
                throw ExtensionHostError.notFound("test factory \(factoryID)")
            }
            factory = f
        case .process, .extensionKit:
            factory = nil
        }

        let process = RemoteExtensionProcess(
            descriptor: descriptor,
            environment: environment,
            policy: policy,
            transportFactory: factory
        )
        await process.setCrashHandler { [weak self] in
            await self?.handleCrash(id: id)
        }
        processes[id] = process
        try await process.start()

        if let registry = services.languageServiceRegistry {
            let reg = await RemoteLanguageServiceProviders.register(
                process: process,
                extensionID: id,
                into: registry,
                selector: .any
            )
            providerRegs[id] = reg
        }
        publishStatuses()
    }

    public func stop(id: ExtensionID) async {
        providerRegs[id]?.dispose()
        providerRegs[id] = nil
        if let process = processes[id] {
            await process.shutdown()
        }
        processes[id] = nil
        publishStatuses()
    }

    public func restart(id: ExtensionID) async throws {
        providerRegs[id]?.dispose()
        providerRegs[id] = nil
        if let process = processes[id] {
            try await process.restart()
            if let registry = services.languageServiceRegistry {
                let reg = await RemoteLanguageServiceProviders.register(
                    process: process,
                    extensionID: id,
                    into: registry
                )
                providerRegs[id] = reg
            }
        } else {
            try await start(id: id)
        }
        restartCounts[id, default: 0] += 1
        publishStatuses()
    }

    public func statuses() async -> [RemoteExtensionStatus] {
        var rows: [RemoteExtensionStatus] = []
        for (id, descriptor) in descriptors {
            if let process = processes[id] {
                rows.append(
                    RemoteExtensionStatus(
                        id: id,
                        displayName: descriptor.displayName,
                        processState: await process.state,
                        health: await process.health,
                        lastError: await process.lastError,
                        grantedPermissions: await process.grantedPermissions
                    )
                )
            } else {
                rows.append(
                    RemoteExtensionStatus(
                        id: id,
                        displayName: descriptor.displayName,
                        processState: .idle
                    )
                )
            }
        }
        return rows.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: - Private

    private func handleCrash(id: ExtensionID) async {
        providerRegs[id]?.dispose()
        providerRegs[id] = nil
        if policy.autoRestart {
            let count = restartCounts[id, default: 0]
            if count < policy.maxRestarts {
                restartCounts[id] = count + 1
                try? await start(id: id)
            }
        }
        publishStatuses()
    }

    private func publishStatuses() {
        Task {
            let rows = await statuses()
            statusContinuation?.yield(rows)
        }
    }
}
