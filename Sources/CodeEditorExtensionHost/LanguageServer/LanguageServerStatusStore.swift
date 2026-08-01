import Foundation
import CodeEditorExtensionAPI

public actor LanguageServerStatusStore {
    public private(set) var statuses: [String: LanguageServerStatus] = [:]
    private var continuation: AsyncStream<LanguageServerStatus>.Continuation?
    public let updates: AsyncStream<LanguageServerStatus>
    private var diagnostics: [LanguageServerDiagnostic] = []

    public init() {
        var cont: AsyncStream<LanguageServerStatus>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func set(_ status: LanguageServerStatus) {
        statuses[status.id] = status
        continuation?.yield(status)
    }

    public func status(serverID: String, extensionID: ExtensionID) -> LanguageServerStatus? {
        statuses["\(extensionID.rawValue)::\(serverID)"]
    }

    public func all() -> [LanguageServerStatus] {
        statuses.values.sorted { $0.id < $1.id }
    }

    public func recordDiagnostic(_ d: LanguageServerDiagnostic) {
        diagnostics.append(d)
    }

    public func allDiagnostics() -> [LanguageServerDiagnostic] {
        diagnostics
    }

    public func clear(extensionID: ExtensionID) {
        for key in statuses.keys where key.hasPrefix(extensionID.rawValue + "::") {
            statuses.removeValue(forKey: key)
        }
    }
}
