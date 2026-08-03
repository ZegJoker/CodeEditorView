import CodeEditorCore
import CodeEditorDAP
import CodeEditorExtensionAPI
import CodeEditorTasks
import Foundation

public enum DebugLaunchPlanError: Error, Sendable, Equatable {
    case diagnostic(DebugAdapterDiagnostic)
    case underlying(String)
}

public actor DebugAdapterStatusStore {
    private var statuses: [String: DebugAdapterStatus] = [:]
    private var diagnostics: [DebugAdapterDiagnostic] = []

    public init() {}

    public func set(_ status: DebugAdapterStatus) {
        statuses[status.id] = status
    }

    public func status(adapterID: String, extensionID: ExtensionID) -> DebugAdapterStatus? {
        statuses["\(extensionID.rawValue)::\(adapterID)"]
    }

    public func recordDiagnostic(_ d: DebugAdapterDiagnostic) {
        diagnostics.append(d)
    }

    public func allDiagnostics() -> [DebugAdapterDiagnostic] { diagnostics }
}

/// Materializes debug adapter launch plans and starts DAP sessions.
public actor DebugAdapterLaunchPlanExecutor {
    public let broker: CapabilityBroker
    public let pool: DebugAdapterPool
    public let statusStore: DebugAdapterStatusStore
    public var taskService: TaskService?

    public init(
        broker: CapabilityBroker,
        pool: DebugAdapterPool = DebugAdapterPool(),
        statusStore: DebugAdapterStatusStore = DebugAdapterStatusStore(),
        taskService: TaskService? = nil
    ) {
        self.broker = broker
        self.pool = pool
        self.statusStore = statusStore
        self.taskService = taskService
    }

    @discardableResult
    public func start(
        plan: DebugAdapterLaunchPlan,
        extensionID: ExtensionID,
        workspaceRoots: [URL] = [],
        runInTerminal: (any DAPRunInTerminalHandler)? = nil
    ) async throws -> DebugAdapterSession {
        let aid = plan.adapterID
        await statusStore.set(
            DebugAdapterStatus(
                adapterID: aid,
                extensionID: extensionID,
                state: .resolving,
                message: "resolving"
            ))
        do {
            try validate(plan: plan, extensionID: extensionID)
            await statusStore.set(
                DebugAdapterStatus(
                    adapterID: aid,
                    extensionID: extensionID,
                    state: .installing,
                    message: "materializing"
                ))
            let material = try await materialize(plan: plan, extensionID: extensionID, workspaceRoots: workspaceRoots)

            if let pre = plan.preDebugTaskID, let tasks = taskService {
                _ = try? await tasks.start(id: TaskID(rawValue: pre))
            }

            let definition = DebugAdapterDefinition(
                id: DebugAdapterID(rawValue: aid),
                displayName: plan.displayName,
                languages: Set(plan.languages),
                launch: material.launch,
                environment: plan.environment,
                currentDirectory: material.workingDirectory,
                preDebugTaskID: plan.preDebugTaskID,
                postDebugTaskID: plan.postDebugTaskID
            )
            await statusStore.set(
                DebugAdapterStatus(
                    adapterID: aid,
                    extensionID: extensionID,
                    state: .starting,
                    message: "starting",
                    binaryPath: material.resolvedCommand
                ))
            let session = try await pool.adapter(for: definition)
            if let runInTerminal {
                await session.setRunInTerminalHandler(runInTerminal)
            }
            await statusStore.set(
                DebugAdapterStatus(
                    adapterID: aid,
                    extensionID: extensionID,
                    state: .running,
                    message: "running",
                    binaryPath: material.resolvedCommand
                ))
            return session
        } catch let DebugLaunchPlanError.diagnostic(d) {
            await statusStore.recordDiagnostic(d)
            await statusStore.set(
                DebugAdapterStatus(
                    adapterID: aid,
                    extensionID: extensionID,
                    state: .failed,
                    lastError: d.message
                ))
            throw DebugLaunchPlanError.diagnostic(d)
        } catch {
            let msg = String(describing: error)
            await statusStore.set(
                DebugAdapterStatus(
                    adapterID: aid,
                    extensionID: extensionID,
                    state: .failed,
                    lastError: msg
                ))
            throw error
        }
    }

    public func stop(adapterID: String, extensionID: ExtensionID) async {
        await pool.remove(id: DebugAdapterID(rawValue: adapterID))
        await statusStore.set(
            DebugAdapterStatus(
                adapterID: adapterID,
                extensionID: extensionID,
                state: .stopped,
                message: "stopped"
            ))
    }

    public func restart(adapterID: String, extensionID: ExtensionID, configuration: DAPJSONObject? = nil) async throws {
        try await pool.restart(id: DebugAdapterID(rawValue: adapterID), configuration: configuration)
        await statusStore.set(
            DebugAdapterStatus(
                adapterID: adapterID,
                extensionID: extensionID,
                state: .running,
                message: "restarted"
            ))
    }

    private func validate(plan: DebugAdapterLaunchPlan, extensionID: ExtensionID) throws {
        if plan.adapterID.isEmpty || plan.command.isEmpty {
            throw DebugLaunchPlanError.diagnostic(
                .init(
                    code: .planInvalid,
                    message: "adapterID and command required",
                    adapterID: plan.adapterID,
                    extensionID: extensionID
                ))
        }
        switch plan.binarySource {
        case .worktreeRelative(let path), .absolute(let path):
            if path.contains("..") {
                throw DebugLaunchPlanError.diagnostic(
                    .init(
                        code: .pathEscape,
                        message: "path escape",
                        adapterID: plan.adapterID,
                        extensionID: extensionID
                    ))
            }
        default:
            break
        }
    }

    private struct Materialized {
        var launch: DebugAdapterLaunch
        var resolvedCommand: String
        var workingDirectory: URL?
    }

    private func materialize(
        plan: DebugAdapterLaunchPlan,
        extensionID: ExtensionID,
        workspaceRoots: [URL]
    ) async throws -> Materialized {
        let cwd =
            plan.workingDirectoryRelative.flatMap { rel in
                workspaceRoots.first?.appendingPathComponent(rel)
            } ?? workspaceRoots.first

        switch plan.binarySource {
        case .testFactory(let id):
            return Materialized(launch: .test(factoryID: id), resolvedCommand: "test://\(id)", workingDirectory: cwd)
        case .systemPath(let name):
            guard let path = findOnPath(name) else {
                throw DebugLaunchPlanError.diagnostic(
                    .init(
                        code: .binaryNotFound,
                        message: "not on PATH: \(name)",
                        adapterID: plan.adapterID,
                        extensionID: extensionID
                    ))
            }
            try await ensureProcess(path, extensionID: extensionID, adapterID: plan.adapterID)
            return Materialized(
                launch: .process(executable: URL(fileURLWithPath: path), arguments: plan.arguments),
                resolvedCommand: path,
                workingDirectory: cwd
            )
        case .absolute(let path):
            try await ensureProcess(path, extensionID: extensionID, adapterID: plan.adapterID)
            return Materialized(
                launch: .process(executable: URL(fileURLWithPath: path), arguments: plan.arguments),
                resolvedCommand: path,
                workingDirectory: cwd
            )
        case .worktreeRelative(let rel):
            guard let root = workspaceRoots.first else {
                throw DebugLaunchPlanError.diagnostic(
                    .init(
                        code: .binaryNotFound,
                        message: "no worktree",
                        adapterID: plan.adapterID,
                        extensionID: extensionID
                    ))
            }
            let url = root.appendingPathComponent(rel)
            try await ensureProcess(url.path, extensionID: extensionID, adapterID: plan.adapterID)
            return Materialized(
                launch: .process(executable: url, arguments: plan.arguments),
                resolvedCommand: url.path,
                workingDirectory: cwd
            )
        case .downloaded(let urlString, let digest, let cacheKey):
            do {
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
                try await ensureProcess(dest.path, extensionID: extensionID, adapterID: plan.adapterID)
                return Materialized(
                    launch: .process(executable: dest, arguments: plan.arguments),
                    resolvedCommand: dest.path,
                    workingDirectory: cwd
                )
            } catch {
                throw DebugLaunchPlanError.diagnostic(
                    .init(
                        code: .downloadDenied,
                        message: String(describing: error),
                        adapterID: plan.adapterID,
                        extensionID: extensionID
                    ))
            }
        case .npm(let package, let version, let bin):
            let handle = try await broker.npmHandle(extensionID: extensionID)
            let dest = try await broker.npmInstall(
                caller: extensionID, handle: handle.id, package: package, version: version
            )
            let exec = dest.appendingPathComponent(bin)
            // Do not invent binaries — package install must provide the declared bin.
            guard FileManager.default.fileExists(atPath: exec.path) else {
                throw DebugLaunchPlanError.diagnostic(
                    .init(
                        code: .binaryNotFound,
                        message: "npm bin missing after install: \(bin)",
                        adapterID: plan.adapterID,
                        extensionID: extensionID
                    ))
            }
            try await ensureProcess(exec.path, extensionID: extensionID, adapterID: plan.adapterID)
            return Materialized(
                launch: .process(executable: exec, arguments: plan.arguments),
                resolvedCommand: exec.path,
                workingDirectory: cwd
            )
        }
    }

    private func ensureProcess(_ executable: String, extensionID: ExtensionID, adapterID: String) async throws {
        do {
            _ = try await broker.processHandle(extensionID: extensionID)
        } catch {
            throw DebugLaunchPlanError.diagnostic(
                .init(
                    code: .processDenied,
                    message: "process capability denied",
                    adapterID: adapterID,
                    extensionID: extensionID
                ))
        }
        let allowed = await broker.processAllowed(executable: executable)
        if !allowed {
            throw DebugLaunchPlanError.diagnostic(
                .init(
                    code: .processDenied,
                    message: "not on allowlist: \(executable)",
                    adapterID: adapterID,
                    extensionID: extensionID
                ))
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
