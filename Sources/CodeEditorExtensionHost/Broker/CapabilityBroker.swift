import Foundation
import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
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
        public var processAllowlist: [ProcessAllow]
        public var downloadAllowlist: [DownloadAllow]
        public var npmAllowlist: [NPMAllow]
        public var platformProfile: PlatformCapabilityProfile

        public init(
            worktreeRoots: [URL] = [],
            projectName: String = "project",
            storageRoot: URL,
            toolCacheRoot: URL,
            storageQuotaBytes: Int = 16 * 1024 * 1024,
            maxDownloadBytes: Int = 32 * 1024 * 1024,
            processAllowlist: [ProcessAllow] = [],
            downloadAllowlist: [DownloadAllow] = [],
            npmAllowlist: [NPMAllow] = [],
            platformProfile: PlatformCapabilityProfile = .default()
        ) {
            self.worktreeRoots = worktreeRoots
            self.projectName = projectName
            self.storageRoot = storageRoot
            self.toolCacheRoot = toolCacheRoot
            self.storageQuotaBytes = storageQuotaBytes
            self.maxDownloadBytes = maxDownloadBytes
            self.processAllowlist = processAllowlist
            self.downloadAllowlist = downloadAllowlist
            self.npmAllowlist = npmAllowlist
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
            if let p = liveProcesses.removeValue(forKey: h.id) {
                p.cancel()
            }
        }
        storageBytes[id] = nil
    }

    // MARK: - Worktree

    public func worktreeHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .readWorkspace)
        return issue(extensionID, kind: "worktree", ops: ["list", "read"])
    }

    public func worktreeList(handle: BrokerHandleID, relative: String = "") throws -> [String] {
        let h = try resolve(handle, kind: "worktree", op: "list")
        let root = try resolveWorktreePath(h.extensionID, relative: relative)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.sorted()
    }

    public func worktreeRead(handle: BrokerHandleID, relative: String) throws -> Data {
        let h = try resolve(handle, kind: "worktree", op: "read")
        let url = try resolveWorktreePath(h.extensionID, relative: relative)
        return try Data(contentsOf: url)
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

    // MARK: - Settings

    private var settingsStore: [ExtensionID: [String: String]] = [:]

    public func settingsHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        return issue(extensionID, kind: "settings", ops: ["get", "set"])
    }

    public func settingsGet(handle: BrokerHandleID, key: String) throws -> String? {
        let h = try resolve(handle, kind: "settings", op: "get")
        return settingsStore[h.extensionID]?[key]
    }

    public func settingsSet(handle: BrokerHandleID, key: String, value: String) throws {
        let h = try resolve(handle, kind: "settings", op: "set")
        var map = settingsStore[h.extensionID] ?? [:]
        map[key] = value
        settingsStore[h.extensionID] = map
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
        let used = storageBytes[h.extensionID] ?? 0
        if used + value.count > config.storageQuotaBytes {
            throw BrokerError.quotaExceeded
        }
        let url = storageURL(extensionID: h.extensionID, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, options: .atomic)
        storageBytes[h.extensionID] = used + value.count
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

    public func downloadFetch(handle: BrokerHandleID, urlString: String, expectedDigest: String? = nil) async throws -> URL {
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
        // Local fixture scheme for tests: file:// under tool cache or explicit test fetch via data
        // Real HTTPS download with size cap.
        let (data, response) = try await URLSession.shared.data(from: url)
        if data.count > config.maxDownloadBytes {
            throw BrokerError.quotaExceeded
        }
        _ = response
        if let expectedDigest {
            let actual = sha256Hex(data)
            if actual != expectedDigest {
                throw BrokerError.invalidRequest("digest mismatch")
            }
        }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Test-only local fetch that still enforces allowlist host parsing for https test URLs.
    public func downloadWriteFixture(handle: BrokerHandleID, host: String, path: String, data: Data) throws -> URL {
        let h = try resolve(handle, kind: "download", op: "fetch")
        guard isDownloadAllowed(host: host, path: path) else {
            throw BrokerError.downloadDenied(host)
        }
        if data.count > config.maxDownloadBytes { throw BrokerError.quotaExceeded }
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - npm

    public func npmHandle(extensionID: ExtensionID) throws -> BrokerHandle {
        try require(extensionID, .network)
        return issue(extensionID, kind: "npm", ops: ["install"])
    }

    public func npmInstall(handle: BrokerHandleID, package: String, version: String?) throws -> URL {
        let h = try resolve(handle, kind: "npm", op: "install")
        guard isNPMAllowed(package: package, version: version) else {
            throw BrokerError.npmDenied(package)
        }
        // No lifecycle scripts: materialize a lockfile-style stub package dir (real install optional via allowlist).
        let dest = config.toolCacheRoot
            .appendingPathComponent(h.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent("npm")
            .appendingPathComponent(package)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let meta = """
        {"name":"\(package)","version":"\(version ?? "*")","scripts_disabled":true}
        """
        try meta.write(to: dest.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
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
                "data_b64": data?.base64EncodedString() as Any,
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

    private func resolveWorktreePath(_ extensionID: ExtensionID, relative: String) throws -> URL {
        _ = extensionID
        guard let root = config.worktreeRoots.first else {
            throw BrokerError.notFound("no worktree root")
        }
        let cleaned = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.contains("..") { throw BrokerError.pathEscape }
        let url = cleaned.isEmpty ? root : root.appendingPathComponent(cleaned)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path != rootResolved.path && !resolved.path.hasPrefix(rootResolved.path + "/") {
            throw BrokerError.pathEscape
        }
        return resolved
    }

    private func storageURL(extensionID: ExtensionID, key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return config.storageRoot
            .appendingPathComponent(extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(safe)
    }

    private func isProcessAllowed(executable: String, arguments: [String]) -> Bool {
        for allow in config.processAllowlist {
            if allow.command == executable || allow.command == "**" {
                if allow.argsGlob == ["**"] { return true }
                // simple equality check when not **
                if allow.argsGlob == arguments { return true }
            }
            // basename match
            if URL(fileURLWithPath: executable).lastPathComponent == allow.command {
                return allow.argsGlob == ["**"] || allow.argsGlob == arguments
            }
        }
        return false
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
        return String(data.count)
        #endif
    }
}
