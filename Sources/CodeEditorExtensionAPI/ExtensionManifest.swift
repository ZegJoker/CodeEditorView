import Foundation

/// When an extension becomes eligible for activation.
public enum ExtensionActivationEvent: Hashable, Codable, Sendable {
    case startup
    case workspaceOpened
    case language(String)
    case command(String)
    case fileMatch(pattern: String)
    case view(String)
    case manual

    /// Whether this event matches a fired host event (language/fileMatch are case-insensitive).
    public func matches(_ other: ExtensionActivationEvent) -> Bool {
        switch (self, other) {
        case (.startup, .startup),
             (.workspaceOpened, .workspaceOpened),
             (.manual, .manual):
            return true
        case let (.language(a), .language(b)):
            return a.lowercased() == b.lowercased()
        case let (.command(a), .command(b)):
            return a == b
        case let (.view(a), .view(b)):
            return a == b
        case let (.fileMatch(pattern), .fileMatch(path)):
            return filePattern(pattern, matches: path)
        default:
            return false
        }
    }

    private func filePattern(_ pattern: String, matches path: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2)).lowercased()
            return (path as NSString).pathExtension.lowercased() == ext
        }
        if pattern.hasPrefix("*") {
            return path.lowercased().hasSuffix(String(pattern.dropFirst()).lowercased())
        }
        return path.localizedCaseInsensitiveContains(pattern)
    }
}

/// Host services an extension may require.
public enum HostCapability: String, Hashable, Codable, Sendable, CaseIterable {
    case commands
    case keybindings
    case languages
    case languageServices
    case panels
    case themes
    case snippets
    case storage
}

/// Privileges an extension may request; hosts grant a subset.
public enum ExtensionPermission: String, Hashable, Codable, Sendable, CaseIterable {
    case readWorkspace
    case writeWorkspace
    case accessOutsideWorkspace
    case startProcesses
    case network
    case terminal
    case sourceControlMutate
    case clipboard
    case presentUI
}

public struct ExtensionManifest: Hashable, Codable, Sendable {
    public var id: ExtensionID
    public var displayName: String
    public var version: SemanticVersion
    public var requiredAPIVersion: VersionRange
    public var activationEvents: [ExtensionActivationEvent]
    public var requiredHostCapabilities: Set<HostCapability>
    public var requestedPermissions: Set<ExtensionPermission>

    public init(
        id: ExtensionID,
        displayName: String,
        version: SemanticVersion = SemanticVersion(major: 1),
        requiredAPIVersion: VersionRange = .from(.phase9API),
        activationEvents: [ExtensionActivationEvent] = [.startup],
        requiredHostCapabilities: Set<HostCapability> = [],
        requestedPermissions: Set<ExtensionPermission> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.requiredAPIVersion = requiredAPIVersion
        self.activationEvents = activationEvents
        self.requiredHostCapabilities = requiredHostCapabilities
        self.requestedPermissions = requestedPermissions
    }
}

/// Host-published environment for capability and permission negotiation.
public struct HostEnvironment: Sendable {
    public var apiVersion: SemanticVersion
    public var capabilities: Set<HostCapability>
    /// Global grant mask; actual grants are intersection with each extension's requests
    /// unless a per-extension override is supplied at registration time.
    public var grantedPermissions: Set<ExtensionPermission>

    public init(
        apiVersion: SemanticVersion = .phase9API,
        capabilities: Set<HostCapability> = Set(HostCapability.allCases),
        grantedPermissions: Set<ExtensionPermission> = Set(ExtensionPermission.allCases)
    ) {
        self.apiVersion = apiVersion
        self.capabilities = capabilities
        self.grantedPermissions = grantedPermissions
    }

    public static let full = HostEnvironment()

    public static var minimal: HostEnvironment {
        HostEnvironment(
            capabilities: [.commands, .storage],
            grantedPermissions: []
        )
    }
}

public enum ExtensionError: Error, Sendable, Equatable {
    case incompatibleAPI(required: String, host: String)
    case missingCapabilities(Set<HostCapability>)
    case permissionDenied(ExtensionPermission)
    case alreadyActive
    case notRegistered
    case notActive
    case activationFailed(String)
    case storagePathEscape
    case dataLoad(String)
}
