import CodeEditorCore
import CodeEditorDocuments
import Foundation

public struct DebugAdapterID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum DebugAdapterLaunch: Sendable {
    case process(executable: URL, arguments: [String])
    case test(factoryID: String)
    case connect(host: String, port: Int)
    case custom(@Sendable () async throws -> any DAPTransport)
}

public struct DebugAdapterDefinition: Sendable {
    public var id: DebugAdapterID
    public var displayName: String
    public var languages: Set<String>
    public var launch: DebugAdapterLaunch
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var adapterID: String
    /// Pre/post debug task IDs (host resolves via TaskService).
    public var preDebugTaskID: String?
    public var postDebugTaskID: String?

    public init(
        id: DebugAdapterID,
        displayName: String,
        languages: Set<String> = [],
        launch: DebugAdapterLaunch,
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        adapterID: String? = nil,
        preDebugTaskID: String? = nil,
        postDebugTaskID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.languages = Set(languages.map { $0.lowercased() })
        self.launch = launch
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.adapterID = adapterID ?? id.rawValue
        self.preDebugTaskID = preDebugTaskID
        self.postDebugTaskID = postDebugTaskID
    }

    public var poolKey: String { id.rawValue }
}

public enum DebugAdapterState: String, Sendable, Hashable, Codable {
    case idle
    case starting
    case initializing
    case initialized
    case configured
    case running
    case stopped
    case terminating
    case terminated
    case failed
}

/// Capability snapshot from `initialize` response body.
public struct DAPCapabilities: Sendable, Hashable {
    public var supportsConfigurationDoneRequest: Bool
    public var supportsFunctionBreakpoints: Bool
    public var supportsConditionalBreakpoints: Bool
    public var supportsHitConditionalBreakpoints: Bool
    public var supportsEvaluateForHovers: Bool
    public var supportsStepBack: Bool
    public var supportsSetVariable: Bool
    public var supportsRestartFrame: Bool
    public var supportsGotoTargetsRequest: Bool
    public var supportsStepInTargetsRequest: Bool
    public var supportsCompletionsRequest: Bool
    public var supportsModulesRequest: Bool
    public var supportsRestartRequest: Bool
    public var supportsExceptionOptions: Bool
    public var supportsValueFormattingOptions: Bool
    public var supportsExceptionInfoRequest: Bool
    public var supportTerminateDebuggee: Bool
    public var supportsDelayedStackTraceLoading: Bool
    public var supportsLoadedSourcesRequest: Bool
    public var supportsLogPoints: Bool
    public var supportsTerminateThreadsRequest: Bool
    public var supportsSetExpression: Bool
    public var supportsTerminateRequest: Bool
    public var supportsDataBreakpoints: Bool
    public var supportsReadMemoryRequest: Bool
    public var supportsWriteMemoryRequest: Bool
    public var supportsDisassembleRequest: Bool
    public var supportsCancelRequest: Bool
    public var supportsBreakpointLocationsRequest: Bool
    public var supportsInstructionBreakpoints: Bool
    public var supportsExceptionFilterOptions: Bool
    public var supportsSingleThreadExecutionRequests: Bool

    public static let empty = DAPCapabilities(
        supportsConfigurationDoneRequest: false,
        supportsFunctionBreakpoints: false,
        supportsConditionalBreakpoints: false,
        supportsHitConditionalBreakpoints: false,
        supportsEvaluateForHovers: false,
        supportsStepBack: false,
        supportsSetVariable: false,
        supportsRestartFrame: false,
        supportsGotoTargetsRequest: false,
        supportsStepInTargetsRequest: false,
        supportsCompletionsRequest: false,
        supportsModulesRequest: false,
        supportsRestartRequest: false,
        supportsExceptionOptions: false,
        supportsValueFormattingOptions: false,
        supportsExceptionInfoRequest: false,
        supportTerminateDebuggee: false,
        supportsDelayedStackTraceLoading: false,
        supportsLoadedSourcesRequest: false,
        supportsLogPoints: false,
        supportsTerminateThreadsRequest: false,
        supportsSetExpression: false,
        supportsTerminateRequest: false,
        supportsDataBreakpoints: false,
        supportsReadMemoryRequest: false,
        supportsWriteMemoryRequest: false,
        supportsDisassembleRequest: false,
        supportsCancelRequest: false,
        supportsBreakpointLocationsRequest: false,
        supportsInstructionBreakpoints: false,
        supportsExceptionFilterOptions: false,
        supportsSingleThreadExecutionRequests: false
    )

