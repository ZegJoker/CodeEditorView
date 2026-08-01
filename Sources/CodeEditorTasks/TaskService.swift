import Foundation
import CodeEditorDocuments
import CodeEditorLanguageServices

public actor TaskService {
    private var definitions: [TaskID: TaskDefinition] = [:]
    private var runs: [UUID: TaskRun] = [:]
    private var handles: [UUID: TaskExecutionHandle] = [:]
    private let runner: any TaskRunner
    private let channels: OutputChannelRegistry
    private var matchers: [ProblemMatcherID: ProblemMatcher] = [:]
    private var diagnosticsSink: (any TaskDiagnosticsSink)?
    private var groupLocks: [String: UUID] = [:]
    private var extraVariables: [String: String] = [:]

    public init(
        runner: any TaskRunner = ProcessTaskRunner(),
        channels: OutputChannelRegistry = OutputChannelRegistry()
    ) {
        self.runner = runner
        self.channels = channels
    }

    public func setVariables(_ variables: [String: String]) {
        extraVariables = variables
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

    /// Start task graph; returns the root run's handle.
    @discardableResult
    public func start(id: TaskID) async throws -> TaskExecutionHandle {
        let order = try resolveOrder(id)
        var lastHandle: TaskExecutionHandle?
        for (index, taskID) in order.enumerated() {
            let isRoot = index == order.count - 1
            let handle = try await startSingle(id: taskID)
            lastHandle = handle
            if definitions[taskID]?.isBackground == true {
                // TASK-002: only "ready" unblocks dependents. Failed/completed-before-ready
                // is a typed dependency failure — never silently continue the graph.
                var sawReady = false
                var completedWithoutReady = false
                for await event in handle.events {
                    switch event {
                    case .ready:
                        sawReady = true
                    case .completed:
                        completedWithoutReady = !sawReady
                    default:
                        break
                    }
                    if sawReady { break }
                    if completedWithoutReady { break }
                }
                if !sawReady {
                    throw TaskError.dependencyFailed(taskID.rawValue)
                }
                continue
            }
            if isRoot {
                // Caller may await the root handle.
                break
            }
            do {
                let result = try await handle.wait()
                if result.run.state == .failed || result.run.state == .timedOut {
                    throw TaskError.dependencyFailed(taskID.rawValue)
                }
            } catch TaskError.cancelled {
                throw TaskError.cancelled
            }
        }
        guard let lastHandle else {
            throw TaskError.notFound(id.rawValue)
        }
        return lastHandle
    }

    @discardableResult
    public func run(id: TaskID) async throws -> TaskRun {
        let order = try resolveOrder(id)
        var last: TaskRun?
        for taskID in order {
            let handle = try await startSingle(id: taskID)
            if definitions[taskID]?.isBackground == true {
                var sawReady = false
                var completedWithoutReady = false
                for await event in handle.events {
                    switch event {
                    case .ready: sawReady = true
                    case .completed: completedWithoutReady = !sawReady
                    default: break
                    }
                    if sawReady { break }
                    if completedWithoutReady { break }
                }
                if !sawReady {
                    throw TaskError.dependencyFailed(taskID.rawValue)
                }
                last = handle.run
                continue
            }
            do {
                let result = try await handle.wait()
                last = result.run
                if result.run.state == .failed || result.run.state == .timedOut {
                    return result.run
                }
            } catch TaskError.cancelled {
                return handle.run
            } catch TaskError.timedOut {
                return handle.run
            }
        }
        return last ?? TaskRun(definitionID: id, state: .failed)
    }

    public func cancel(runID: UUID) {
        if var run = runs[runID], run.state == .running || run.state == .queued || run.state == .starting {
            run.state = .cancelled
            runs[runID] = run
        }
        handles[runID]?.cancel()
        // Release concurrency locks held by this run
        for (group, holder) in groupLocks where holder == runID {
            groupLocks[group] = nil
        }
    }

    public func runSnapshot(id: UUID) -> TaskRun? {
        if let handle = handles[id] {
            return handle.run
        }
        return runs[id]
    }

    private func startSingle(id: TaskID) async throws -> TaskExecutionHandle {
        guard var def = definitions[id] else {
            throw TaskError.notFound(id.rawValue)
        }
        def = TaskVariableResolver.resolveDefinition(def, extraVariables: extraVariables)

        if let group = def.concurrencyGroup {
            if let holder = groupLocks[group], def.isExclusive || handles[holder]?.run.state == .running {
                // Wait for exclusive holder
                if let other = handles[holder] {
                    _ = try? await other.wait()
                }
                groupLocks[group] = nil
            }
        }

        let channel = await channels.channel(id: "task.\(id.rawValue)", name: def.label)
        channel.clear()

        let handle = try await runner.start(def, output: channel)
        runs[handle.runID] = handle.run
        handles[handle.runID] = handle

        if let group = def.concurrencyGroup, def.isExclusive {
            groupLocks[group] = handle.runID
        }

        // Streaming + final problem matchers
        let matcherList = def.problemMatchers.compactMap { matchers[$0] }
        if !matcherList.isEmpty {
            let engine = StreamingProblemMatcherEngine(
                matchers: matcherList,
                cwd: def.cwd,
                workspaceRoot: def.cwd
            )
            let sink = diagnosticsSink
            let owner = matcherList[0].owner
            Task {
                for await event in handle.events {
                    switch event {
                    case .stdout(let t), .stderr(let t):
                        let problems = engine.feed(t)
                        await publish(problems, sink: sink, owner: owner)
                    case .completed(let run):
                        _ = run
                        var problems = engine.finish()
                        // Also scan full collected buffers (covers completed-handle fakes).
                        let full = handle.collectedStdout + "\n" + handle.collectedStderr
                        if problems.isEmpty {
                            problems = ProblemMatcherEngine.matchAll(
                                text: full,
                                matchers: matcherList,
                                cwd: def.cwd,
                                workspaceRoot: def.cwd
                            )
                        }
                        await publish(problems, sink: sink, owner: owner)
                    case .ready:
                        break
                    }
                }
            }
        }

        // Release exclusive lock when done
        if let group = def.concurrencyGroup, def.isExclusive {
            let runID = handle.runID
            Task {
                _ = try? await handle.wait()
                await self.releaseGroup(group, runID: runID)
            }
        }

        return handle
    }

    private func releaseGroup(_ group: String, runID: UUID) {
        if groupLocks[group] == runID {
            groupLocks[group] = nil
        }
    }

    private func publish(
        _ problems: [MatchedProblem],
        sink: (any TaskDiagnosticsSink)?,
        owner: String
    ) async {
        guard let sink, !problems.isEmpty else { return }
        var byURI: [DocumentURI: [LanguageDiagnostic]] = [:]
        for p in problems {
            guard let uri = p.uri else { continue }
            byURI[uri, default: []].append(p.diagnostic)
        }
        for (uri, diags) in byURI {
            await sink.publish(uri: uri, diagnostics: diags, owner: owner)
        }
    }
}
