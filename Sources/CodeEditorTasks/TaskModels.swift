import Foundation

public struct TaskID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct ProblemMatcherID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum TaskGroup: String, Sendable, Hashable, Codable {
    case build
    case test
    case none
}

public enum TaskExecutionKind: String, Sendable, Hashable, Codable {
    case direct
    case shell
}

public enum TaskPresentationReveal: String, Sendable, Hashable, Codable {
    case always
    case silent
    case onProblem
}

public struct TaskPresentation: Sendable, Hashable, Codable {
    public var reveal: TaskPresentationReveal
    public var echo: Bool
    public var focus: Bool
    public var panel: String?

    public init(
        reveal: TaskPresentationReveal = .always,
        echo: Bool = true,
        focus: Bool = false,
        panel: String? = nil
    ) {
        self.reveal = reveal
        self.echo = echo
        self.focus = focus
        self.panel = panel
    }
}

public struct TaskDefinition: Sendable, Hashable {
    public var id: TaskID
    public var label: String
    public var executable: String
    public var arguments: [String]
    public var cwd: URL?
    public var environment: [String: String]
    public var dependsOn: [TaskID]
    public var problemMatchers: [ProblemMatcherID]
    public var group: TaskGroup
    public var execution: TaskExecutionKind
    public var presentation: TaskPresentation
    /// Serialize tasks sharing this non-nil group name.
    public var concurrencyGroup: String?
    /// When true, no other task in the same concurrency group may run concurrently.
    public var isExclusive: Bool
    /// When true, do not block dependents until readiness matcher matches (background).
    public var isBackground: Bool
    /// Regex that marks a background task ready.
    public var readinessPattern: String?
    public var timeout: Duration?
    /// Variable map overrides (`workspaceFolder`, custom keys).
    public var variables: [String: String]
    /// Typed prelaunch/post-debug hooks (metadata only; no UI).
    public var runOptions: [String: String]

    public init(
        id: TaskID,
        label: String,
        executable: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        dependsOn: [TaskID] = [],
        problemMatchers: [ProblemMatcherID] = [],
        group: TaskGroup = .none,
        execution: TaskExecutionKind = .direct,
        presentation: TaskPresentation = TaskPresentation(),
        concurrencyGroup: String? = nil,
        isExclusive: Bool = false,
        isBackground: Bool = false,
        readinessPattern: String? = nil,
        timeout: Duration? = nil,
        variables: [String: String] = [:],
        runOptions: [String: String] = [:],
        useShell: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.dependsOn = dependsOn
        self.problemMatchers = problemMatchers
        self.group = group
        if let useShell {
            self.execution = useShell ? .shell : .direct
        } else {
            self.execution = execution
        }
        self.presentation = presentation
        self.concurrencyGroup = concurrencyGroup
        self.isExclusive = isExclusive
        self.isBackground = isBackground
        self.readinessPattern = readinessPattern
        self.timeout = timeout
        self.variables = variables
        self.runOptions = runOptions
    }

    /// Backward-compatible alias.
    public var useShell: Bool {
        get { execution == .shell }
        set { execution = newValue ? .shell : .direct }
    }
}

public enum TaskRunState: String, Sendable, Hashable, Codable {
    case queued
    case starting
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut
}

