import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorTasks
import Foundation
import Observation

/// Fail-closed workflow errors (WB-N06).
public enum WorkbenchWorkflowError: Error, Sendable, Equatable {
    case serviceUnavailable(String)
    case schemeActionFailed(String)
}

/// Binds production services to advertised workbench workflows (WB-N06).
///
/// Hosts inject ``TaskService`` / ``SourceControlService``; the workbench never
/// invents fake build/SCM results. Missing bindings fail closed.
@MainActor
@Observable
public final class WorkbenchWorkflowCoordinator {
    public private(set) var taskService: TaskService?
    public private(set) var sourceControl: SourceControlService?
    /// Optional problem matchers used when ingesting task output into the problems bridge.
    public var problemMatchers: [ProblemMatcher] = []

    public init() {
        if let swift = try? ProblemMatcher.swiftCompiler() {
            problemMatchers = [swift]
        }
    }

    public func bind(taskService: TaskService) {
        self.taskService = taskService
    }

    public func bind(sourceControl: SourceControlService) {
        self.sourceControl = sourceControl
    }

    /// Run the selected scheme action through production ``TaskService``.
    @discardableResult
    public func runSchemeAction(
        _ action: WorkbenchSchemeModel.SchemeAction,
        model: WorkbenchModel
    ) async throws -> TaskGraphReport {
        guard let tasks = taskService else {
            let message = "TaskService is not bound"
            model.schemes.recordError(message)
            throw WorkbenchWorkflowError.serviceUnavailable(message)
        }

        let taskIDString: String
        do {
            taskIDString = try model.schemes.taskID(for: action)
        } catch {
            model.schemes.recordError(String(describing: error))
            throw WorkbenchWorkflowError.schemeActionFailed(String(describing: error))
        }

        let activityID = "scheme.\(action.rawValue)"
        model.activity.begin(id: activityID, title: "\(action.rawValue.capitalized)…")
        defer { model.activity.end(id: activityID) }

        if action == .test {
            model.tests.markRunning(taskID: taskIDString)
        }

        let taskID = TaskID(rawValue: taskIDString)
        do {
            let report = try await tasks.executeGraph(id: taskID)
            if let handle = report.rootHandle {
                await ingestProblems(from: handle, model: model)
            }
            switch report.rootOutcome {
            case .succeeded, .skippedBecauseDependency:
                break
            case .cancelled:
                model.schemes.recordError("cancelled")
            case .failed(let failure):
                model.schemes.recordError(String(describing: failure))
            }
            return report
        } catch {
            model.schemes.recordError(String(describing: error))
            throw error
        }
    }

    /// Refresh SCM status via production ``SourceControlService``.
    public func refreshSCM(model: WorkbenchModel) async throws {
        guard let scm = sourceControl else {
            let message = "SourceControlService is not bound"
            model.scmModel.recordError(message)
            throw WorkbenchWorkflowError.serviceUnavailable(message)
        }
        do {
            let statuses = try await scm.refresh()
            model.scmModel.applyStatuses(statuses)
        } catch {
            model.scmModel.recordError(String(describing: error))
            throw error
        }
    }

    private func ingestProblems(from handle: TaskExecutionHandle, model: WorkbenchModel) async {
        guard !problemMatchers.isEmpty else { return }
        let text = handle.collectedStdout + "\n" + handle.collectedStderr
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let problems = ProblemMatcherEngine.matchAll(
            text: text,
            matchers: problemMatchers,
            cwd: nil,
            workspaceRoot: nil
        )
        guard !problems.isEmpty else { return }
        model.problemsBridge.ingest(matched: problems, runID: handle.runID.uuidString)
    }
}
