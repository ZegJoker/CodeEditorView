import Foundation
import CodeEditorExtensions

/// UI-free manager model for workbench / settings screens.
@MainActor
public final class ExtensionManagerModel {
    public private(set) var rows: [RemoteExtensionStatus] = []
    private let host: RemoteExtensionHost

    public init(host: RemoteExtensionHost) {
        self.host = host
    }

    public func reload() async {
        rows = await host.statuses()
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