public struct TaskRun: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var definitionID: TaskID
    public var state: TaskRunState
    public var exitCode: Int?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        definitionID: TaskID,
        state: TaskRunState = .queued,
        exitCode: Int? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.definitionID = definitionID
        self.state = state
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct TaskRunResult: Sendable {
    public var run: TaskRun
    public var stdout: String
    public var stderr: String

    public init(run: TaskRun, stdout: String, stderr: String) {
        self.run = run
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum TaskOutputStream: String, Sendable, Hashable, Codable {
    case stdout
    case stderr
}

public enum TaskOutputEvent: Sendable, Hashable {
    case stdout(String)
    case stderr(String)
    /// Bounded spool overflow: delivered once per stream when the cap is first exceeded (TASK-N03).
    case outputTruncated(stream: TaskOutputStream, droppedBytes: Int)
    case ready
    case completed(TaskRun)
}

/// Explicit DAG node outcome (TASK-N06) — dependents never launch merely because wait returned.
public enum TaskNodeOutcome: Sendable, Hashable {
    case succeeded
    case failed(TaskFailure)
    case cancelled
    case skippedBecauseDependency(TaskID)

    public var isFailureOrSkip: Bool {
        switch self {
        case .succeeded: return false
        case .failed, .cancelled, .skippedBecauseDependency: return true
        }
    }

    public var allowsDependents: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

public enum TaskFailure: Sendable, Hashable {
    case exitCode(Int)
    case timedOut
    case processFailed(String)
    case invalidDefinition(String)
    case notReady(TaskID)
    case concurrencyConflict(String)
}

/// Result of executing a task graph with per-node outcomes (TASK-N06).
public struct TaskGraphReport: Sendable {
    public var root: TaskID
    public var order: [TaskID]
    public var outcomes: [TaskID: TaskNodeOutcome]
    /// Live handle for the root when it was launched; nil when root was skipped/failed before launch.
    public var rootHandle: TaskExecutionHandle?

    public init(
        root: TaskID,
        order: [TaskID],
        outcomes: [TaskID: TaskNodeOutcome],
        rootHandle: TaskExecutionHandle? = nil
    ) {
        self.root = root
        self.order = order
        self.outcomes = outcomes
        self.rootHandle = rootHandle
    }

    public var rootOutcome: TaskNodeOutcome {
        outcomes[root] ?? .failed(.invalidDefinition("missing root outcome"))
    }
}

public enum TaskError: Error, Sendable, Equatable {
    case notFound(String)
    case dependencyCycle([String])
    case dependencyFailed(String)
    case cancelled
    case processFailed(String)
    case timedOut
    case invalidDefinition(String)
    case concurrencyConflict(String)
}

extension TaskError {
    /// Validate readiness regex at definition/launch time (TASK-N05). Throws source-located config error.
    public static func validateReadinessPattern(_ pattern: String?) throws -> NSRegularExpression? {
        guard let pattern else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            throw TaskError.invalidDefinition(
                "invalid readinessPattern: \(pattern) (\(error.localizedDescription))"
            )
        }
    }
}

// MARK: - Variable resolution

public enum TaskVariableResolver {
    /// Resolve `${name}` placeholders. Unresolved names throw (TASK-004 / §18.8).
    public static func resolve(
        _ text: String,
        variables: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowEmpty: Bool = false
    ) throws -> String {
        var result = text
        let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_.-]+)\}"#, options: [])
        let ns = result as NSString
        let matches = pattern.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let key = ns.substring(with: match.range(at: 1))
            if let value = variables[key] ?? environment[key] {
                result = (result as NSString).replacingCharacters(in: match.range, with: value)
            } else if allowEmpty {
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
            } else {
                throw TaskError.invalidDefinition("unresolved variable: \(key)")
            }
        }
        return result
    }

    public static func resolveDefinition(
        _ definition: TaskDefinition,
        extraVariables: [String: String] = [:]
    ) throws -> TaskDefinition {
        var vars = definition.variables
        for (k, v) in extraVariables { vars[k] = v }
        if let cwd = definition.cwd {
            vars["workspaceFolder"] = vars["workspaceFolder"] ?? cwd.path
        }
        var copy = definition
        copy.executable = try resolve(definition.executable, variables: vars)
        copy.arguments = try definition.arguments.map { try resolve($0, variables: vars) }
        var env: [String: String] = [:]
        for (k, v) in definition.environment {
            env[try resolve(k, variables: vars)] = try resolve(v, variables: vars)
        }
        copy.environment = env
        return copy
    }
}
