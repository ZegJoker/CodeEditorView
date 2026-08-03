import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorWorkspace
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Handles

public struct BrokerHandleID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
}

public struct BrokerHandle: Sendable, Hashable {
    public var id: BrokerHandleID
    public var extensionID: ExtensionID
    public var generation: UInt64
    public var kind: String
    public var operations: Set<String>

    public init(
        id: BrokerHandleID = BrokerHandleID(),
        extensionID: ExtensionID,
        generation: UInt64,
        kind: String,
        operations: Set<String>
    ) {
        self.id = id
        self.extensionID = extensionID
        self.generation = generation
        self.kind = kind
        self.operations = operations
    }
}

public enum BrokerError: Error, Sendable, Equatable {
    case permissionDenied(String)
    case forgedHandle
    case staleGeneration
    case pathEscape
    case notFound(String)
    case quotaExceeded
    case processDenied(String)
    case downloadDenied(String)
    case npmDenied(String)
    case invalidRequest(String)
    case unsupported(String)
    case revokedHandle
    case ioError(String)
    case initializationFailed(String)
    case unregisteredExtension
}

/// Typed project metadata (BROKER-N08) — never join roots with `:`.
public struct BrokerProjectInfo: Sendable, Hashable, Codable {
    public var name: String
    public var roots: [BrokerProjectRoot]

    public init(name: String, roots: [BrokerProjectRoot]) {
        self.name = name
        self.roots = roots
    }
}

public struct BrokerProjectRoot: Sendable, Hashable, Codable {
    public var path: String
    public var uri: String

    public init(path: String, uri: String) {
        self.path = path
        self.uri = uri
    }

    public init(url: URL) {
        let standardized = url.standardizedFileURL
        self.path = standardized.path
        self.uri = standardized.absoluteString
    }
}

/// Process lease returned from spawn (BROKER-N12).
public struct BrokerProcessLease: Sendable, Hashable {
    public var lease: BrokerHandleID
    public var pid: Int32
    public var supervisorLeaseID: UUID

    public init(lease: BrokerHandleID, pid: Int32, supervisorLeaseID: UUID) {
        self.lease = lease
        self.pid = pid
        self.supervisorLeaseID = supervisorLeaseID
    }
}

/// Exact argument vector matcher (BROKER-N11). Not a shell/glob pattern.
public enum ProcessArgumentMatcher: Sendable, Hashable {
    /// Any argument vector is accepted.
    case anyArguments
    /// Argument vector must equal this sequence exactly.
    case exactArguments([String])
}

// MARK: - Broker

