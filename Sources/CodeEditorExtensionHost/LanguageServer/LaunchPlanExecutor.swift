import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensionAPI
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import CodeEditorLSP

public enum LaunchPlanError: Error, Sendable, Equatable {
    case diagnostic(LanguageServerDiagnostic)
    case underlying(String)
}

/// Validates and materializes ``LanguageServerLaunchPlan`` via the capability broker, then starts LSP.
public actor LanguageServerLaunchPlanExecutor {
    public let broker: CapabilityBroker
    public let pool: LanguageServerPool
    public let statusStore: LanguageServerStatusStore
    public let labelHooks: LanguageServerLabelHookRegistry
    public let platformProfile: PlatformCapabilityProfile

    private var registrations: [String: LSPProviderRegistration] = [:]
    private var configurationSources: [String: LanguageServerConfigurationSource] = [:]
    private var activePlans: [String: StoredPlan] = [:]

    private struct StoredPlan: Sendable {
        var plan: LanguageServerLaunchPlan
        var extensionID: ExtensionID
        var workspaceRoots: [URL]
    }

    public init(
        broker: CapabilityBroker,
        pool: LanguageServerPool = LanguageServerPool(),
        statusStore: LanguageServerStatusStore = LanguageServerStatusStore(),
        labelHooks: LanguageServerLabelHookRegistry = LanguageServerLabelHookRegistry(),
        platformProfile: PlatformCapabilityProfile = .default()
    ) {
        self.broker = broker
        self.pool = pool
        self.statusStore = statusStore
        self.labelHooks = labelHooks
        self.platformProfile = platformProfile
    }

    public func registerConfigurationSource(serverID: String, source: LanguageServerConfigurationSource) {
        configurationSources[serverID] = source
    }

    /// Resolve static TOML contribution or provider plan, materialize, start, register adapters.
    @discardableResult
    public func start(
        plan: LanguageServerLaunchPlan,
        extensionID: ExtensionID,
        registry: LanguageServiceRegistry,
        workspaceRoots: [URL] = [],
        provider: (any LanguageServerProvider)? = nil
    ) async throws -> LanguageServerSession {
        let sid = plan.serverID
        await statusStore.set(LanguageServerStatus(
            serverID: sid,
            extensionID: extensionID,
            state: .resolving,
            message: "resolving launch plan"
        ))

        do {
            try await validate(plan: plan, extensionID: extensionID)
            await statusStore.set(LanguageServerStatus(
                serverID: sid,
                extensionID: extensionID,
                state: .installing,
                message: "materializing binary",
                progress: 0.3
            ))
            let material = try await materialize(plan: plan, extensionID: extensionID, workspaceRoots: workspaceRoots)

            var initOpts = plan.initializationOptionsJSON
            if initOpts == nil, let provider {
                let ctx = LanguageServerResolveContext(
                    extensionID: extensionID,
                    workspaceRootPaths: workspaceRoots.map(\.path)
                )
                initOpts = try await provider.initializationOptions(serverID: sid, context: ctx)
            }

            let definition = LanguageServerDefinition(
                id: LanguageServerID(rawValue: sid),
                displayName: plan.displayName,
                languages: Set(plan.languages),
                documentSelector: plan.languages.isEmpty
                    ? .any
                    : DocumentSelector(languageIDs: Set(plan.languages)),
                launch: material.launch,
                workspaceRootURIs: workspaceRoots.map { DocumentURI(fileURL: $0) },
                environment: plan.environment,
                currentDirectory: material.workingDirectory,
                initializationOptions: initOpts.flatMap { data -> LSPJSONObject? in
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }
                    return LSPJSONObject(obj)
                }
            )

            await statusStore.set(LanguageServerStatus(
                serverID: sid,
                extensionID: extensionID,
                state: .starting,
                message: "starting language server",
                progress: 0.6,
                binaryPath: material.resolvedCommand
            ))

            let session = try await pool.server(for: definition)

            // Wire configuration
            if let provider {
                await session.setConfigurationHandler { [provider] (items: [[String: Any]]) async -> [Any] in
                    let mapped = items.map {
                        WorkspaceConfigurationItem(
                            section: $0["section"] as? String,
                            scopeURI: $0["scopeUri"] as? String ?? $0["scopeURI"] as? String
                        )
                    }
                    let results = (try? await provider.workspaceConfiguration(serverID: sid, items: mapped)) ?? []
                    return results.map { data -> Any in
                        if let data,
                           let obj = try? JSONSerialization.jsonObject(with: data)
                        {
                            return obj
                        }
                        return NSNull()
                    }
                }
            } else if let source = configurationSources[sid] {
                await session.setConfigurationHandler { (items: [[String: Any]]) async -> [Any] in
                    await source.configuration(items: items)
                }
            }

            // Label hooks
            if let provider {
                await labelHooks.registerCompletion(serverID: sid) { item in
                    await provider.transformCompletionLabel(item)
                }
                await labelHooks.registerSymbol(serverID: sid) { item in
                    await provider.transformSymbolLabel(item)
                }
            }

            let hooks = labelHooks
            let reg = await LSPClientProviders.register(
                session: session,
                into: registry,
                completionLabelHook: { item in
                    await hooks.transformCompletion(serverID: sid, item: item)
                },
                symbolLabelHook: { name, detail, container in
                    await hooks.transformSymbol(serverID: sid, name: name, detail: detail, container: container)
                }
            )
            registrations[sid] = reg
            activePlans[sid] = StoredPlan(
                plan: plan,
                extensionID: extensionID,
                workspaceRoots: workspaceRoots
            )

            await statusStore.set(LanguageServerStatus(
                serverID: sid,
                extensionID: extensionID,
                state: .running,
                message: "running",
                progress: 1.0,
                binaryPath: material.resolvedCommand
            ))
            return session
        } catch let LaunchPlanError.diagnostic(d) {
            await statusStore.recordDiagnostic(d)
            await statusStore.set(LanguageServerStatus(
                serverID: sid,
                extensionID: extensionID,
                state: .failed,
                lastError: d.message
            ))
            throw LaunchPlanError.diagnostic(d)
        } catch {
            let msg = String(describing: error)
            await statusStore.set(LanguageServerStatus(
                serverID: sid,
                extensionID: extensionID,
                state: .failed,
                lastError: msg
            ))
            await statusStore.recordDiagnostic(LanguageServerDiagnostic(
                code: .spawnFailed,
                message: msg,
                serverID: sid,
                extensionID: extensionID
            ))
            throw error
        }
    }

    public func stop(serverID: String, extensionID: ExtensionID) async {
        registrations[serverID]?.dispose()
        registrations[serverID] = nil
        activePlans[serverID] = nil
        await labelHooks.unregister(serverID: serverID)
        if let session = await pool.sessionMatching(id: LanguageServerID(rawValue: serverID)) {
            await session.shutdown()
        }
        await statusStore.set(LanguageServerStatus(
            serverID: serverID,
            extensionID: extensionID,
            state: .stopped,
            message: "stopped"
        ))
    }

    public func restart(serverID: String) async throws {
        try await pool.restart(id: LanguageServerID(rawValue: serverID))
    }

    /// Restart using the stored plan (pool session recreate).
    public func restartStored(serverID: String, registry: LanguageServiceRegistry) async throws -> LanguageServerSession? {
        guard let stored = activePlans[serverID] else {
            try await pool.restart(id: LanguageServerID(rawValue: serverID))
            return await pool.sessionMatching(id: LanguageServerID(rawValue: serverID))
        }
        await stop(serverID: serverID, extensionID: stored.extensionID)
        return try await start(
            plan: stored.plan,
            extensionID: stored.extensionID,
            registry: registry,
            workspaceRoots: stored.workspaceRoots
        )
    }

    // MARK: - Validate / materialize

    private func validate(plan: LanguageServerLaunchPlan, extensionID: ExtensionID) async throws {
        if plan.serverID.isEmpty || plan.command.isEmpty {
            throw LaunchPlanError.diagnostic(.init(
                code: .planInvalid,
                message: "serverID and command required",
                serverID: plan.serverID,
                extensionID: extensionID
            ))
        }
        // Phase 15: profile-driven gate (not OS compile flags alone).
        let coordinator = RemoteToolingCoordinator(platformProfile: platformProfile)
        switch coordinator.languageServerLaunchDecision() {
        case .allowLocal:
            break
        case .useRemoteFallback(let reason):
            throw LaunchPlanError.diagnostic(.init(
                code: .platformDenied,
                message: "use remote tooling fallback: \(reason)",
                serverID: plan.serverID,
                extensionID: extensionID
            ))
        case .deny(let reason):
            throw LaunchPlanError.diagnostic(.init(
                code: .platformDenied,
                message: reason,
                serverID: plan.serverID,
                extensionID: extensionID
            ))
        }
        if !ExtensionPlatformInfo.current.processLaunchAllowed {
            throw LaunchPlanError.diagnostic(.init(
                code: .platformDenied,
                message: "process launch not allowed on this platform profile",
                serverID: plan.serverID,
                extensionID: extensionID
            ))
        }
        switch plan.binarySource {
        case .absolute(let path):
            if path.contains("..") {
                throw LaunchPlanError.diagnostic(.init(
                    code: .pathEscape,
                    message: "absolute path escape",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
        case .worktreeRelative(let path):
            if path.contains("..") {
                throw LaunchPlanError.diagnostic(.init(
                    code: .pathEscape,
                    message: "worktree path escape",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
        default:
            break
        }
    }

    private struct Materialized {
        var launch: LanguageServerLaunch
        var resolvedCommand: String
        var workingDirectory: URL?
    }

    private func materialize(
        plan: LanguageServerLaunchPlan,
        extensionID: ExtensionID,
        workspaceRoots: [URL]
    ) async throws -> Materialized {
        let cwd: URL?
        if let rel = plan.workingDirectoryRelative, let root = workspaceRoots.first {
            cwd = root.appendingPathComponent(rel)
        } else {
            cwd = workspaceRoots.first
        }

        switch plan.binarySource {
        case .testFactory(let id):
            return Materialized(
                launch: .test(factoryID: id),
                resolvedCommand: "test://\(id)",
                workingDirectory: cwd
            )

        case .systemPath(let name):
            let path = try findOnPath(name) ?? {
                throw LaunchPlanError.diagnostic(.init(
                    code: .binaryNotFound,
                    message: "executable not found on PATH: \(name)",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }()
            try await ensureProcessAllowed(executable: path, extensionID: extensionID, serverID: plan.serverID)
            return Materialized(
                launch: .process(executable: URL(fileURLWithPath: path), arguments: plan.arguments),
                resolvedCommand: path,
                workingDirectory: cwd
            )

        case .absolute(let path):
            guard FileManager.default.isExecutableFile(atPath: path) || FileManager.default.fileExists(atPath: path) else {
                throw LaunchPlanError.diagnostic(.init(
                    code: .binaryNotFound,
                    message: "absolute binary missing: \(path)",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
            try await ensureProcessAllowed(executable: path, extensionID: extensionID, serverID: plan.serverID)
            return Materialized(
                launch: .process(executable: URL(fileURLWithPath: path), arguments: plan.arguments),
                resolvedCommand: path,
                workingDirectory: cwd
            )

        case .worktreeRelative(let rel):
            guard let root = workspaceRoots.first else {
                throw LaunchPlanError.diagnostic(.init(
                    code: .binaryNotFound,
                    message: "no worktree root for relative binary",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
            let url = root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LaunchPlanError.diagnostic(.init(
                    code: .binaryNotFound,
                    message: "worktree binary missing: \(rel)",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
            try await ensureProcessAllowed(executable: url.path, extensionID: extensionID, serverID: plan.serverID)
            return Materialized(
                launch: .process(executable: url, arguments: plan.arguments),
                resolvedCommand: url.path,
                workingDirectory: cwd
            )

        case .downloaded(let urlString, let digest, let cacheKey):
            do {
                let handle = try await broker.downloadHandle(extensionID: extensionID)
                // Prefer fixture path for tests when URL is file: or fixture scheme
                let dest: URL
                if urlString.hasPrefix("fixture://"),
                   let b64 = urlString.split(separator: "/").last.flatMap({ Data(base64Encoded: String($0)) })
                {
                    dest = try await broker.downloadWriteFixture(
                        handle: handle.id,
                        host: "cdn.example",
                        path: "/\(cacheKey)",
                        data: b64,
                        expectedDigest: digest
                    )
                } else if urlString.hasPrefix("file://"), let fileURL = URL(string: urlString) {
                    let data = try Data(contentsOf: fileURL)
                    dest = try await broker.downloadWriteFixture(
                        handle: handle.id,
                        host: "cdn.example",
                        path: "/\(cacheKey)",
                        data: data,
                        expectedDigest: digest
                    )
                } else {
                    dest = try await broker.downloadFetch(
                        handle: handle.id,
                        urlString: urlString,
                        expectedDigest: digest
                    )
                }
                // Treat dest as directory or file; if directory look for plan.command
                var exec = dest
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
                    exec = dest.appendingPathComponent(plan.command)
                }
                try await ensureProcessAllowed(executable: exec.path, extensionID: extensionID, serverID: plan.serverID)
                return Materialized(
                    launch: .process(executable: exec, arguments: plan.arguments),
                    resolvedCommand: exec.path,
                    workingDirectory: cwd
                )
            } catch BrokerError.downloadDenied {
                throw LaunchPlanError.diagnostic(.init(
                    code: .downloadDenied,
                    message: "download denied for \(urlString)",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }

        case .npm(let package, let version, let bin):
            do {
                let handle = try await broker.npmHandle(extensionID: extensionID)
                let dest = try await broker.npmInstall(handle: handle.id, package: package, version: version)
                let exec = dest.appendingPathComponent(bin)
                // Do not invent binaries — npm materialize must produce the declared bin.
                guard FileManager.default.fileExists(atPath: exec.path) else {
                    throw LaunchPlanError.diagnostic(.init(
                        code: .binaryNotFound,
                        message: "npm bin missing after install: \(bin)",
                        serverID: plan.serverID,
                        extensionID: extensionID
                    ))
                }
                try await ensureProcessAllowed(executable: exec.path, extensionID: extensionID, serverID: plan.serverID)
                return Materialized(
                    launch: .process(executable: exec, arguments: plan.arguments),
                    resolvedCommand: exec.path,
                    workingDirectory: cwd
                )
            } catch BrokerError.npmDenied {
                throw LaunchPlanError.diagnostic(.init(
                    code: .npmDenied,
                    message: "npm denied for \(package)",
                    serverID: plan.serverID,
                    extensionID: extensionID
                ))
            }
        }
    }

    private func ensureProcessAllowed(executable: String, extensionID: ExtensionID, serverID: String) async throws {
        do {
            _ = try await broker.processHandle(extensionID: extensionID)
        } catch {
            throw LaunchPlanError.diagnostic(.init(
                code: .processDenied,
                message: "process capability not granted for \(serverID)",
                serverID: serverID,
                extensionID: extensionID
            ))
        }
        let allowed = await broker.processAllowed(executable: executable)
        if !allowed {
            throw LaunchPlanError.diagnostic(.init(
                code: .processDenied,
                message: "executable not on process allowlist: \(executable)",
                serverID: serverID,
                extensionID: extensionID
            ))
        }
    }

    private func findOnPath(_ name: String) throws -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Configuration source

public protocol LanguageServerConfigurationSource: Sendable {
    func configuration(items: [[String: Any]]) async -> [Any]
}

// MARK: - Session configuration helper

extension LanguageServerSession {
    public func setConfigurationHandler(
        _ handler: @escaping @Sendable ([[String: Any]]) async -> [Any]
    ) {
        configurationHandler = handler
    }
}
