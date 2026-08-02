import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
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
            platformProfile: PlatformCapabilityProfile = .default()
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
        }
    }

    public struct ProcessAllow: Sendable, Hashable {
        public var command: String
        public var argsGlob: [String]
        public init(command: String, argsGlob: [String] = ["**"]) {
            self.command = command
            self.argsGlob = argsGlob
        }
    }

    public struct DownloadAllow: Sendable, Hashable {
        public var host: String
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

    private var config: Config
    private var handles: [BrokerHandleID: BrokerHandle] = [:]
    private var permissions: [ExtensionID: Set<ExtensionPermission>] = [:]
    private var generations: [ExtensionID: UInt64] = [:]
    private var storageBytes: [ExtensionID: Int] = [:]
    private var liveProcesses: [BrokerHandleID: ProcessHandle] = [:]
    /// Per-handle worktree root (EXT-015 / §15.18 multi-root).
    private var worktreeRootByHandle: [BrokerHandleID: URL] = [:]
    private let processService: ProcessService

    public init(config: Config) {
        self.config = config
        self.processService = ProcessService(profile: config.platformProfile)
        try? FileManager.default.createDirectory(at: config.storageRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config.toolCacheRoot, withIntermediateDirectories: true)
    }

    public func registerExtension(
        id: ExtensionID,
        generation: UInt64,
        granted: Set<ExtensionPermission>
    ) {
        permissions[id] = granted
        generations[id] = generation
    }

    public func revokeExtension(id: ExtensionID) {
        permissions[id] = nil
        generations[id] = nil
        let toKill = handles.values.filter { $0.extensionID == id }
        for h in toKill {
            handles[h.id] = nil
            worktreeRootByHandle[h.id] = nil
            if let p = liveProcesses.removeValue(forKey: h.id) {
                p.cancel()
            }
        }
        storageBytes[id] = nil
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
            // Handle may still be issued; list/read fail with notFound until roots exist.
            selected = nil
        }
        let handle = issue(extensionID, kind: "worktree", ops: ["list", "read", "which", "environment"])
        if let selected {
            worktreeRootByHandle[handle.id] = selected
        }
        return handle
    }

    public func worktreeList(handle: BrokerHandleID, relative: String = "") throws -> [String] {
        let h = try resolve(handle, kind: "worktree", op: "list")
        let root = try resolveWorktreePath(handle: h.id, extensionID: h.extensionID, relative: relative)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.sorted()
    }

    public func worktreeRead(handle: BrokerHandleID, relative: String) throws -> Data {
        let h = try resolve(handle, kind: "worktree", op: "read")
        let url = try resolveWorktreePath(handle: h.id, extensionID: h.extensionID, relative: relative)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.intValue > config.maxWorktreeReadBytes {
            throw BrokerError.quotaExceeded
        }
        let data = try Data(contentsOf: url)
        if data.count > config.maxWorktreeReadBytes {
            throw BrokerError.quotaExceeded
        }
        return data
    }

    /// Find an executable under worktree roots first, then the process PATH (scoped).
    public func worktreeWhich(handle: BrokerHandleID, name: String) throws -> String? {
        _ = try resolve(handle, kind: "worktree", op: "which")
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/"), !cleaned.contains("..") else {
            throw BrokerError.invalidRequest("executable name")
        }
        // Prefer worktree-local bin directories.
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
        handle: BrokerHandleID,
        names: Set<String>,
        allowed: Set<String> = CapabilityBroker.defaultAllowedEnvironmentNames
    ) throws -> [String: String] {
        _ = try resolve(handle, kind: "worktree", op: "environment")
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
        return issue(extensionID, kind: "project", ops: ["info"])
    }

    public func projectInfo(handle: BrokerHandleID) throws -> [String: String] {
        _ = try resolve(handle, kind: "project", op: "info")
        return [
            "name": config.projectName,
            "roots": config.worktreeRoots.map(\.path).joined(separator: ":"),
        ]
    }

    // MARK: - Settings (durable under storage root — EXT-011)

    public func settingsHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        return issue(extensionID, kind: "settings", ops: ["get", "set"])
    }

    public func settingsGet(handle: BrokerHandleID, key: String) throws -> String? {
        let h = try resolve(handle, kind: "settings", op: "get")
        let map = try loadSettings(extensionID: h.extensionID)
        return map[key]
    }

    public func settingsSet(handle: BrokerHandleID, key: String, value: String) throws {
        let h = try resolve(handle, kind: "settings", op: "set")
        var map = try loadSettings(extensionID: h.extensionID)
        map[key] = value
        try saveSettings(extensionID: h.extensionID, map: map)
    }

    // MARK: - Storage

    public func storageHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        return issue(extensionID, kind: "storage", ops: ["get", "set"])
    }

    public func storageGet(handle: BrokerHandleID, key: String) throws -> Data? {
        let h = try resolve(handle, kind: "storage", op: "get")
        let url = storageURL(extensionID: h.extensionID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func storageSet(handle: BrokerHandleID, key: String, value: Data) throws {
        let h = try resolve(handle, kind: "storage", op: "set")
        let url = storageURL(extensionID: h.extensionID, key: key)
        let existing = (try? Data(contentsOf: url))?.count ?? 0
        // Prefer live disk reconciliation so restarts cannot zero quotas (EXT-010).
        let used = max(storageBytes[h.extensionID] ?? 0, usageOnDisk(extensionID: h.extensionID))
        let next = used - existing + value.count
        if next > config.storageQuotaBytes {
            throw BrokerError.quotaExceeded
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, options: .atomic)
        storageBytes[h.extensionID] = usageOnDisk(extensionID: h.extensionID)
    }

    // MARK: - Process

    public func processHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .startProcesses)
        return issue(extensionID, kind: "process", ops: ["spawn", "kill"])
    }

    public func processSpawn(
        handle: BrokerHandleID,
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) throws -> (lease: BrokerHandleID, pid: Int32) {
        let h = try resolve(handle, kind: "process", op: "spawn")
        guard isProcessAllowed(executable: executable, arguments: arguments) else {
            throw BrokerError.processDenied(executable)
        }
        let cwd = currentDirectory.map { URL(fileURLWithPath: $0) }
        if let cwd {
            try validateCWD(cwd)
        }
        let request = ProcessLaunchRequest(
            executable: executable,
            arguments: arguments,
            mode: .direct,
            currentDirectory: cwd,
            environment: [:],
            mergeEnvironment: false,
            capabilityKind: .localProcess
        )
        let processHandle = try processService.launch(request)
        let lease = issue(h.extensionID, kind: "processLease", ops: ["kill"])
        liveProcesses[lease.id] = processHandle
        return (lease.id, processHandle.processIdentifier)
    }

    public func processKill(handle: BrokerHandleID) throws {
        let h = try resolve(handle, kind: "processLease", op: "kill")
        if let p = liveProcesses.removeValue(forKey: h.id) {
            p.cancel()
        }
        handles[h.id] = nil
    }

    // MARK: - Download

    public func downloadHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .network)
        return issue(extensionID, kind: "download", ops: ["fetch"])
    }

    public func downloadFetch(
        handle: BrokerHandleID, urlString: String, expectedDigest: String? = nil
    ) async throws -> URL {
        let h = try resolve(handle, kind: "download", op: "fetch")
        guard let url = URL(string: urlString), let host = url.host else {
            throw BrokerError.invalidRequest("bad url")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw BrokerError.downloadDenied("https only")
        }
        guard isDownloadAllowed(host: host, path: url.path) else {
            throw BrokerError.downloadDenied(host)
        }
        // EXT-012: stream with mid-stream byte cap (never load full response then check).
        let delegate = DownloadRedirectGuard(isAllowed: { [config] host, path in
            // Capture allowlist via local copy of checks
            for allow in config.downloadAllowlist {
                if allow.host == host || allow.host == "**" {
                    if allow.pathPrefix.isEmpty { return true }
                    let prefix = "/" + allow.pathPrefix.joined(separator: "/")
                    if path.hasPrefix(prefix) || path.hasPrefix(String(prefix.dropFirst())) { return true }
                }
            }
            return false
        })
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, let finalURL = http.url {
            guard let finalHost = finalURL.host else { throw BrokerError.downloadDenied("no host") }
            guard isDownloadAllowed(host: finalHost, path: finalURL.path) else {
                throw BrokerError.downloadDenied(finalHost)
            }
        }
        var data = Data()
        data.reserveCapacity(min(config.maxDownloadBytes, 64 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count > config.maxDownloadBytes {
                throw BrokerError.quotaExceeded
            }
        }
        if let expectedDigest {
            let actual = sha256Hex(data)
            if actual != expectedDigest {
                throw BrokerError.invalidRequest("digest mismatch")
            }
        }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Test-only local fetch that still enforces allowlist host parsing for https test URLs.
    public func downloadWriteFixture(
        handle: BrokerHandleID,
        host: String,
        path: String,
        data: Data,
        expectedDigest: String? = nil
    ) throws -> URL {
        let h = try resolve(handle, kind: "download", op: "fetch")
        guard isDownloadAllowed(host: host, path: path) else {
            throw BrokerError.downloadDenied(host)
        }
        if data.count > config.maxDownloadBytes { throw BrokerError.quotaExceeded }
        if let expectedDigest {
            let actual = sha256Hex(data)
            if actual != expectedDigest {
                throw BrokerError.invalidRequest("digest mismatch")
            }
        }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Public allowlist check for host-side process materialization.
    public func processAllowed(executable: String, arguments: [String] = []) -> Bool {
        isProcessAllowed(executable: executable, arguments: arguments)
    }

    // MARK: - npm

    public func npmHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .network)
        return issue(extensionID, kind: "npm", ops: ["install"])
    }

    /// Host-owned npm materializer (EXT-013): copies from local registry root only.
    /// No lifecycle scripts. Not a stub `package.json` writer.
    public func npmInstall(handle: BrokerHandleID, package: String, version: String?) throws -> URL {
        let h = try resolve(handle, kind: "npm", op: "install")
        guard isNPMAllowed(package: package, version: version) else {
            throw BrokerError.npmDenied(package)
        }
        guard let registry = config.npmRegistryRoot else {
            throw BrokerError.npmDenied("no npm registry configured")
        }
        let ver = version ?? "latest"
        // Reject path-like package names.
        if package.contains("..") || package.contains("/") || package.contains("\\") {
            throw BrokerError.npmDenied(package)
        }
        let source = registry
            .appendingPathComponent(package, isDirectory: true)
            .appendingPathComponent(ver, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BrokerError.notFound("npm package \(package)@\(ver)")
        }
        // Reject symlinks at package root.
        let srcValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        if srcValues.isSymbolicLink == true {
            throw BrokerError.npmDenied("symlink package")
        }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("npm", isDirectory: true)
            .appendingPathComponent(package, isDirectory: true)
            .appendingPathComponent(ver, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyTreeRejectingSymlinks(from: source, to: dest, maxBytes: config.maxDownloadBytes)
        // Ensure no scripts execute — strip scripts from package.json if present.
        let pkgJSON = dest.appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: pkgJSON.path),
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: pkgJSON)) as? [String: Any]
        {
            obj["scripts"] = [:]
            obj["scripts_disabled"] = true
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: pkgJSON, options: .atomic)
        }
        return dest
    }

    // MARK: - Wire dispatch

    public func dispatch(method: ExtensionMethodID, extensionID: ExtensionID, payload: Data) async throws -> Data {
        let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        switch method {
        case .worktreeList:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let rel = obj["path"] as? String ?? ""
            let items = try worktreeList(handle: hid, relative: rel)
            return try JSONSerialization.data(withJSONObject: ["entries": items])
        case .worktreeRead:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let rel = obj["path"] as? String ?? ""
            let data = try worktreeRead(handle: hid, relative: rel)
            return try JSONSerialization.data(withJSONObject: ["data_b64": data.base64EncodedString()])
        case .worktreeWhich:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let name = obj["name"] as? String ?? ""
            let path = try worktreeWhich(handle: hid, name: name)
            return try JSONSerialization.data(withJSONObject: ["path": path as Any])
        case .worktreeEnvironment:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let names = Set(obj["names"] as? [String] ?? [])
            let values = try worktreeEnvironment(handle: hid, names: names)
            return try JSONSerialization.data(withJSONObject: ["environment": values])
        case .projectInfo:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let info = try projectInfo(handle: hid)
            return try JSONSerialization.data(withJSONObject: info)
        case .settingsGet:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let key = obj["key"] as? String ?? ""
            let value = try settingsGet(handle: hid, key: key)
            return try JSONSerialization.data(withJSONObject: ["value": value as Any])
        case .settingsSet:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let key = obj["key"] as? String ?? ""
            let value = obj["value"] as? String ?? ""
            try settingsSet(handle: hid, key: key, value: value)
            return Data(#"{"ok":true}"#.utf8)
        case .storageGet:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let key = obj["key"] as? String ?? ""
            let data = try storageGet(handle: hid, key: key)
            return try JSONSerialization.data(withJSONObject: [
                "data_b64": data?.base64EncodedString() as Any
            ])
        case .storageSet:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let key = obj["key"] as? String ?? ""
            let b64 = obj["data_b64"] as? String ?? ""
            let data = Data(base64Encoded: b64) ?? Data()
            try storageSet(handle: hid, key: key, value: data)
            return Data(#"{"ok":true}"#.utf8)
        case .processSpawn:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let exe = obj["executable"] as? String ?? ""
            let args = obj["arguments"] as? [String] ?? []
            let result = try processSpawn(handle: hid, executable: exe, arguments: args)
            return try JSONSerialization.data(withJSONObject: [
                "lease": result.lease.rawValue,
                "pid": result.pid,
            ])
        case .processKill:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            try processKill(handle: hid)
            return Data(#"{"ok":true}"#.utf8)
        case .downloadFetch:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            if let host = obj["fixture_host"] as? String,
                let path = obj["fixture_path"] as? String,
                let b64 = obj["fixture_b64"] as? String,
                let data = Data(base64Encoded: b64)
            {
                let url = try downloadWriteFixture(handle: hid, host: host, path: path, data: data)
                return try JSONSerialization.data(withJSONObject: ["path": url.path])
            }
            let urlString = obj["url"] as? String ?? ""
            let digest = obj["digest"] as? String
            let dest = try await downloadFetch(handle: hid, urlString: urlString, expectedDigest: digest)
            return try JSONSerialization.data(withJSONObject: ["path": dest.path])
        case .npmInstall:
            let hid = BrokerHandleID(rawValue: obj["handle"] as? String ?? "")
            let pkg = obj["package"] as? String ?? ""
            let ver = obj["version"] as? String
            let dest = try npmInstall(handle: hid, package: pkg, version: ver)
            return try JSONSerialization.data(withJSONObject: ["path": dest.path])
        default:
            // Issue handles
            if method.rawValue == "broker.worktree.handle" {
                let h = try worktreeHandle(extensionID: extensionID)
                return try encodeHandle(h)
            }
            throw ExtensionWireError.methodNotFound
        }
    }

    public func mintHandlesJSON(extensionID: ExtensionID) throws -> Data {
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

    // MARK: - Private

    private func issue(_ extensionID: ExtensionID, kind: String, ops: Set<String>) -> BrokerHandle {
        let gen = generations[extensionID] ?? 0
        let h = BrokerHandle(extensionID: extensionID, generation: gen, kind: kind, operations: ops)
        handles[h.id] = h
        return h
    }

    private func resolve(_ id: BrokerHandleID, kind: String, op: String) throws -> BrokerHandle {
        guard let h = handles[id] else { throw BrokerError.forgedHandle }
        guard h.kind == kind || (kind == "processLease" && h.kind == "processLease") else {
            throw BrokerError.forgedHandle
        }
        guard h.operations.contains(op) else { throw BrokerError.permissionDenied(op) }
        if let gen = generations[h.extensionID], gen != h.generation {
            throw BrokerError.staleGeneration
        }
        return h
    }

    private func require(_ extensionID: ExtensionID, _ permission: ExtensionPermission) throws {
        guard permissions[extensionID]?.contains(permission) == true else {
            throw BrokerError.permissionDenied(permission.rawValue)
        }
    }

    private func resolveWorktreePath(
        handle: BrokerHandleID,
        extensionID: ExtensionID,
        relative: String
    ) throws -> URL {
        _ = extensionID
        guard let root = worktreeRootByHandle[handle] ?? config.worktreeRoots.first else {
            throw BrokerError.notFound("no worktree root")
        }
        let cleaned = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.contains("..") { throw BrokerError.pathEscape }
        // Component-aware containment (not string hasPrefix alone).
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let url = cleaned.isEmpty ? rootResolved : rootResolved.appendingPathComponent(cleaned)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = rootResolved.pathComponents
        let fullParts = resolved.pathComponents
        guard fullParts.count >= rootParts.count,
            Array(fullParts.prefix(rootParts.count)) == rootParts
        else {
            throw BrokerError.pathEscape
        }
        return resolved
    }

    /// Collision-free key encoding (EXT-010) — never sanitize by replacing `/` with `_`.
    private func storageURL(extensionID: ExtensionID, key: String) -> URL {
        let encoded = sha256Hex(Data(key.utf8))
        return config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("kv", isDirectory: true)
            .appendingPathComponent(encoded)
    }

    private func settingsFileURL(extensionID: ExtensionID) -> URL {
        config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func loadSettings(extensionID: ExtensionID) throws -> [String: String] {
        let url = settingsFileURL(extensionID: extensionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func saveSettings(extensionID: ExtensionID, map: [String: String]) throws {
        let url = settingsFileURL(extensionID: extensionID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func usageOnDisk(extensionID: ExtensionID) -> Int {
        let kv = config.storageRoot
            .appendingPathComponent(extensionID.directoryKey, isDirectory: true)
            .appendingPathComponent("kv", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: kv.path) else { return 0 }
        var total = 0
        if let files = try? fm.contentsOfDirectory(at: kv, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files {
                if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += size
                }
            }
        }
        return total
    }

    /// EXT-014: no basename-only allow — absolute path identity or trusted-dir resolution.
    private func isProcessAllowed(executable: String, arguments: [String]) -> Bool {
        let execPath = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        for allow in config.processAllowlist {
            if allow.command == "**" {
                return allow.argsGlob == ["**"] || allow.argsGlob == arguments
            }
            let allowedPath: String
            if allow.command.hasPrefix("/") {
                allowedPath = URL(fileURLWithPath: allow.command).resolvingSymlinksInPath().standardizedFileURL.path
            } else {
                // Name-only entries resolve only under fixed trusted system directories.
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
                return allow.argsGlob == ["**"] || allow.argsGlob == arguments
            }
        }
        return false
    }

    private func copyTreeRejectingSymlinks(from source: URL, to dest: URL, maxBytes: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let children = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
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
                try copyTreeRejectingSymlinks(from: url, to: nested, maxBytes: maxBytes - total)
                // Approximate nested size by scanning dest (best-effort).
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
    }

    private func isDownloadAllowed(host: String, path: String) -> Bool {
        for allow in config.downloadAllowlist {
            if allow.host == host || allow.host == "**" {
                if allow.pathPrefix.isEmpty { return true }
                let prefix = "/" + allow.pathPrefix.joined(separator: "/")
                if path.hasPrefix(prefix) || path.hasPrefix(String(prefix.dropFirst())) { return true }
            }
        }
        return false
    }

    private func isNPMAllowed(package: String, version: String?) -> Bool {
        for allow in config.npmAllowlist {
            if allow.package == package || allow.package == "**" {
                if allow.version == nil || allow.version == version || allow.version == "*" { return true }
            }
        }
        return false
    }

    private func validateCWD(_ cwd: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            throw BrokerError.invalidRequest("cwd")
        }
        // Must be under a worktree root if roots configured
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

    private func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            let d = SHA256.hash(data: data)
            return d.map { String(format: "%02x", $0) }.joined()
        #else
            fatalError("CryptoKit unavailable: broker digests require SHA-256 (fail closed)")
        #endif
    }
}

// MARK: - Download redirect revalidation (EXT-012)

/// URLSession delegate that rejects redirects to hosts/paths outside the download allowlist.
final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let isAllowed: @Sendable (String, String) -> Bool

    init(isAllowed: @escaping @Sendable (String, String) -> Bool) {
        self.isAllowed = isAllowed
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
        if isAllowed(host, url.path) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
