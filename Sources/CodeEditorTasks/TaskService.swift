import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation

public actor TaskService {
    private var definitions: [TaskID: TaskDefinition] = [:]
    private var runs: [UUID: TaskRun] = [:]
    private var handles: [UUID: TaskExecutionHandle] = [:]
    private let runner: any TaskRunner
    private let channels: OutputChannelRegistry
    private var matchers: [ProblemMatcherID: ProblemMatcher] = [:]
    private var diagnosticsSink: (any TaskDiagnosticsSink)?
    private var groupLocks: [String: UUID] = [:]
    /// Last terminal outcome observed for an exclusive concurrency group (TASK-N06).
    /// Updated on holder wait and on release — never silently discarded.
    private var exclusiveGroupOutcomes: [String: TaskNodeOutcome] = [:]
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

    /// Last recorded exclusive-group outcome (TASK-N06). Failures are preserved until a later
    /// holder for the same group completes and overwrites with its terminal outcome.
    public func exclusiveGroupLastOutcome(group: String) -> TaskNodeOutcome? {
        exclusiveGroupOutcomes[group]
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

    /// Execute the full DAG and record explicit per-node outcomes (TASK-N06).
    ///
    /// A dependent is launched only when every dependency has ``TaskNodeOutcome/succeeded``
    /// (background tasks require readiness before they count as succeeded for dependents).
    /// Every non-skipped node is waited to a terminal outcome — live states are never reported
    /// as ``TaskNodeOutcome/succeeded``.
    public func executeGraph(id root: TaskID) async throws -> TaskGraphReport {
        let order = try resolveOrder(root)
        var outcomes: [TaskID: TaskNodeOutcome] = [:]
        var rootHandle: TaskExecutionHandle?

        for taskID in order {
            // If any direct dependency failed/skipped/cancelled, skip this node.
            if let def = definitions[taskID] {
                var blockedBy: TaskID?
                for dep in def.dependsOn {
                    guard let depOutcome = outcomes[dep] else {
                        blockedBy = dep
                        break
                    }
                    if !depOutcome.allowsDependents {
                        blockedBy = dep
                        break
                    }
                }
                if let blocker = blockedBy {
                    outcomes[taskID] = .skippedBecauseDependency(blocker)
                    continue
                }
            }

            do {
                let handle = try await startSingle(id: taskID)
                if taskID == root {
                    rootHandle = handle
                }
                let def = definitions[taskID]
                if def?.isBackground == true {
                    let ready = await waitForReadyOrCompletion(handle)
                    if ready {
                        outcomes[taskID] = .succeeded
                    } else {
                        let state = handle.run.state
                        if state == .cancelled {
                            outcomes[taskID] = .cancelled
                        } else {
                            outcomes[taskID] = .failed(.notReady(taskID))
                        }
                    }
                    continue
                }
                // Wait for terminal outcome — no provisional success for live runs (TASK-N06).
                do {
                    let result = try await handle.wait()
                    outcomes[taskID] = Self.terminalOutcome(from: result.run)
                } catch TaskError.cancelled {
                    outcomes[taskID] = .cancelled
                } catch TaskError.timedOut {
                    outcomes[taskID] = .failed(.timedOut)
                }
            } catch TaskError.cancelled {
                outcomes[taskID] = .cancelled
            } catch TaskError.invalidDefinition(let msg) {
                outcomes[taskID] = .failed(.invalidDefinition(msg))
            } catch TaskError.processFailed(let msg) {
                outcomes[taskID] = .failed(.processFailed(msg))
            } catch TaskError.concurrencyConflict(let msg) {
                outcomes[taskID] = .failed(.concurrencyConflict(msg))
            } catch TaskError.dependencyFailed(let dep) {
                outcomes[taskID] = .skippedBecauseDependency(TaskID(rawValue: dep))
            } catch {
                outcomes[taskID] = .failed(.processFailed(String(describing: error)))
            }
        }

        return TaskGraphReport(root: root, order: order, outcomes: outcomes, rootHandle: rootHandle)
    }

    /// Start task graph deps to completion, then return a live handle for the root (does not wait on root).
    @discardableResult
    public func start(id: TaskID) async throws -> TaskExecutionHandle {
        let order = try resolveOrder(id)
        var outcomes: [TaskID: TaskNodeOutcome] = [:]

        for taskID in order {
            if taskID == id {
                // Launch root without waiting — caller owns live streaming / wait.
                return try await startSingle(id: taskID)
            }

            if let def = definitions[taskID] {
                for dep in def.dependsOn {
                    if let depOutcome = outcomes[dep], !depOutcome.allowsDependents {
                        outcomes[taskID] = .skippedBecauseDependency(dep)
                        throw TaskError.dependencyFailed(dep.rawValue)
                    }
                }
            }

            let node = try await runNodeToTerminal(id: taskID)
            outcomes[taskID] = node
            if !node.allowsDependents {
                throw TaskError.dependencyFailed(taskID.rawValue)
            }
        }

        // Single-node graph (order == [id]) is handled in the loop; defensive fallback:
        return try await startSingle(id: id)
    }

    @discardableResult
    public func run(id: TaskID) async throws -> TaskRun {
        let order = try resolveOrder(id)
        var last: TaskRun?
        var outcomes: [TaskID: TaskNodeOutcome] = [:]

        for taskID in order {
            if let def = definitions[taskID] {
                for dep in def.dependsOn {
                    if let depOutcome = outcomes[dep], !depOutcome.allowsDependents {
                        outcomes[taskID] = .skippedBecauseDependency(dep)
                        throw TaskError.dependencyFailed(dep.rawValue)
                    }
                }
            }

            let handle = try await startSingle(id: taskID)
            if definitions[taskID]?.isBackground == true {
                let ready = await waitForReadyOrCompletion(handle)
                if !ready {
                    outcomes[taskID] = .failed(.notReady(taskID))
                    throw TaskError.dependencyFailed(taskID.rawValue)
                }
                outcomes[taskID] = .succeeded
                last = handle.run
                continue
            }
            do {
                let result = try await handle.wait()
                last = result.run
                let node = Self.terminalOutcome(from: result.run)
                outcomes[taskID] = node
                if !node.allowsDependents {
                    return result.run
                }
            } catch TaskError.cancelled {
                outcomes[taskID] = .cancelled
                return handle.run
            } catch TaskError.timedOut {
                outcomes[taskID] = .failed(.timedOut)
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
        // Signal cancel only — exclusive concurrency groups are released when
        // the handle completes (process death), not here (TASK-003 / §18.4).
        handles[runID]?.cancel()
    }

    public func runSnapshot(id: UUID) -> TaskRun? {
        if let handle = handles[id] {
            return handle.run
        }
        return runs[id]
    }

    // MARK: - Private

    /// Map a finished `TaskRun` to a terminal DAG outcome.
    /// Non-terminal states never count as success (TASK-N06) — dependents must not launch.
    nonisolated static func terminalOutcome(from run: TaskRun) -> TaskNodeOutcome {
        switch run.state {
        case .succeeded:
            return .succeeded
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failed(.timedOut)
        case .failed:
            return .failed(.exitCode(run.exitCode ?? 1))
        case .queued, .starting, .running:
            return .failed(.processFailed("task not finished (state=\(run.state.rawValue))"))
        }
    }

    private func runNodeToTerminal(id: TaskID) async throws -> TaskNodeOutcome {
        let handle = try await startSingle(id: id)
        if definitions[id]?.isBackground == true {
            let ready = await waitForReadyOrCompletion(handle)
            if ready { return .succeeded }
            if handle.run.state == .cancelled { return .cancelled }
            return .failed(.notReady(id))
        }
        do {
            let result = try await handle.wait()
            return Self.terminalOutcome(from: result.run)
        } catch TaskError.cancelled {
            return .cancelled
        } catch TaskError.timedOut {
            return .failed(.timedOut)
        }
    }

    private func waitForReadyOrCompletion(_ handle: TaskExecutionHandle) async -> Bool {
        // TASK-N06: only "ready" unblocks dependents. Failed/completed-before-ready is failure.
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
        return sawReady
    }

    private func startSingle(id: TaskID) async throws -> TaskExecutionHandle {
        guard var def = definitions[id] else {
            throw TaskError.notFound(id.rawValue)
        }
        // TASK-N05: validate readiness before any launch work.
        _ = try TaskError.validateReadinessPattern(def.readinessPattern)
        def = try TaskVariableResolver.resolveDefinition(def, extraVariables: extraVariables)

        if let group = def.concurrencyGroup {
            if let holder = groupLocks[group], def.isExclusive || handles[holder]?.run.state == .running {
                // Wait for exclusive holder — record outcome explicitly (TASK-N06), then release.
                if let other = handles[holder] {
                    let waited = await waitExclusiveHolder(other)
                    exclusiveGroupOutcomes[group] = waited
                }
                groupLocks[group] = nil
            }
        }

        let channel = await channels.channel(id: "task.\(id.rawValue)", name: def.label)
        // Re-open semantics: clear buffer; if previously finished, use a fresh channel.
        let output: OutputChannel
        if channel.isFinished {
            let fresh = OutputChannel(id: "task.\(id.rawValue).\(UUID().uuidString)", name: def.label)
            output = fresh
        } else {
            channel.clear()
            output = channel
        }

        let handle = try await runner.start(def, output: output)
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
                    case .outputTruncated:
                        break
                    case .completed(let run):
                        _ = run
                        var problems = engine.finish()
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

        // Release exclusive lock when done (process death / complete); record outcome (TASK-N06).
        if let group = def.concurrencyGroup, def.isExclusive {
            let runID = handle.runID
            Task {
                let terminal = await self.waitExclusiveHolder(handle)
                await self.recordExclusiveRelease(group: group, runID: runID, outcome: terminal)
            }
        }

        return handle
    }

    /// Wait for an exclusive holder and map to a terminal outcome — no empty catch that hides failure.
    private func waitExclusiveHolder(_ handle: TaskExecutionHandle) async -> TaskNodeOutcome {
        do {
            let result = try await handle.wait()
            return Self.terminalOutcome(from: result.run)
        } catch TaskError.cancelled {
            return .cancelled
        } catch TaskError.timedOut {
            return .failed(.timedOut)
        } catch {
            return .failed(.processFailed(String(describing: error)))
        }
    }

    private func recordExclusiveRelease(group: String, runID: UUID, outcome: TaskNodeOutcome) async {
        exclusiveGroupOutcomes[group] = outcome
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
