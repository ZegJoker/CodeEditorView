import CodeEditorCore
import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorTasks
import Foundation
import Observation

// MARK: - Problems ingest from tasks (WB-007)

@MainActor
@Observable
public final class WorkbenchTaskProblemsBridge {
    public private(set) var problems: [WorkbenchProblemsPanelModel.Item] = []

    public init() {}

    public func ingest(matched: [MatchedProblem], runID: String) {
        var items: [WorkbenchProblemsPanelModel.Item] = []
        for (idx, m) in matched.enumerated() {
            items.append(
                WorkbenchProblemsPanelModel.Item(
                    id: "\(runID):\(idx)",
                    severity: m.diagnostic.severity == .warning ? "warning" : "error",
                    message: m.diagnostic.message,
                    path: m.path,
                    line: m.position.line,
                    column: m.position.column
                )
            )
        }
        problems = items
    }

    public func clear() { problems = [] }
}

// MARK: - SCM model (WB-007)

@MainActor
@Observable
public final class WorkbenchSCMModel {
    public private(set) var statuses: [SCMFileStatus] = []
    public private(set) var errorMessage: String?
    public var trusted: Bool = false

    public init() {}

    public func refresh(provider: any SourceControlProvider) async {
        do {
            if let git = provider as? GitCLIProvider {
                git.trusted = trusted
            }
            statuses = try await provider.status()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            statuses = []
        }
    }
}

// MARK: - Debug session list model (WB-007)

public struct WorkbenchDebugSessionInfo: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var state: String

    public init(id: String, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
}

@MainActor
@Observable
public final class WorkbenchDebugModel {
    public private(set) var sessions: [WorkbenchDebugSessionInfo] = []

    public init() {}

    public func upsert(id: String, name: String, state: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx] = WorkbenchDebugSessionInfo(id: id, name: name, state: state)
        } else {
            sessions.append(WorkbenchDebugSessionInfo(id: id, name: name, state: state))
        }
    }

    public func remove(id: String) {
        sessions.removeAll { $0.id == id }
    }

    public func clear() { sessions = [] }
}
