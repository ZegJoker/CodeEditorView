import Foundation
import CodeEditorDocuments
import CodeEditorLanguageServices

public actor TaskService {
    private var definitions: [TaskID: TaskDefinition] = [:]
    private var runs: [UUID: TaskRun] = [:]
    private var activeProcesses: [UUID: Bool] = [:]
    private let runner: any TaskRunner
    private let channels: OutputChannelRegistry
    private var matchers: [ProblemMatcherID: ProblemMatcher] = [:]
    private var diagnosticsSink: (any TaskDiagnosticsSink)?

    public init(
        runner: any TaskRunner = ProcessTaskRunner(),
        channels: OutputChannelRegistry = OutputChannelRegistry()
    ) {
        self.runner = runner
        self.channels = channels
    }

    public func setDiagnosticsSink(_ sink: (any TaskDiagnosticsSink)?) {
        diagnosticsSink = sink
    }

    public func registerMatcher(_ matcher: ProblemMatcher) {
        matchers[matcher.id] = matcher
    }

    public func register(_ definition: TaskDefinition) {
        definitions[definition.id] = definition
    }

    public func definition(id: TaskID) -> TaskDefinition? {
        definitions[id]
    }

    public func allDefinitions() -> [TaskDefinition] {
        Array(definitions.values).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Topological order of `root` and its dependencies. Throws on cycles.
    public func resolveOrder(_ root: TaskID) throws -> [TaskID] {
        var sorted: [TaskID] = []
        var temporary = Set<TaskID>()
        var permanent = Set<TaskID>()

        func visit(_ id: TaskID) throws {
            if permanent.contains(id) { return }
            if temporary.contains(id) {
                throw TaskError.dependencyCycle([id.rawValue])
            }
            temporary.insert(id)
            guard let def = definitions[id] else {
                throw TaskError.notFound(id.rawValue)
            }
            for dep in def.dependsOn {
                try visit(dep)
            }
            temporary.remove(id)
            permanent.insert(id)
            sorted.append(id)
        }

        try visit(root)
        return sorted
    }

    @discardableResult
    public func run(id: TaskID) async throws -> TaskRun {
        let order = try resolveOrder(id)
        var last: TaskRun?
        for taskID in order {
            let result = try await runSingle(id: taskID)
            last = result.run
            if result.run.state == .failed {
                return result.run
            }
        }
        return last ?? TaskRun(definitionID: id, state: .failed)
    }

    public func cancel(runID: UUID) {
        if var run = runs[runID], run.state == .running || run.state == .queued {
            run.state = .cancelled
            runs[runID] = run
        }
        activeProcesses[runID] = false
    }

    public func runSnapshot(id: UUID) -> TaskRun? {
        runs[id]
    }

    private func runSingle(id: TaskID) async throws -> TaskRunResult {
        guard let def = definitions[id] else {
            throw TaskError.notFound(id.rawValue)
        }
        let channel = await channels.channel(id: "task.\(id.rawValue)", name: def.label)
        channel.clear()
        channel.append(text: "> \(def.executable) \(def.arguments.joined(separator: " "))")

        let result = try await runner.run(def, output: channel)
        runs[result.run.id] = result.run

        // Problem matchers
        let matcherList = def.problemMatchers.compactMap { matchers[$0] }
        if !matcherList.isEmpty, let sink = diagnosticsSink {
            let problems = ProblemMatcherEngine.matchAll(
                text: result.stdout + "\n" + result.stderr,
                matchers: matcherList,
                cwd: def.cwd
            )
            var byURI: [DocumentURI: [LanguageDiagnostic]] = [:]
            for p in problems {
                guard let uri = p.uri else { continue }
                byURI[uri, default: []].append(p.diagnostic)
            }
            for (uri, diags) in byURI {
                await sink.publish(uri: uri, diagnostics: diags, owner: matcherList[0].owner)
            }
        }
        return result
    }
}
