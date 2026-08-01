import Foundation

public enum LanguageServerLifecycleState: String, Sendable, Hashable, Codable {
    case idle
    case resolving
    case installing
    case starting
    case running
    case failed
    case stopped
}

public struct LanguageServerStatus: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(extensionID.rawValue)::\(serverID)" }
    public var serverID: String
    public var extensionID: ExtensionID
    public var state: LanguageServerLifecycleState
    public var message: String?
    public var progress: Double?
    public var lastError: String?
    public var binaryPath: String?
    public var updatedAt: Date

    public init(
        serverID: String,
        extensionID: ExtensionID,
        state: LanguageServerLifecycleState,
        message: String? = nil,
        progress: Double? = nil,
        lastError: String? = nil,
        binaryPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.serverID = serverID
        self.extensionID = extensionID
        self.state = state
        self.message = message
        self.progress = progress
        self.lastError = lastError
        self.binaryPath = binaryPath
        self.updatedAt = updatedAt
    }
}

public enum LanguageServerDiagnosticCode: String, Sendable, Hashable, Codable {
    case binaryNotFound = "ls.binary_not_found"
    case downloadDenied = "ls.download_denied"
    case npmDenied = "ls.npm_denied"
    case spawnFailed = "ls.spawn_failed"
    case initializeFailed = "ls.initialize_failed"
    case pathEscape = "ls.path_escape"
    case processDenied = "ls.process_denied"
    case platformDenied = "ls.platform_denied"
    case planInvalid = "ls.plan_invalid"
}

public struct LanguageServerDiagnostic: Sendable, Hashable, Codable {
    public var code: LanguageServerDiagnosticCode
    public var message: String
    public var serverID: String?
    public var extensionID: ExtensionID?

    public init(
        code: LanguageServerDiagnosticCode,
        message: String,
        serverID: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.code = code
        self.message = message
        self.serverID = serverID
        self.extensionID = extensionID
    }

    public func asPackageDiagnostic() -> ExtensionPackageDiagnostic {
        ExtensionPackageDiagnostic(
            code: code.rawValue,
            severity: .error,
            message: message,
            path: serverID
        )
    }
}