/// Fail-closed capability broker for worktree/project/settings/storage/process/download/npm.
public actor CapabilityBroker {
    public struct Config: Sendable {
        public var worktreeRoots: [URL]
        public var projectName: String
        public var storageRoot: URL
        public var toolCacheRoot: URL
        public var storageQuotaBytes: Int
        public var maxDownloadBytes: Int
        /// Max bytes for a single worktree read (EXT-015 / §15.19).
        public var maxWorktreeReadBytes: Int
        public var processAllowlist: [ProcessAllow]
        public var downloadAllowlist: [DownloadAllow]
        public var npmAllowlist: [NPMAllow]
        /// Host-owned npm package materialization root: `{name}/{version}/` trees (EXT-013).
        public var npmRegistryRoot: URL?
        public var platformProfile: PlatformCapabilityProfile
        /// Max key character length for settings/storage (BROKER-N09).
        public var maxKeyLength: Int
        /// Max number of storage keys per extension (BROKER-N09).
        public var maxKeyCount: Int
        /// Max bytes per storage value (BROKER-N09).
        public var maxValueBytes: Int
        /// Max total settings JSON bytes per extension (BROKER-N09).
        public var maxSettingsBytes: Int
        /// Max settings/storage mutations per window (BROKER-N09).
        public var maxMutationsPerWindow: Int
        public var mutationWindow: Duration
        /// Allow non-HTTPS downloads only when true (test profiles). Production defaults false.
        public var allowInsecureHTTP: Bool

        public init(
            worktreeRoots: [URL] = [],
            projectName: String = "project",
            storageRoot: URL,
            toolCacheRoot: URL,
            storageQuotaBytes: Int = 16 * 1024 * 1024,
            maxDownloadBytes: Int = 32 * 1024 * 1024,
            maxWorktreeReadBytes: Int = 4 * 1024 * 1024,
            processAllowlist: [ProcessAllow] = [],
            downloadAllowlist: [DownloadAllow] = [],
            npmAllowlist: [NPMAllow] = [],
            npmRegistryRoot: URL? = nil,
            platformProfile: PlatformCapabilityProfile = .default(),
            maxKeyLength: Int = 256,
            maxKeyCount: Int = 4096,
            maxValueBytes: Int = 1024 * 1024,
            maxSettingsBytes: Int = 256 * 1024,
            maxMutationsPerWindow: Int = 10_000,
            mutationWindow: Duration = .seconds(60),
            allowInsecureHTTP: Bool = false
        ) {
            self.worktreeRoots = worktreeRoots
            self.projectName = projectName
            self.storageRoot = storageRoot
            self.toolCacheRoot = toolCacheRoot
            self.storageQuotaBytes = storageQuotaBytes
            self.maxDownloadBytes = maxDownloadBytes
            self.maxWorktreeReadBytes = maxWorktreeReadBytes
            self.processAllowlist = processAllowlist
            self.downloadAllowlist = downloadAllowlist
            self.npmAllowlist = npmAllowlist
            self.npmRegistryRoot = npmRegistryRoot
            self.platformProfile = platformProfile
            self.maxKeyLength = maxKeyLength
            self.maxKeyCount = maxKeyCount
            self.maxValueBytes = maxValueBytes
            self.maxSettingsBytes = maxSettingsBytes
            self.maxMutationsPerWindow = maxMutationsPerWindow
            self.mutationWindow = mutationWindow
            self.allowInsecureHTTP = allowInsecureHTTP
        }
    }

    public struct ProcessAllow: Sendable, Hashable {
        public var command: String
        /// Exact or any argument vector (BROKER-N11). Not a glob.
        public var argumentMatcher: ProcessArgumentMatcher

        public init(command: String, argumentMatcher: ProcessArgumentMatcher = .anyArguments) {
            self.command = command
            self.argumentMatcher = argumentMatcher
        }

        /// Convenience: exact argument vector.
        public init(command: String, exactArguments: [String]) {
            self.command = command
            self.argumentMatcher = .exactArguments(exactArguments)
        }
    }

    public struct DownloadAllow: Sendable, Hashable {
        public var host: String
        /// Path component prefix after percent-decoding and normalization (BROKER-N14).
        public var pathPrefix: [String]
        public init(host: String, pathPrefix: [String] = []) {
            self.host = host
            self.pathPrefix = pathPrefix
        }
    }

    public struct NPMAllow: Sendable, Hashable {
        public var package: String
        public var version: String?
        public init(package: String, version: String? = nil) {
            self.package = package
            self.version = version
        }
    }

    private struct StorageLedger: Codable, Sendable {
        var usedBytes: Int
        var keys: [String: Int]
        var settingsBytes: Int

        static let empty = StorageLedger(usedBytes: 0, keys: [:], settingsBytes: 0)
    }

    private var config: Config
    private var handles: [BrokerHandleID: BrokerHandle] = [:]
    private var permissions: [ExtensionID: Set<ExtensionPermission>] = [:]
    private var generations: [ExtensionID: UInt64] = [:]
    /// Durable accounting (BROKER-N10) — not recomputed by scanning on every write.
    private var ledgers: [ExtensionID: StorageLedger] = [:]
    private var liveProcesses: [BrokerHandleID: UUID] = [:]
    private var worktreeRootByHandle: [BrokerHandleID: URL] = [:]
    private let processSupervisor: ProcessSupervisor
    private var mutationTimestamps: [ExtensionID: [ContinuousClock.Instant]] = [:]
    /// Revocation cleanup tasks (BROKER-N16) — not awaited on the critical path.
    private var revocationTasks: [ExtensionID: Task<Void, Never>] = [:]

    /// Initialize broker; fails closed if storage/cache roots cannot be created (BROKER-N04).
    public init(config: Config) throws {
        self.config = config
        self.processSupervisor = ProcessSupervisor(profile: config.platformProfile)
        do {
            try FileManager.default.createDirectory(
                at: config.storageRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: config.toolCacheRoot, withIntermediateDirectories: true)
            // Prove roots are usable directories (not a file / missing parent).
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: config.storageRoot.path, isDirectory: &isDir),
                isDir.boolValue
            else {
                throw BrokerError.initializationFailed("storageRoot is not a directory")
            }
            guard FileManager.default.fileExists(atPath: config.toolCacheRoot.path, isDirectory: &isDir),
                isDir.boolValue
            else {
                throw BrokerError.initializationFailed("toolCacheRoot is not a directory")
            }
        } catch let error as BrokerError {
            throw error
        } catch {
            throw BrokerError.initializationFailed(String(describing: error))
        }
    }

    public func registerExtension(
        id: ExtensionID,
        generation: UInt64,
        granted: Set<ExtensionPermission>
    ) {
        permissions[id] = granted
        generations[id] = generation
        if ledgers[id] == nil {
            ledgers[id] = (try? loadLedger(extensionID: id)) ?? .empty
        }
    }

    /// Immediately strip capabilities and request process cancellation without awaiting death (BROKER-N16).
    public func revokeExtension(id: ExtensionID) {
        permissions[id] = nil
        generations[id] = nil
        let owned = handles.values.filter { $0.extensionID == id }
        var supervisorIDs: [UUID] = []
        for h in owned {
            handles[h.id] = nil
            worktreeRootByHandle[h.id] = nil
            if let sid = liveProcesses.removeValue(forKey: h.id) {
                supervisorIDs.append(sid)
            }
        }
        ledgers[id] = nil
        mutationTimestamps[id] = nil
        // Nonblocking: cancel via supervisor off the critical actor path.
        let supervisor = processSupervisor
        let previous = revocationTasks.removeValue(forKey: id)
        previous?.cancel()
        revocationTasks[id] = Task {
            for sid in supervisorIDs {
                await supervisor.cancel(sid)
            }
        }
    }

    // MARK: - Worktree

    /// Environment variable names extensions may read via worktree handles (fail-closed).
    public static let defaultAllowedEnvironmentNames: Set<String> = [
        "PATH", "HOME", "USER", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        "DEVELOPER_DIR", "SDKROOT", "TOOLCHAIN_DIR", "SWIFT_EXEC",
        "CARGO_HOME", "RUSTUP_HOME", "GOPATH", "GOROOT", "JAVA_HOME", "NODE_PATH",
    ]

    /// Issue a worktree handle bound to a specific root (defaults to first configured root).
    public func worktreeHandle(extensionID: ExtensionID, root: URL? = nil) throws -> BrokerHandle {
        try require(extensionID, .readWorkspace)
        let selected: URL?
        if let root {
            let want = root.resolvingSymlinksInPath().standardizedFileURL
            guard config.worktreeRoots.contains(where: {
                $0.resolvingSymlinksInPath().standardizedFileURL == want
            }) else {
                throw BrokerError.pathEscape
            }
            selected = want
        } else if let first = config.worktreeRoots.first {
            selected = first.resolvingSymlinksInPath().standardizedFileURL
        } else {
            selected = nil
        }
        let handle = try issue(extensionID, kind: "worktree", ops: ["list", "read", "which", "environment"])
        if let selected {
            worktreeRootByHandle[handle.id] = selected
        }
        return handle
    }

    public func worktreeList(
        caller: ExtensionID,
        handle: BrokerHandleID,
        relative: String = ""
    ) throws -> [String] {
        let h = try resolve(handle, caller: caller, kind: "worktree", op: "list")
        return try listWorktreeDescriptor(handle: h.id, relative: relative)
    }

    public func worktreeRead(
        caller: ExtensionID,
        handle: BrokerHandleID,
        relative: String
    ) throws -> Data {
        let h = try resolve(handle, caller: caller, kind: "worktree", op: "read")
        return try readWorktreeDescriptor(handle: h.id, relative: relative)
    }

    /// Find an executable under worktree roots first, then the process PATH (scoped).
    public func worktreeWhich(caller: ExtensionID, handle: BrokerHandleID, name: String) throws -> String? {
        _ = try resolve(handle, caller: caller, kind: "worktree", op: "which")
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/"), !cleaned.contains("..") else {
            throw BrokerError.invalidRequest("executable name")
        }
        for root in config.worktreeRoots {
            for sub in ["bin", "tools", ".bin", "node_modules/.bin"] {
                let candidate = root.appendingPathComponent(sub).appendingPathComponent(cleaned)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
            let direct = root.appendingPathComponent(cleaned)
            if FileManager.default.isExecutableFile(atPath: direct.path) {
                return direct.path
            }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(cleaned).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Read allowed environment variables only (never arbitrary process env dump).
    public func worktreeEnvironment(
        caller: ExtensionID,
        handle: BrokerHandleID,
        names: Set<String>,
        allowed: Set<String> = CapabilityBroker.defaultAllowedEnvironmentNames
    ) throws -> [String: String] {
        _ = try resolve(handle, caller: caller, kind: "worktree", op: "environment")
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [:]
        for name in names {
            guard allowed.contains(name) else { continue }
            if let value = env[name] {
                out[name] = value
            }
        }
        return out
    }

    // MARK: - Project

    public func projectHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .readWorkspace)
        return try issue(extensionID, kind: "project", ops: ["info"])
    }

    public func projectInfo(caller: ExtensionID, handle: BrokerHandleID) throws -> BrokerProjectInfo {
        _ = try resolve(handle, caller: caller, kind: "project", op: "info")
        return BrokerProjectInfo(
            name: config.projectName,
            roots: config.worktreeRoots.map { BrokerProjectRoot(url: $0) }
        )
    }

    // MARK: - Settings (durable under storage root — EXT-011)

    public func settingsHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try requireRegistered(extensionID)
        return try issue(extensionID, kind: "settings", ops: ["get", "set"])
    }

    public func settingsGet(caller: ExtensionID, handle: BrokerHandleID, key: String) throws -> String? {
        let h = try resolve(handle, caller: caller, kind: "settings", op: "get")
        try validateKey(key)
        let map = try loadSettings(extensionID: h.extensionID)
        return map[key]
    }

    public func settingsSet(caller: ExtensionID, handle: BrokerHandleID, key: String, value: String) throws {
        let h = try resolve(handle, caller: caller, kind: "settings", op: "set")
        try validateKey(key)
        try noteMutation(extensionID: h.extensionID)
        var map = try loadSettings(extensionID: h.extensionID)
        map[key] = value
        try saveSettings(extensionID: h.extensionID, map: map)
    }

    // MARK: - Storage

    public func storageHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try requireRegistered(extensionID)
        return try issue(extensionID, kind: "storage", ops: ["get", "set"])
    }

    public func storageGet(caller: ExtensionID, handle: BrokerHandleID, key: String) throws -> Data? {
        let h = try resolve(handle, caller: caller, kind: "storage", op: "get")
        try validateKey(key)
        let url = try storageURL(extensionID: h.extensionID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func storageSet(caller: ExtensionID, handle: BrokerHandleID, key: String, value: Data) throws {
        let h = try resolve(handle, caller: caller, kind: "storage", op: "set")
        try validateKey(key)
        if value.count > config.maxValueBytes {
            throw BrokerError.quotaExceeded
        }
        try noteMutation(extensionID: h.extensionID)
        try reserveAndCommitStorage(extensionID: h.extensionID, key: key, value: value)
    }

    // MARK: - Process

    public func processHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .startProcesses)
        return try issue(extensionID, kind: "process", ops: ["spawn", "kill", "events", "awaitExit"])
    }

    public func processSpawn(
        caller: ExtensionID,
        handle: BrokerHandleID,
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) async throws -> BrokerProcessLease {
        let h = try resolve(handle, caller: caller, kind: "process", op: "spawn")
        let trusted = try resolveTrustedExecutable(executable: executable, arguments: arguments)
        let cwd = currentDirectory.map { URL(fileURLWithPath: $0) }
        if let cwd {
            try validateCWD(cwd)
        }
        // BROKER-N07: revalidate identity immediately before spawn.
        let revalidated = try resolveTrustedExecutable(executable: trusted, arguments: arguments)
        guard revalidated == trusted else {
            throw BrokerError.processDenied(executable)
        }
        let request = ProcessLaunchRequest(
            executable: trusted,
            arguments: arguments,
            mode: .direct,
            currentDirectory: cwd,
            environment: [:],
            mergeEnvironment: false,
            capabilityKind: .localProcess
        )
        let processHandle = try await processSupervisor.spawn(request)
        let lease = try issue(h.extensionID, kind: "processLease", ops: ["kill", "events", "awaitExit"])
        liveProcesses[lease.id] = processHandle.id
        return BrokerProcessLease(
            lease: lease.id,
            pid: processHandle.processIdentifier,
            supervisorLeaseID: processHandle.id
        )
    }

    public func processKill(caller: ExtensionID, handle: BrokerHandleID) async throws {
        let h = try resolve(handle, caller: caller, kind: "processLease", op: "kill")
        if let sid = liveProcesses.removeValue(forKey: h.id) {
            // Nonblocking cancel (BROKER-N16 family).
            await processSupervisor.cancel(sid)
        }
        handles[h.id] = nil
    }

    /// Sequenced stdout/stderr/exit stream via ProcessSupervisor / ProcessHandle (BROKER-N12).
    public func processEvents(
        caller: ExtensionID,
        handle: BrokerHandleID
    ) async throws -> AsyncStream<ProcessOutputEvent> {
        let h = try resolve(handle, caller: caller, kind: "processLease", op: "events")
        guard let sid = liveProcesses[h.id],
            let ph = await processSupervisor.handle(for: sid)
        else {
            throw BrokerError.notFound("process lease")
        }
        return ph.makeEventStream()
    }

    public func processAwaitExit(
        caller: ExtensionID,
        handle: BrokerHandleID
    ) async throws -> ProcessExit {
        let h = try resolve(handle, caller: caller, kind: "processLease", op: "awaitExit")
        guard let sid = liveProcesses[h.id] else {
            throw BrokerError.notFound("process lease")
        }
        return try await processSupervisor.awaitExit(sid)
    }

    // MARK: - Download

    public func downloadHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .network)
        return try issue(extensionID, kind: "download", ops: ["fetch"])
    }

    public func downloadFetch(
        caller: ExtensionID,
        handle: BrokerHandleID,
        urlString: String,
        expectedDigest: String? = nil
    ) async throws -> URL {
        let h = try resolve(handle, caller: caller, kind: "download", op: "fetch")
        guard let url = URL(string: urlString), let host = url.host else {
            throw BrokerError.invalidRequest("bad url")
        }
        try validateDownloadURL(url, host: host)
        let destDir = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let tmp = destDir.appendingPathComponent("dl-\(UUID().uuidString).partial")
        let finalURL = destDir.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tmp)
        }

        let allowInsecure = config.allowInsecureHTTP
        let allowlist = config.downloadAllowlist
        let isAllowed: @Sendable (String, String) -> Bool = { host, path in
            CapabilityBroker.pathAllowlistMatches(host: host, path: path, allowlist: allowlist)
        }
        let delegate = DownloadRedirectGuard(
            isAllowed: isAllowed,
            allowInsecureHTTP: allowInsecure
        )
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse {
            if let final = http.url {
                guard let finalHost = final.host else { throw BrokerError.downloadDenied("no host") }
                try validateDownloadURL(final, host: finalHost)
            }
            if let cl = http.value(forHTTPHeaderField: "Content-Length"),
                let declared = Int(cl), declared > config.maxDownloadBytes
            {
                throw BrokerError.quotaExceeded
            }
        }

        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        defer { try? fh.close() }
        var written = 0
        var hasher = try SHA256StreamingHasher()
        for try await byte in bytes {
            if written + 1 > config.maxDownloadBytes {
                throw BrokerError.quotaExceeded
            }
            var b = byte
            try fh.write(contentsOf: Data(bytes: &b, count: 1))
            hasher.update(byte: byte)
            written += 1
        }
        try fh.synchronize()
        let actual = hasher.finalizeHex()
        if let expectedDigest, actual != expectedDigest {
            throw BrokerError.invalidRequest("digest mismatch")
        }
        // Atomic move into tool cache + bind metadata (BROKER-N13).
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tmp, to: finalURL)
        #if canImport(Darwin)
            let parent = finalURL.deletingLastPathComponent()
            let pfd = open(parent.path, O_RDONLY | O_DIRECTORY)
            if pfd >= 0 {
                _ = fsync(pfd)
                close(pfd)
            }
        #endif
        let meta: [String: Any] = [
            "sourceURL": urlString,
            "digest": actual,
            "bytes": written,
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try metaData.write(to: finalURL.appendingPathExtension("meta.json"), options: .atomic)
        return finalURL
    }

    /// Test fixture write that still enforces allowlist host/path (not a production network path).
    public func downloadWriteFixture(
        caller: ExtensionID,
        handle: BrokerHandleID,
        host: String,
        path: String,
        data: Data,
        expectedDigest: String? = nil,
        sourceURL: String? = nil
    ) throws -> URL {
        let h = try resolve(handle, caller: caller, kind: "download", op: "fetch")
        guard Self.pathAllowlistMatches(host: host, path: path, allowlist: config.downloadAllowlist)
        else {
            throw BrokerError.downloadDenied(host)
        }
        if data.count > config.maxDownloadBytes { throw BrokerError.quotaExceeded }
        let actual = try sha256Hex(data)
        if let expectedDigest, actual != expectedDigest {
            throw BrokerError.invalidRequest("digest mismatch")
        }
        let destDir = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(UUID().uuidString)
        try data.write(to: dest, options: .atomic)
        let meta: [String: Any] = [
            "sourceURL": sourceURL ?? "https://\(host)\(path)",
            "digest": actual,
            "bytes": data.count,
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try metaData.write(to: dest.appendingPathExtension("meta.json"), options: .atomic)
        return dest
    }

    /// Public allowlist check for host-side process materialization.
    public func processAllowed(executable: String, arguments: [String] = []) -> Bool {
        (try? resolveTrustedExecutable(executable: executable, arguments: arguments)) != nil
    }

    // MARK: - npm

    public func npmHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .network)
        return try issue(extensionID, kind: "npm", ops: ["install"])
    }

    /// Host-owned npm materializer (BROKER-N15 / EXT-013): copies from local registry root only.
    /// No lifecycle scripts. Immutable copy — does not mutate package.json after materialization.
    public func npmInstall(
        caller: ExtensionID,
        handle: BrokerHandleID,
        package: String,
        version: String?
    ) throws -> URL {
        let h = try resolve(handle, caller: caller, kind: "npm", op: "install")
        guard isNPMAllowed(package: package, version: version) else {
            throw BrokerError.npmDenied(package)
        }
        guard let registry = config.npmRegistryRoot else {
            throw BrokerError.npmDenied("no npm registry configured")
        }
        let ver = version ?? "latest"
        let packagePath = try npmPackageRelativePath(package: package)
        let source = registry
            .appendingPathComponent(packagePath, isDirectory: true)
            .appendingPathComponent(ver, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BrokerError.notFound("npm package \(package)@\(ver)")
        }
        let srcValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        if srcValues.isSymbolicLink == true {
            throw BrokerError.npmDenied("symlink package")
        }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("npm", isDirectory: true)
            .appendingPathComponent(packagePath, isDirectory: true)
            .appendingPathComponent(ver, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Scripts disabled by acquisition policy (no npm install / no lifecycle) — not by post-copy mutation.
        _ = try copyTreeRejectingSymlinks(from: source, to: dest, maxBytes: config.maxDownloadBytes)
        return dest
    }

    // MARK: - Wire dispatch (BROKER-N03 strict schemas)

    public func dispatch(method: ExtensionMethodID, extensionID: ExtensionID, payload: Data) async throws -> Data {
        switch method {
        case .worktreeList:
            let req = try decodeStrict(BrokerWire.HandlePath.self, from: payload, keys: ["handle", "path"])
            let items = try worktreeList(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                relative: req.path ?? ""
            )
            return try JSONSerialization.data(withJSONObject: ["entries": items])
        case .worktreeRead:
            let req = try decodeStrict(BrokerWire.HandlePathRequired.self, from: payload, keys: ["handle", "path"])
            let data = try worktreeRead(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                relative: req.path
            )
            return try JSONSerialization.data(withJSONObject: ["data_b64": data.base64EncodedString()])
        case .worktreeWhich:
            let req = try decodeStrict(BrokerWire.HandleName.self, from: payload, keys: ["handle", "name"])
            let path = try worktreeWhich(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                name: req.name
            )
            return try JSONSerialization.data(withJSONObject: ["path": path as Any])
        case .worktreeEnvironment:
            let req = try decodeStrict(BrokerWire.HandleNames.self, from: payload, keys: ["handle", "names"])
            let values = try worktreeEnvironment(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                names: Set(req.names)
            )
            return try JSONSerialization.data(withJSONObject: ["environment": values])
        case .projectInfo:
            let req = try decodeStrict(BrokerWire.HandleOnly.self, from: payload, keys: ["handle"])
            let info = try projectInfo(caller: extensionID, handle: BrokerHandleID(rawValue: req.handle))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(info)
        case .settingsGet:
            let req = try decodeStrict(BrokerWire.HandleKey.self, from: payload, keys: ["handle", "key"])
            let value = try settingsGet(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                key: req.key
            )
            return try JSONSerialization.data(withJSONObject: ["value": value as Any])
        case .settingsSet:
            let req = try decodeStrict(BrokerWire.HandleKeyValue.self, from: payload, keys: ["handle", "key", "value"])
            try settingsSet(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                key: req.key,
                value: req.value
            )
            return Data(#"{"ok":true}"#.utf8)
        case .storageGet:
            let req = try decodeStrict(BrokerWire.HandleKey.self, from: payload, keys: ["handle", "key"])
            let data = try storageGet(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                key: req.key
            )
            return try JSONSerialization.data(withJSONObject: [
                "data_b64": data?.base64EncodedString() as Any
            ])
        case .storageSet:
            let req = try decodeStrict(BrokerWire.HandleKeyDataB64.self, from: payload, keys: ["handle", "key", "data_b64"])
            guard let data = Data(base64Encoded: req.data_b64) else {
                throw BrokerError.invalidRequest("invalid base64")
            }
            try storageSet(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                key: req.key,
                value: data
            )
            return Data(#"{"ok":true}"#.utf8)
        case .processSpawn:
            let req = try decodeStrict(
                BrokerWire.ProcessSpawn.self,
                from: payload,
                keys: ["handle", "executable", "arguments", "cwd"]
            )
            let result = try await processSpawn(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                executable: req.executable,
                arguments: req.arguments,
                currentDirectory: req.cwd
            )
            return try JSONSerialization.data(withJSONObject: [
                "lease": result.lease.rawValue,
                "pid": result.pid,
                "supervisorLeaseID": result.supervisorLeaseID.uuidString,
            ])
        case .processKill:
            let req = try decodeStrict(BrokerWire.HandleOnly.self, from: payload, keys: ["handle"])
            try await processKill(caller: extensionID, handle: BrokerHandleID(rawValue: req.handle))
            return Data(#"{"ok":true}"#.utf8)
        case .downloadFetch:
            // Fixture path is explicit and still schema-validated (tests only).
            if let fixture = try? decodeStrict(
                BrokerWire.DownloadFixture.self,
                from: payload,
                keys: ["handle", "fixture_host", "fixture_path", "fixture_b64", "digest"]
            ) {
                guard let data = Data(base64Encoded: fixture.fixture_b64) else {
                    throw BrokerError.invalidRequest("invalid base64")
                }
                let url = try downloadWriteFixture(
                    caller: extensionID,
                    handle: BrokerHandleID(rawValue: fixture.handle),
                    host: fixture.fixture_host,
                    path: fixture.fixture_path,
                    data: data,
                    expectedDigest: fixture.digest
                )
                return try JSONSerialization.data(withJSONObject: ["path": url.path])
            }
            let req = try decodeStrict(
                BrokerWire.DownloadFetch.self,
                from: payload,
                keys: ["handle", "url", "digest"]
            )
            let dest = try await downloadFetch(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                urlString: req.url,
                expectedDigest: req.digest
            )
            return try JSONSerialization.data(withJSONObject: ["path": dest.path])
        case .npmInstall:
            let req = try decodeStrict(
                BrokerWire.NPMInstall.self,
                from: payload,
                keys: ["handle", "package", "version"]
            )
            let dest = try npmInstall(
                caller: extensionID,
                handle: BrokerHandleID(rawValue: req.handle),
                package: req.package,
                version: req.version
            )
            return try JSONSerialization.data(withJSONObject: ["path": dest.path])
        default:
            if method.rawValue == "broker.worktree.handle" {
                let h = try worktreeHandle(extensionID: extensionID)
                return try encodeHandle(h)
            }
            throw ExtensionWireError.methodNotFound
        }
    }

    public func mintHandlesJSON(extensionID: ExtensionID) throws -> Data {
        try requireRegistered(extensionID)
        var out: [String: String] = [:]
        if permissions[extensionID]?.contains(.readWorkspace) == true {
            out["worktree"] = try worktreeHandle(extensionID: extensionID).id.rawValue
            out["project"] = try projectHandle(extensionID: extensionID).id.rawValue
        }
        out["settings"] = try settingsHandle(extensionID: extensionID).id.rawValue
        out["storage"] = try storageHandle(extensionID: extensionID).id.rawValue
        if permissions[extensionID]?.contains(.startProcesses) == true {
            out["process"] = try processHandle(extensionID: extensionID).id.rawValue
        }
        if permissions[extensionID]?.contains(.network) == true {
            out["download"] = try downloadHandle(extensionID: extensionID).id.rawValue
            out["npm"] = try npmHandle(extensionID: extensionID).id.rawValue
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    /// Expose path-prefix policy for tests (BROKER-N14).
    public nonisolated static func isDownloadPathAllowed(
        host: String,
        path: String,
        allowlist: [DownloadAllow]
    ) -> Bool {
        pathAllowlistMatches(host: host, path: path, allowlist: allowlist)
    }

    // MARK: - Private resolve / issue

    private func issue(_ extensionID: ExtensionID, kind: String, ops: Set<String>) throws -> BrokerHandle {
        // BROKER-N02: never mint with generation 0 for unregistered extensions.
        guard let gen = generations[extensionID] else {
            throw BrokerError.unregisteredExtension
        }
        let h = BrokerHandle(extensionID: extensionID, generation: gen, kind: kind, operations: ops)
        handles[h.id] = h
        return h
    }

    /// BROKER-N01: every handle use is bound to caller id + live generation.
    private func resolve(
        _ id: BrokerHandleID,
        caller: ExtensionID,
        kind: String,
        op: String
    ) throws -> BrokerHandle {
        guard let h = handles[id] else { throw BrokerError.forgedHandle }
        guard h.extensionID == caller else { throw BrokerError.forgedHandle }
        guard let gen = generations[caller], gen == h.generation else {
            // Revoked or generation advanced.
            if generations[caller] == nil {
                throw BrokerError.revokedHandle
            }
            throw BrokerError.staleGeneration
        }
        guard h.kind == kind else { throw BrokerError.forgedHandle }
        guard h.operations.contains(op) else { throw BrokerError.permissionDenied(op) }
        return h
    }

    private func require(_ extensionID: ExtensionID, _ permission: ExtensionPermission) throws {
        try requireRegistered(extensionID)
        guard permissions[extensionID]?.contains(permission) == true else {
            throw BrokerError.permissionDenied(permission.rawValue)
        }
    }

    private func requireRegistered(_ extensionID: ExtensionID) throws {
        guard generations[extensionID] != nil else {
            throw BrokerError.unregisteredExtension
        }
    }

    // MARK: - Descriptor-relative worktree (BROKER-N06)

    private func listWorktreeDescriptor(handle: BrokerHandleID, relative: String) throws -> [String] {
        guard let root = worktreeRootByHandle[handle] ?? config.worktreeRoots.first else {
            throw BrokerError.notFound("no worktree root")
        }
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let rootFd: Int32
        do {
            rootFd = try DescriptorRelativeIO.openDirectory(at: rootURL)
        } catch {
            throw BrokerError.ioError(String(describing: error))
        }
        defer { DescriptorRelativeIO.close(rootFd) }
        let components: [String]
        do {
            components = try DescriptorRelativeIO.relativeComponents(relative)
        } catch {
            throw BrokerError.pathEscape
        }
        let dirFd: Int32
        let owns: Bool
        if components.isEmpty {
            dirFd = rootFd
            owns = false
        } else {
            do {
                dirFd = try DescriptorRelativeIO.openNestedDirectory(rootDirfd: rootFd, segments: components)
                owns = true
            } catch let error as DescriptorRelativeIOError {
                switch error {
                case .symlinkRefused, .pathEscape:
                    throw BrokerError.pathEscape
                case .openFailed(let msg), .operationFailed(let msg):
                    throw BrokerError.ioError(msg)
                case .notSupported:
                    throw BrokerError.unsupported("descriptor IO")
                }
            } catch {
                throw BrokerError.ioError(String(describing: error))
            }
        }
        defer { if owns { DescriptorRelativeIO.close(dirFd) } }
        do {
            return try DescriptorRelativeIO.listDirectory(dirfd: dirFd)
        } catch {
            throw BrokerError.ioError(String(describing: error))
        }
    }

    private func readWorktreeDescriptor(handle: BrokerHandleID, relative: String) throws -> Data {
        guard let root = worktreeRootByHandle[handle] ?? config.worktreeRoots.first else {
            throw BrokerError.notFound("no worktree root")
        }
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let components: [String]
        do {
            components = try DescriptorRelativeIO.relativeComponents(relative)
        } catch {
            throw BrokerError.pathEscape
        }
        guard !components.isEmpty else {
            throw BrokerError.invalidRequest("path required for read")
        }
        let rootFd: Int32
        do {
            rootFd = try DescriptorRelativeIO.openDirectory(at: rootURL)
        } catch {
            throw BrokerError.ioError(String(describing: error))
        }
        defer { DescriptorRelativeIO.close(rootFd) }
        let fd: Int32
        do {
            fd = try DescriptorRelativeIO.openNestedFile(
                rootDirfd: rootFd,
                relativePath: components.joined(separator: "/")
            )
        } catch let error as DescriptorRelativeIOError {
            switch error {
            case .symlinkRefused, .pathEscape:
                throw BrokerError.pathEscape
            case .openFailed(let msg), .operationFailed(let msg):
                if msg == "quotaExceeded" { throw BrokerError.quotaExceeded }
                throw BrokerError.ioError(msg)
            case .notSupported:
                throw BrokerError.unsupported("descriptor IO")
            }
        } catch {
            throw BrokerError.ioError(String(describing: error))
        }
        defer { DescriptorRelativeIO.close(fd) }
        do {
            return try DescriptorRelativeIO.readFile(fd: fd, maxBytes: config.maxWorktreeReadBytes)
        } catch let error as DescriptorRelativeIOError {
            if case .operationFailed(let msg) = error, msg == "quotaExceeded" {
                throw BrokerError.quotaExceeded
            }
            throw BrokerError.ioError(String(describing: error))
        } catch {
            throw BrokerError.ioError(String(describing: error))
        }
    }

    // MARK: - Storage accounting (BROKER-N09 / N10)

    private func storageURL(extensionID: ExtensionID, key: String) throws -> URL {
        let encoded = try sha256Hex(Data(key.utf8))
        return config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("kv", isDirectory: true)
            .appendingPathComponent(encoded)
    }

    private func ledgerURL(extensionID: ExtensionID) -> URL {
        config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("quota-ledger.json")
    }

    private func settingsFileURL(extensionID: ExtensionID) -> URL {
        config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func loadLedger(extensionID: ExtensionID) throws -> StorageLedger {
        let url = ledgerURL(extensionID: extensionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StorageLedger.self, from: data)
    }

    private func saveLedger(extensionID: ExtensionID, ledger: StorageLedger) throws {
        let url = ledgerURL(extensionID: extensionID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: .atomic)
        ledgers[extensionID] = ledger
    }

    private func loadSettings(extensionID: ExtensionID) throws -> [String: String] {
        let url = settingsFileURL(extensionID: extensionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw BrokerError.invalidRequest("corrupt settings")
        }
        return map
    }

    private func saveSettings(extensionID: ExtensionID, map: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        if data.count > config.maxSettingsBytes {
            throw BrokerError.quotaExceeded
        }
        var ledger = ledgers[extensionID] ?? (try? loadLedger(extensionID: extensionID)) ?? .empty
        let oldSettings = ledger.settingsBytes
        let nextTotal = ledger.usedBytes - oldSettings + data.count
        if nextTotal > config.storageQuotaBytes {
            throw BrokerError.quotaExceeded
        }
        let url = settingsFileURL(extensionID: extensionID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        ledger.settingsBytes = data.count
        ledger.usedBytes = nextTotal
        try saveLedger(extensionID: extensionID, ledger: ledger)
    }

    private func reserveAndCommitStorage(extensionID: ExtensionID, key: String, value: Data) throws {
        var ledger = ledgers[extensionID] ?? (try? loadLedger(extensionID: extensionID)) ?? .empty
        let keyHash = try sha256Hex(Data(key.utf8))
        let previous = ledger.keys[keyHash] ?? 0
        let isNew = previous == 0 && !ledger.keys.keys.contains(keyHash)
        if isNew && ledger.keys.count >= config.maxKeyCount {
            throw BrokerError.quotaExceeded
        }
        let nextKV = ledger.usedBytes - ledger.settingsBytes - previous + value.count
        let nextTotal = nextKV + ledger.settingsBytes
        if nextTotal > config.storageQuotaBytes {
            throw BrokerError.quotaExceeded
        }
        // Reservation accepted — commit write then durable ledger.
        let url = try storageURL(extensionID: extensionID, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, options: .atomic)
        ledger.keys[keyHash] = value.count
        ledger.usedBytes = nextTotal
        try saveLedger(extensionID: extensionID, ledger: ledger)
    }

    private func validateKey(_ key: String) throws {
        if key.isEmpty || key.count > config.maxKeyLength {
            throw BrokerError.invalidRequest("key length")
        }
    }

    private func noteMutation(extensionID: ExtensionID) throws {
        let now = ContinuousClock.now
        var stamps = mutationTimestamps[extensionID] ?? []
        let window = config.mutationWindow
        stamps = stamps.filter { now - $0 < window }
        if stamps.count >= config.maxMutationsPerWindow {
            throw BrokerError.quotaExceeded
        }
        stamps.append(now)
        mutationTimestamps[extensionID] = stamps
    }

    // MARK: - Process trust (BROKER-N07)

    private func resolveTrustedExecutable(executable: String, arguments: [String]) throws -> String {
        let execPath = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        for allow in config.processAllowlist {
            let allowedPath: String
            if allow.command == "**" {
                guard argumentsMatch(allow.argumentMatcher, arguments: arguments) else { continue }
                // Wildcard command still requires absolute real path and not under worktree.
                guard execPath.hasPrefix("/") else { throw BrokerError.processDenied(executable) }
                try rejectExtensionWritableExecutable(execPath)
                return execPath
            }
            if allow.command.hasPrefix("/") {
                allowedPath = URL(fileURLWithPath: allow.command).resolvingSymlinksInPath().standardizedFileURL.path
            } else {
                var found: String?
                for dir in ["/usr/bin", "/bin", "/usr/local/bin"] {
                    let candidate = URL(fileURLWithPath: dir).appendingPathComponent(allow.command)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        found = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                        break
                    }
                }
                guard let found else { continue }
                allowedPath = found
            }
            if execPath == allowedPath {
                guard argumentsMatch(allow.argumentMatcher, arguments: arguments) else {
                    throw BrokerError.processDenied(executable)
                }
                try rejectExtensionWritableExecutable(allowedPath)
                // Re-check isExecutable immediately (TOCTOU minimize).
                guard FileManager.default.isExecutableFile(atPath: allowedPath) else {
                    throw BrokerError.processDenied(executable)
                }
                return allowedPath
            }
        }
        throw BrokerError.processDenied(executable)
    }

    private func argumentsMatch(_ matcher: ProcessArgumentMatcher, arguments: [String]) -> Bool {
        switch matcher {
        case .anyArguments:
            return true
        case .exactArguments(let expected):
            return expected == arguments
        }
    }

    private func rejectExtensionWritableExecutable(_ path: String) throws {
        for root in config.worktreeRoots {
            let r = root.resolvingSymlinksInPath().path
            if path == r || path.hasPrefix(r + "/") {
                throw BrokerError.processDenied("executable under worktree")
            }
        }
    }

    // MARK: - Download path policy (BROKER-N14)

    private func validateDownloadURL(_ url: URL, host: String) throws {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "https" {
            // ok
        } else if scheme == "http", config.allowInsecureHTTP {
            // explicit profile
        } else {
            throw BrokerError.downloadDenied("https only")
        }
        guard Self.pathAllowlistMatches(host: host, path: url.path, allowlist: config.downloadAllowlist)
        else {
            throw BrokerError.downloadDenied(host)
        }
    }

    nonisolated private static func pathAllowlistMatches(
        host: String,
        path: String,
        allowlist: [DownloadAllow]
    ) -> Bool {
        let normalized = normalizeURLPathComponents(path)
        for allow in allowlist {
            if allow.host == host || allow.host == "**" {
                if allow.pathPrefix.isEmpty { return true }
                let prefix = allow.pathPrefix.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                    .filter { !$0.isEmpty }
                // Component-wise prefix: /allowed must not match /allowed-bad
                if normalized.count >= prefix.count,
                    Array(normalized.prefix(prefix.count)) == prefix
                {
                    return true
                }
            }
        }
        return false
    }

    /// Percent-decode once, split on `/`, drop empty / `.` components; reject `..`.
    nonisolated private static func normalizeURLPathComponents(_ path: String) -> [String] {
        let decoded = path.removingPercentEncoding ?? path
        var parts: [String] = []
        for raw in decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if raw == "." { continue }
            if raw == ".." {
                // Reject traversal rather than resolving out of allowlist space.
                return ["__REJECT_DOTDOT__"]
            }
            parts.append(raw)
        }
        return parts
    }

    // MARK: - npm (BROKER-N15)

    private func npmPackageRelativePath(package: String) throws -> String {
        // Allow scoped packages `@scope/name` and unscoped `name`. Reject path escape.
        if package.contains("\\") || package.contains("..") {
            throw BrokerError.npmDenied(package)
        }
        if package.hasPrefix("@") {
            let parts = package.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                !parts[0].isEmpty,
                !parts[1].isEmpty,
                !parts[1].contains("/")
            else {
                throw BrokerError.npmDenied(package)
            }
            return "\(parts[0])/\(parts[1])"
        }
        if package.contains("/") {
            throw BrokerError.npmDenied(package)
        }
        guard !package.isEmpty else { throw BrokerError.npmDenied(package) }
        return package
    }

    private func isNPMAllowed(package: String, version: String?) -> Bool {
        for allow in config.npmAllowlist {
            if allow.package == package || allow.package == "**" {
                if allow.version == nil || allow.version == version || allow.version == "*" { return true }
            }
        }
        return false
    }

    /// Recursive copy returning total bytes for parent accounting (BROKER-N15). Includes hidden files.
    @discardableResult
    private func copyTreeRejectingSymlinks(from source: URL, to dest: URL, maxBytes: Int) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // Include hidden files — do not skip.
        let children = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: []
        )
        var total = 0
        for url in children {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                throw BrokerError.npmDenied("symlink in package")
            }
            if values.isDirectory == true {
                let nested = dest.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                let nestedBytes = try copyTreeRejectingSymlinks(from: url, to: nested, maxBytes: maxBytes - total)
                total += nestedBytes
                if total > maxBytes { throw BrokerError.quotaExceeded }
                continue
            }
            guard values.isRegularFile == true else {
                throw BrokerError.npmDenied("special file in package")
            }
            let size = values.fileSize ?? 0
            total += size
            if total > maxBytes { throw BrokerError.quotaExceeded }
            let out = dest.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            try fm.copyItem(at: url, to: out)
        }
        return total
    }

    private func validateCWD(_ cwd: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            throw BrokerError.invalidRequest("cwd")
        }
        if !config.worktreeRoots.isEmpty {
            let ok = config.worktreeRoots.contains { root in
                let r = root.resolvingSymlinksInPath().path
                let c = cwd.resolvingSymlinksInPath().path
                return c == r || c.hasPrefix(r + "/")
            }
            if !ok { throw BrokerError.pathEscape }
        }
    }

    private func encodeHandle(_ h: BrokerHandle) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "handle": h.id.rawValue,
            "kind": h.kind,
            "generation": h.generation,
        ])
    }

    private func sha256Hex(_ data: Data) throws -> String {
        do {
            return try SecurityDigest.sha256Hex(data)
        } catch SecurityDigestError.cryptoUnavailable {
            throw BrokerError.invalidRequest("cryptoUnavailable: SHA-256 required")
        }
    }

    // MARK: - Strict wire decode (BROKER-N03)

    private func decodeStrict<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        keys: Set<String>
    ) throws -> T {
        guard !data.isEmpty else {
            throw BrokerError.invalidRequest("empty payload")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw BrokerError.invalidRequest("malformed json")
        }
        guard let dict = obj as? [String: Any] else {
            throw BrokerError.invalidRequest("object required")
        }
        let unknown = Set(dict.keys).subtracting(keys)
        if !unknown.isEmpty {
            throw BrokerError.invalidRequest("unknown fields: \(unknown.sorted().joined(separator: ","))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BrokerError.invalidRequest("schema: \(error.localizedDescription)")
        }
    }
}

