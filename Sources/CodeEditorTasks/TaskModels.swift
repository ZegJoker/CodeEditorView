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

public struct TaskDefinition: Sendable, Hashable, Codable {
    public var id: TaskID
    public var label: String
    public var executable: String
    public var arguments: [String]
    public var cwd: URL?
    public var environment: [String: String]
    public var dependsOn: [TaskID]
    public var problemMatchers: [ProblemMatcherID]
    public var group: TaskGroup
    public var useShell: Bool

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
        useShell: Bool = false
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
        self.useShell = useShell
    }
}

public enum TaskRunState: String, Sendable, Hashable, Codable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
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

public enum TaskError: Error, Sendable, Equatable {
    case notFound(String)
    case dependencyCycle([String])
    case cancelled
    case processFailed(String)
}
