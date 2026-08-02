import Foundation

/// Host-owned terminal security policy (audit §21.10 / TER-N08).
public struct TerminalSecurityPolicy: Sendable, Hashable {
    public enum ClipboardPolicy: String, Sendable, Hashable, Codable {
        case deny
        case prompt
        case allow
    }

    public enum FileTransferPolicy: String, Sendable, Hashable, Codable {
        case deny
        case prompt
        case allow
    }

    public enum NotificationPolicy: String, Sendable, Hashable, Codable {
        case deny
        case prompt
        case allow
    }

    /// Named deployment profiles (TER-N08).
    public enum Profile: String, Sendable, Hashable, Codable {
        /// macOS direct distribution: local PTY under host policy.
        case macOSDirect
        /// Mac App Store: host entitlement constraints; PTY may be restricted.
        case macAppStore
        /// iOS: no local arbitrary process; remote transport only.
        case iOS
        /// Extension sandboxed access: no ambient terminal create.
        case extensionSandbox
        /// Fail-closed workspace defaults.
        case restricted
        /// Trusted developer workspace.
        case trusted
    }

    /// Explicit extension capabilities — never ambient (TER-N08).
    public struct ExtensionCapabilities: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let create = ExtensionCapabilities(rawValue: 1 << 0)
        public static let write = ExtensionCapabilities(rawValue: 1 << 1)
        public static let read = ExtensionCapabilities(rawValue: 1 << 2)
        public static let resize = ExtensionCapabilities(rawValue: 1 << 3)
        public static let terminate = ExtensionCapabilities(rawValue: 1 << 4)

        public static let none: ExtensionCapabilities = []
        public static let all: ExtensionCapabilities = [.create, .write, .read, .resize, .terminate]
    }

    public var allowLocalPTY: Bool
    public var allowRemoteTransport: Bool
    public var allowShellIntegrationInjection: Bool
    public var osc52Clipboard: ClipboardPolicy
    public var allowHyperlinkOpen: Bool
    public var allowOSCFileTransfer: Bool
    public var desktopNotifications: NotificationPolicy
    public var fileTransfer: FileTransferPolicy
    public var workspaceTrusted: Bool
    public var extensionCapabilities: ExtensionCapabilities
    public var profile: Profile

    public init(
        allowLocalPTY: Bool = true,
        allowRemoteTransport: Bool = true,
        allowShellIntegrationInjection: Bool = false,
        osc52Clipboard: ClipboardPolicy = .deny,
        allowHyperlinkOpen: Bool = true,
        allowOSCFileTransfer: Bool = false,
        desktopNotifications: NotificationPolicy = .deny,
        fileTransfer: FileTransferPolicy = .deny,
        workspaceTrusted: Bool = false,
        extensionCapabilities: ExtensionCapabilities = .none,
        profile: Profile = .restricted
    ) {
        self.allowLocalPTY = allowLocalPTY
        self.allowRemoteTransport = allowRemoteTransport
        self.allowShellIntegrationInjection = allowShellIntegrationInjection
        self.osc52Clipboard = osc52Clipboard
        self.allowHyperlinkOpen = allowHyperlinkOpen
        self.allowOSCFileTransfer = allowOSCFileTransfer
        self.desktopNotifications = desktopNotifications
        self.fileTransfer = fileTransfer
        self.workspaceTrusted = workspaceTrusted
        self.extensionCapabilities = extensionCapabilities
        self.profile = profile
    }

    /// Build a policy for a named deployment profile (TER-N08).
    public static func forProfile(_ profile: Profile) -> TerminalSecurityPolicy {
        switch profile {
        case .macOSDirect:
            return TerminalSecurityPolicy(
                allowLocalPTY: true,
                allowRemoteTransport: true,
                allowShellIntegrationInjection: true,
                osc52Clipboard: .prompt,
                allowHyperlinkOpen: true,
                allowOSCFileTransfer: false,
                desktopNotifications: .prompt,
                fileTransfer: .prompt,
                workspaceTrusted: true,
                extensionCapabilities: .none,
                profile: .macOSDirect
            )
        case .macAppStore:
            return TerminalSecurityPolicy(
                allowLocalPTY: false,
                allowRemoteTransport: true,
                allowShellIntegrationInjection: false,
                osc52Clipboard: .deny,
                allowHyperlinkOpen: false,
                allowOSCFileTransfer: false,
                desktopNotifications: .deny,
                fileTransfer: .deny,
                workspaceTrusted: false,
                extensionCapabilities: .none,
                profile: .macAppStore
            )
        case .iOS:
            return TerminalSecurityPolicy(
                allowLocalPTY: false,
                allowRemoteTransport: true,
                allowShellIntegrationInjection: false,
                osc52Clipboard: .deny,
                allowHyperlinkOpen: false,
                allowOSCFileTransfer: false,
                desktopNotifications: .deny,
                fileTransfer: .deny,
                workspaceTrusted: false,
                extensionCapabilities: .none,
                profile: .iOS
            )
        case .extensionSandbox:
            return TerminalSecurityPolicy(
                allowLocalPTY: false,
                allowRemoteTransport: false,
                allowShellIntegrationInjection: false,
                osc52Clipboard: .deny,
                allowHyperlinkOpen: false,
                allowOSCFileTransfer: false,
                desktopNotifications: .deny,
                fileTransfer: .deny,
                workspaceTrusted: false,
                extensionCapabilities: .none,
                profile: .extensionSandbox
            )
        case .restricted:
            return .restricted
        case .trusted:
            return .trusted
        }
    }

    /// Fail-closed defaults for restricted workspaces.
    public static let restricted = TerminalSecurityPolicy(
        allowLocalPTY: true,
        allowRemoteTransport: true,
        allowShellIntegrationInjection: false,
        osc52Clipboard: .deny,
        allowHyperlinkOpen: false,
        allowOSCFileTransfer: false,
        desktopNotifications: .deny,
        fileTransfer: .deny,
        workspaceTrusted: false,
        extensionCapabilities: .none,
        profile: .restricted
    )

    public static let trusted = TerminalSecurityPolicy(
        allowLocalPTY: true,
        allowRemoteTransport: true,
        allowShellIntegrationInjection: true,
        osc52Clipboard: .prompt,
        allowHyperlinkOpen: true,
        allowOSCFileTransfer: false,
        desktopNotifications: .prompt,
        fileTransfer: .prompt,
        workspaceTrusted: true,
        extensionCapabilities: .none,
        profile: .trusted
    )

    public func allowsShellIntegrationInjection() -> Bool {
        workspaceTrusted && allowShellIntegrationInjection
    }

    public func allowsOSC52Write() -> Bool {
        switch osc52Clipboard {
        case .allow: return true
        case .prompt, .deny: return false
        }
    }

    public func allowsHyperlinks() -> Bool {
        allowHyperlinkOpen && workspaceTrusted
    }

    public func allowsDesktopNotifications() -> Bool {
        switch desktopNotifications {
        case .allow: return true
        case .prompt, .deny: return false
        }
    }

    public func allowsFileTransfer() -> Bool {
        switch fileTransfer {
        case .allow: return allowOSCFileTransfer
        case .prompt, .deny: return false
        }
    }

    public func extensionAllows(_ capability: ExtensionCapabilities) -> Bool {
        extensionCapabilities.contains(capability)
    }

    /// Fail closed when an extension requests a capability it was not granted.
    public func requireExtensionCapability(_ capability: ExtensionCapabilities) throws {
        guard extensionAllows(capability) else {
            throw TerminalError.startFailed(
                "extension terminal capability denied: \(capability.rawValue)"
            )
        }
    }
}