// MARK: - Wire schemas

private enum BrokerWire {
    struct HandleOnly: Codable {
        let handle: String
    }

    struct HandlePath: Codable {
        let handle: String
        let path: String?
    }

    struct HandlePathRequired: Codable {
        let handle: String
        let path: String
    }

    struct HandleName: Codable {
        let handle: String
        let name: String
    }

    struct HandleNames: Codable {
        let handle: String
        let names: [String]
    }

    struct HandleKey: Codable {
        let handle: String
        let key: String
    }

    struct HandleKeyValue: Codable {
        let handle: String
        let key: String
        let value: String
    }

    struct HandleKeyDataB64: Codable {
        let handle: String
        let key: String
        let data_b64: String
    }

    struct ProcessSpawn: Codable {
        let handle: String
        let executable: String
        let arguments: [String]
        let cwd: String?
    }

    struct DownloadFetch: Codable {
        let handle: String
        let url: String
        let digest: String?
    }

    struct DownloadFixture: Codable {
        let handle: String
        let fixture_host: String
        let fixture_path: String
        let fixture_b64: String
        let digest: String?
    }

    struct NPMInstall: Codable {
        let handle: String
        let package: String
        let version: String?
    }
}

// MARK: - Streaming SHA-256

private struct SHA256StreamingHasher {
    #if canImport(CryptoKit)
        private var hasher = SHA256()
        init() throws {}
        mutating func update(byte: UInt8) {
            hasher.update(data: Data([byte]))
        }
        mutating func update(data: Data) {
            hasher.update(data: data)
        }
        mutating func finalizeHex() -> String {
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    #else
        init() throws {
            throw BrokerError.invalidRequest("cryptoUnavailable: SHA-256 required")
        }
        mutating func update(byte: UInt8) {}
        mutating func update(data: Data) { _ = data }
        mutating func finalizeHex() -> String { "" }
    #endif
}

// MARK: - Download redirect revalidation (BROKER-N13)

/// URLSession delegate that rejects redirects outside allowlist / non-HTTPS policy.
final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let isAllowed: @Sendable (String, String) -> Bool
    private let allowInsecureHTTP: Bool

    init(
        isAllowed: @escaping @Sendable (String, String) -> Bool,
        allowInsecureHTTP: Bool = false
    ) {
        self.isAllowed = isAllowed
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, let host = url.host else {
            completionHandler(nil)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "https" || (scheme == "http" && allowInsecureHTTP) {
            if isAllowed(host, url.path) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        } else {
            completionHandler(nil)
        }
    }
}
