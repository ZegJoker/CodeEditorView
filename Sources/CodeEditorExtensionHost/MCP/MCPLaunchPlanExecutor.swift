import CodeEditorCore
import CodeEditorExtensionAPI
import Foundation

public enum MCPLaunchPlanError: Error, Sendable, Equatable {
    case diagnostic(String)
    case processDenied
    case binaryNotFound(String)
    case pathEscape
    case planInvalid
}

/// Materializes MCP launch plans and starts host-owned MCP sessions.
public actor MCPLaunchPlanExecutor {
    public let broker: CapabilityBroker
    public let pool: MCPServerPool
    private var statuses: [String: MCPServerStatus] = [:]

    public init(broker: CapabilityBroker, pool: MCPServerPool = MCPServerPool()) {
        self.broker = broker
        self.pool = pool
    }

    public func status(serverID: String, extensionID: ExtensionID) -> MCPServerStatus? {
        statuses["\(extensionID.rawValue)::\(serverID)"]
    }

    public func setStatus(_ status: MCPServerStatus) {
        statuses[status.id] = status
    }

    @discardableResult
    public func start(
        plan: MCPServerLaunchPlan,
        extensionID: ExtensionID,
        workspaceRoots: [URL] = []
    ) async throws -> MCPClientSession {
        let sid = plan.serverID
        setStatus(MCPServerStatus(serverID: sid, extensionID: extensionID, state: .resolving, message: "resolving"))
        do {
            if plan.serverID.isEmpty || plan.command.isEmpty {
                throw MCPLaunchPlanError.planInvalid
            }
            switch plan.binarySource {
            case .worktreeRelative(let path), .absolute(let path):
                if path.contains("..") { throw MCPLaunchPlanError.pathEscape }
            default: break
            }

            setStatus(
                MCPServerStatus(serverID: sid, extensionID: extensionID, state: .starting, message: "materializing"))
            let material = try await materialize(plan: plan, extensionID: extensionID, workspaceRoots: workspaceRoots)

            // Register process factory when not test factory
            if case .test(let factoryID) = material.kind {
                // factory must already be registered on pool
                _ = factoryID
            } else if case .process(let exe, let args, let cwd, let env) = material.kind {
                let factoryID = "proc-\(sid)-\(UUID().uuidString)"
                await pool.registerTestFactory(id: factoryID) {
                    try MCPProcessTransport(
                        executable: exe,
                        arguments: args,
                        environment: env,
                        currentDirectory: cwd
                    )
                }
                var launched = plan
                // Use a rewritten plan with test factory pointing at process transport
                launched = MCPServerLaunchPlan(
                    serverID: plan.serverID,
                    displayName: plan.displayName,
                    command: plan.command,
                    arguments: plan.arguments,
                    environment: plan.environment,
                    secretEnvironment: plan.secretEnvironment,
                    workingDirectoryRelative: plan.workingDirectoryRelative,
                    transport: plan.transport,
                    binarySource: .testFactory(id: factoryID),
                    startupTimeoutMS: plan.startupTimeoutMS,
                    extensionID: extensionID
                )
                let session = try await pool.start(plan: launched)
                setStatus(MCPServerStatus(serverID: sid, extensionID: extensionID, state: .running, message: "running"))
                return session
            }

            var planWithExt = plan
            if plan.extensionID == nil {
                planWithExt = MCPServerLaunchPlan(
                    serverID: plan.serverID,
                    displayName: plan.displayName,
                    command: plan.command,
                    arguments: plan.arguments,
                    environment: plan.environment,
                    secretEnvironment: plan.secretEnvironment,
                    workingDirectoryRelative: plan.workingDirectoryRelative,
                    transport: plan.transport,
                    binarySource: plan.binarySource,
                    startupTimeoutMS: plan.startupTimeoutMS,
                    extensionID: extensionID
                )
            }
            let session = try await pool.start(plan: planWithExt)
            setStatus(MCPServerStatus(serverID: sid, extensionID: extensionID, state: .running, message: "running"))
            return session
        } catch {
            setStatus(
                MCPServerStatus(
                    serverID: sid,
                    extensionID: extensionID,
                    state: .failed,
                    lastError: String(describing: error)
                ))
            throw error
        }
    }

    public func stop(serverID: String, extensionID: ExtensionID) async {
        await pool.stop(serverID: serverID)
        setStatus(MCPServerStatus(serverID: serverID, extensionID: extensionID, state: .stopped, message: "stopped"))
    }

    public func restart(
        serverID: String, extensionID: ExtensionID, workspaceRoots: [URL] = []
    ) async throws -> MCPClientSession {
        guard let existing = await pool.session(serverID: serverID) else {
            throw MCPLaunchPlanError.diagnostic("no session \(serverID)")
        }
        let plan = await existing.plan
        await stop(serverID: serverID, extensionID: extensionID)
        return try await start(plan: plan, extensionID: extensionID, workspaceRoots: workspaceRoots)
    }

    private enum MaterialKind {
        case test(String)
        case process(URL, [String], URL?, [String: String])
    }

    private struct Materialized {
        var kind: MaterialKind
    }

    private func materialize(
        plan: MCPServerLaunchPlan,
        extensionID: ExtensionID,
        workspaceRoots: [URL]
    ) async throws -> Materialized {
        let cwd =
            plan.workingDirectoryRelative.flatMap { workspaceRoots.first?.appendingPathComponent($0) }
            ?? workspaceRoots.first
        var env = plan.environment
        // Resolve secret references from settings (named secrets only — no Keychain dump)
        if !plan.secretEnvironment.isEmpty {
            if let sh = try? await broker.settingsHandle(extensionID: extensionID) {
                for (key, secret) in plan.secretEnvironment {
                    if let value = try? await broker.settingsGet(
                        caller: extensionID, handle: sh.id, key: "secret.\(secret.name)"
                    ) {
                        env[key] = value
                    }
                }
            }
        }

        switch plan.binarySource {
        case .testFactory(let id):
            return Materialized(kind: .test(id))
        case .systemPath(let name):
            guard let path = findOnPath(name) else { throw MCPLaunchPlanError.binaryNotFound(name) }
            try await ensureProcess(path, extensionID: extensionID)
            return Materialized(kind: .process(URL(fileURLWithPath: path), plan.arguments, cwd, env))
        case .absolute(let path):
            try await ensureProcess(path, extensionID: extensionID)
            return Materialized(kind: .process(URL(fileURLWithPath: path), plan.arguments, cwd, env))
        case .worktreeRelative(let rel):
            guard let root = workspaceRoots.first else { throw MCPLaunchPlanError.binaryNotFound(rel) }
            let url = root.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MCPLaunchPlanError.binaryNotFound(rel)
            }
            try await ensureProcess(url.path, extensionID: extensionID)
            return Materialized(kind: .process(url, plan.arguments, cwd, env))
        case .downloaded(let urlString, let digest, let cacheKey):
            let handle = try await broker.downloadHandle(extensionID: extensionID)
            let dest: URL
            if urlString.hasPrefix("fixture://"),
                let b64 = urlString.split(separator: "/").last.flatMap({ Data(base64Encoded: String($0)) })
            {
                dest = try await broker.downloadWriteFixture(
                    caller: extensionID,
                    handle: handle.id,
                    host: "cdn.example",
                    path: "/\(cacheKey)",
                    data: b64,
                    expectedDigest: digest
                )
            } else {
                dest = try await broker.downloadFetch(
                    caller: extensionID,
                    handle: handle.id,
                    urlString: urlString,
                    expectedDigest: digest
                )
            }
            try await ensureProcess(dest.path, extensionID: extensionID)
            return Materialized(kind: .process(dest, plan.arguments, cwd, env))
        case .npm(let package, let version, let bin):
            let handle = try await broker.npmHandle(extensionID: extensionID)
            let dest = try await broker.npmInstall(
                caller: extensionID, handle: handle.id, package: package, version: version
            )
            let exec = dest.appendingPathComponent(bin)
            // Do not invent executables: require the package to provide the bin.
            guard FileManager.default.fileExists(atPath: exec.path) else {
                throw MCPLaunchPlanError.binaryNotFound(bin)
            }
            try await ensureProcess(exec.path, extensionID: extensionID)
            return Materialized(kind: .process(exec, plan.arguments, cwd, env))
        }
    }

    private func ensureProcess(_ executable: String, extensionID: ExtensionID) async throws {
        do {
            _ = try await broker.processHandle(extensionID: extensionID)
        } catch {
            throw MCPLaunchPlanError.processDenied
        }
        if !(await broker.processAllowed(executable: executable)) {
            throw MCPLaunchPlanError.processDenied
        }
    }

    private func findOnPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let c = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }
}
