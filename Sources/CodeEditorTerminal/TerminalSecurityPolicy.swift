import Foundation

/// Host-owned terminal security policy (audit §21.10 / TER-007).
public struct TerminalSecurityPolicy: Sendable, Hashable {
    public enum ClipboardPolicy: String, Sendable, Hashable, Codable {
        case deny
        case prompt
        case allow
    }

    public var allowLocalPTY: Bool
    public var allowShellIntegrationInjection: Bool
    public var osc52Clipboard: ClipboardPolicy
    public var allowHyperlinkOpen: Bool
    public var workspaceTrusted: Bool

    public init(
        allowLocalPTY: Bool = true,
        allowShellIntegrationInjection: Bool = false,
        osc52Clipboard: ClipboardPolicy = .deny,
        allowHyperlinkOpen: Bool = true,
        workspaceTrusted: Bool = false
    ) {
        self.allowLocalPTY = allowLocalPTY
        self.allowShellIntegrationInjection = allowShellIntegrationInjection
        self.osc52Clipboard = osc52Clipboard
        self.allowHyperlinkOpen = allowHyperlinkOpen
        self.workspaceTrusted = workspaceTrusted
    }

    /// Fail-closed defaults for restricted workspaces.
    public static let restricted = TerminalSecurityPolicy(
        allowLocalPTY: true,
        allowShellIntegrationInjection: false,
        osc52Clipboard: .deny,
        allowHyperlinkOpen: false,
        workspaceTrusted: false
    )

    public static let trusted = TerminalSecurityPolicy(
        allowLocalPTY: true,
        allowShellIntegrationInjection: true,
        osc52Clipboard: .prompt,
        allowHyperlinkOpen: true,
        workspaceTrusted: true
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
}
