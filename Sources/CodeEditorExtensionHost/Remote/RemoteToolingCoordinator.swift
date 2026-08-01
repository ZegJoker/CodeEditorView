import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensionAPI
import CodeEditorExtensions
import CodeEditorLanguageServices

/// Selects remote tooling when local process/LSP capabilities are not available.
///
/// Fail-closed: does not spawn local processes when the platform profile denies them.
public struct RemoteToolingCoordinator: Sendable {
    public var platformProfile: PlatformCapabilityProfile

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
    }

    public enum LocalLaunchDecision: Sendable, Equatable {
        case allowLocal
        case useRemoteFallback(reason: String)
        case deny(reason: String)
    }

    /// Whether a local language-server process may be started.
    public func languageServerLaunchDecision() -> LocalLaunchDecision {
        switch platformProfile.availability(for: .localLanguageServerProcess) {
        case .local:
            return .allowLocal
        case .remote:
            if platformProfile.remoteToolingAvailable {
                return .useRemoteFallback(reason: "localLanguageServerProcess is remote-only on \(platformProfile.name)")
            }
            return .deny(reason: "remote tooling not available for language servers")
        case .hostProvided:
            return .deny(reason: "host must provide language server implementation")
        case .dataOnly:
            return .deny(reason: "language server is data-only on this profile")
        case let .unavailable(reason):
            if platformProfile.remoteToolingAvailable {
                return .useRemoteFallback(reason: reason)
            }
            return .deny(reason: reason)
        }
    }

    /// Whether a generic local process may start.
    public func processLaunchDecision() -> LocalLaunchDecision {
        switch platformProfile.availability(for: .localProcess) {
        case .local:
            return .allowLocal
        case .remote:
            if platformProfile.remoteToolingAvailable {
                return .useRemoteFallback(reason: "localProcess is remote-only")
            }
            return .deny(reason: "localProcess remote without remote tooling")
        case let .unavailable(reason):
            if platformProfile.remoteToolingAvailable {
                return .useRemoteFallback(reason: reason)
            }
            return .deny(reason: reason)
        default:
            return .deny(reason: "localProcess not available")
        }
    }

    /// Register remote language-service providers for a live remote process (shared path with tests).
    public func registerRemoteLanguageServices(
        process: RemoteExtensionProcess,
        extensionID: ExtensionID,
        into registry: LanguageServiceRegistry
    ) async -> RemoteProviderRegistration {
        await RemoteLanguageServiceProviders.register(
            process: process,
            extensionID: extensionID,
            into: registry
        )
    }
}
