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

public enum TaskOutputEvent: Sendable, Hashable {
    case stdout(String)
    case stderr(String)
    case ready
    case completed(TaskRun)
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

// MARK: - Variable resolution

public enum TaskVariableResolver {
    public static func resolve(
        _ text: String,
        variables: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var result = text
        // ${workspaceFolder} style
        let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_.-]+)\}"#, options: [])
        let ns = result as NSString
        let matches = pattern.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let key = ns.substring(with: match.range(at: 1))
            let value = variables[key] ?? environment[key] ?? ""
            result = (result as NSString).replacingCharacters(in: match.range, with: value)
        }
        return result
    }

    public static func resolveDefinition(
        _ definition: TaskDefinition,
        extraVariables: [String: String] = [:]
    ) -> TaskDefinition {
        var vars = definition.variables
        for (k, v) in extraVariables { vars[k] = v }
        if let cwd = definition.cwd {
            vars["workspaceFolder"] = vars["workspaceFolder"] ?? cwd.path
        }
        var copy = definition
        copy.executable = resolve(definition.executable, variables: vars)
        copy.arguments = definition.arguments.map { resolve($0, variables: vars) }
        var env: [String: String] = [:]
        for (k, v) in definition.environment {
            env[resolve(k, variables: vars)] = resolve(v, variables: vars)
        }
        copy.environment = env
        return copy
    }
}