    public static func parse(from body: [String: Any]) -> DAPCapabilities {
        func b(_ key: String) -> Bool { body[key] as? Bool ?? false }
        return DAPCapabilities(
            supportsConfigurationDoneRequest: b("supportsConfigurationDoneRequest"),
            supportsFunctionBreakpoints: b("supportsFunctionBreakpoints"),
            supportsConditionalBreakpoints: b("supportsConditionalBreakpoints"),
            supportsHitConditionalBreakpoints: b("supportsHitConditionalBreakpoints"),
            supportsEvaluateForHovers: b("supportsEvaluateForHovers"),
            supportsStepBack: b("supportsStepBack"),
            supportsSetVariable: b("supportsSetVariable"),
            supportsRestartFrame: b("supportsRestartFrame"),
            supportsGotoTargetsRequest: b("supportsGotoTargetsRequest"),
            supportsStepInTargetsRequest: b("supportsStepInTargetsRequest"),
            supportsCompletionsRequest: b("supportsCompletionsRequest"),
            supportsModulesRequest: b("supportsModulesRequest"),
            supportsRestartRequest: b("supportsRestartRequest"),
            supportsExceptionOptions: b("supportsExceptionOptions"),
            supportsValueFormattingOptions: b("supportsValueFormattingOptions"),
            supportsExceptionInfoRequest: b("supportsExceptionInfoRequest"),
            supportTerminateDebuggee: b("supportTerminateDebuggee"),
            supportsDelayedStackTraceLoading: b("supportsDelayedStackTraceLoading"),
            supportsLoadedSourcesRequest: b("supportsLoadedSourcesRequest"),
            supportsLogPoints: b("supportsLogPoints"),
            supportsTerminateThreadsRequest: b("supportsTerminateThreadsRequest"),
            supportsSetExpression: b("supportsSetExpression"),
            supportsTerminateRequest: b("supportsTerminateRequest"),
            supportsDataBreakpoints: b("supportsDataBreakpoints"),
            supportsReadMemoryRequest: b("supportsReadMemoryRequest"),
            supportsWriteMemoryRequest: b("supportsWriteMemoryRequest"),
            supportsDisassembleRequest: b("supportsDisassembleRequest"),
            supportsCancelRequest: b("supportsCancelRequest"),
            supportsBreakpointLocationsRequest: b("supportsBreakpointLocationsRequest"),
            supportsInstructionBreakpoints: b("supportsInstructionBreakpoints"),
            supportsExceptionFilterOptions: b("supportsExceptionFilterOptions"),
            supportsSingleThreadExecutionRequests: b("supportsSingleThreadExecutionRequests")
        )
    }
}

// MARK: - Domain models

public struct DAPSourceBreakpoint: Sendable, Hashable, Codable {
    public var line: Int
    public var column: Int?
    public var condition: String?
    public var hitCondition: String?
    public var logMessage: String?

    public init(
        line: Int, column: Int? = nil, condition: String? = nil, hitCondition: String? = nil, logMessage: String? = nil
    ) {
        self.line = line
        self.column = column
        self.condition = condition
        self.hitCondition = hitCondition
        self.logMessage = logMessage
    }
}

public struct DAPBreakpoint: Sendable, Hashable, Codable {
    public var id: Int?
    public var verified: Bool
    public var message: String?
    public var line: Int?
    public var column: Int?

    public init(id: Int? = nil, verified: Bool, message: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.id = id
        self.verified = verified
        self.message = message
        self.line = line
        self.column = column
    }
}

public struct DAPThread: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DAPStackFrame: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var line: Int
    public var column: Int
    public var sourcePath: String?
    public init(id: Int, name: String, line: Int, column: Int, sourcePath: String? = nil) {
        self.id = id
        self.name = name
        self.line = line
        self.column = column
        self.sourcePath = sourcePath
    }
}

public struct DAPScope: Sendable, Hashable, Codable {
    public var name: String
    public var variablesReference: Int
    public var expensive: Bool
    public init(name: String, variablesReference: Int, expensive: Bool = false) {
        self.name = name
        self.variablesReference = variablesReference
        self.expensive = expensive
    }
}

public struct DAPVariable: Sendable, Hashable, Codable {
    public var name: String
    public var value: String
    public var type: String?
    public var variablesReference: Int
    public init(name: String, value: String, type: String? = nil, variablesReference: Int = 0) {
        self.name = name
        self.value = value
        self.type = type
        self.variablesReference = variablesReference
    }
}

public struct DAPStoppedEvent: Sendable, Hashable {
    public var reason: String
    public var threadId: Int?
    public var allThreadsStopped: Bool?
    public var description: String?
}

public struct DAPOutputEvent: Sendable, Hashable {
    public var category: String?
    public var output: String
}

/// Host-injected reverse-request handlers (no hard Tasks/Terminal dependency in DAP product).
public protocol DAPRunInTerminalHandler: Sendable {
    func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult
}

public struct DAPRunInTerminalArgs: Sendable {
    public var kind: String?
    public var title: String?
    public var cwd: String?
    public var args: [String]
    public var env: [String: String]?

    public init(
        kind: String? = nil, title: String? = nil, cwd: String? = nil, args: [String], env: [String: String]? = nil
    ) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.args = args
        self.env = env
    }
}

public struct DAPRunInTerminalResult: Sendable {
    public var processId: Int?
    public var shellProcessId: Int?
    public init(processId: Int? = nil, shellProcessId: Int? = nil) {
        self.processId = processId
        self.shellProcessId = shellProcessId
    }
}

public protocol DAPStartDebuggingHandler: Sendable {
    func startDebugging(configuration: DAPJSONObject, request: String) async throws
}
