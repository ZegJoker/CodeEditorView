import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensions

/// UI-free manager model for workbench / settings screens.
@MainActor
public final class ExtensionManagerModel {
    public private(set) var rows: [RemoteExtensionStatus] = []
    public private(set) var trustItems: [ExtensionTrustStatusItem] = []
    public private(set) var pendingTrustPrompts: [TrustPromptDescriptor] = []
    private let host: RemoteExtensionHost
    private var storeManager: ExtensionPackageManager?

    public init(host: RemoteExtensionHost) {
        self.host = host
    }

    /// Optional local store for trust status / prompts (Phase 14 descriptors).
    public func attachStore(_ manager: ExtensionPackageManager) {
        storeManager = manager
    }

    public func reload() async {
        rows = await host.statuses()
        if let manager = storeManager {
            trustItems = await manager.trustStatusItems()
            pendingTrustPrompts = []
            for item in trustItems where !item.quarantined {
                if let prompt = await manager.trustPromptIfNeeded(for: ExtensionID(rawValue: item.packageID)) {
                    pendingTrustPrompts.append(prompt)
                }
            }
        } else {
            trustItems = []
            pendingTrustPrompts = []
        }
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
