import Foundation
import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensions

/// UI-free manager model for workbench / settings screens.
@MainActor
public final class ExtensionManagerModel {
    public private(set) var rows: [RemoteExtensionStatus] = []
    public private(set) var trustItems: [ExtensionTrustStatusItem] = []
    public private(set) var pendingTrustPrompts: [TrustPromptDescriptor] = []
    public private(set) var hostProfile: ExtensionHostProfile
    public private(set) var runnability: [ArtifactRunnabilityDescriptor] = []
    private let host: RemoteExtensionHost
    private var storeManager: ExtensionPackageManager?

    public init(host: RemoteExtensionHost, hostProfile: ExtensionHostProfile = .shipping(.test)) {
        self.host = host
        self.hostProfile = hostProfile
    }

    /// Optional local store for trust status / prompts (Phase 14 descriptors).
    public func attachStore(_ manager: ExtensionPackageManager) {
        storeManager = manager
    }

    public func setHostProfile(_ profile: ExtensionHostProfile) {
        hostProfile = profile
    }

    public func reload() async {
        rows = await host.statuses()
        if let manager = storeManager {
            trustItems = await manager.trustStatusItems()
            pendingTrustPrompts = []
            for item in trustItems where !item.quarantined {
                if let prompt = await manager.trustPromptIfNeeded(for: ExtensionID(rawValue: item.packageID)!) {
                    pendingTrustPrompts.append(prompt)
                }
            }
        } else {
            trustItems = []
            pendingTrustPrompts = []
        }
        runnability = rows.map { row in
            ArtifactRunnability.evaluate(
                packageID: row.id.rawValue,
                origin: .installed,
                requestedRuntime: .nativeProcess,
                hostProfile: hostProfile,
                hasRemoteDescriptor: true
            )
        }
    }

    public func runnability(
        packageID: String,
        origin: ExtensionArtifactOrigin,
        runtime: ExtensionRuntimeKindDTO,
        hasRemoteDescriptor: Bool = false
    ) -> ArtifactRunnabilityDescriptor {
        ArtifactRunnability.evaluate(
            packageID: packageID,
            origin: origin,
            requestedRuntime: runtime,
            hostProfile: hostProfile,
            hasRemoteDescriptor: hasRemoteDescriptor
        )
    }

    public func start(id: ExtensionID) async throws {
        try await host.start(id: id)
        await reload()
    }

    public func stop(id: ExtensionID) async {
        await host.stop(id: id)
        await reload()
    }

    public func restart(id: ExtensionID) async throws {
        try await host.restart(id: id)
        await reload()
    }

    public func toggle(id: ExtensionID) async throws {
        let current = rows.first(where: { $0.id == id })
        if current?.processState == .running {
            await stop(id: id)
        } else {
            try await start(id: id)
        }
    }
}
