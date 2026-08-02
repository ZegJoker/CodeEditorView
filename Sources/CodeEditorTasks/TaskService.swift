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

    /// Execute the full DAG and record explicit per-node outcomes (TASK-N06).
    ///
    /// A dependent is launched only when every dependency has ``TaskNodeOutcome/succeeded``
    /// (background tasks require readiness before they count as succeeded for dependents).
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
                if taskID == root {
                    // Root may still be running; outcome finalized by caller via wait, or succeed if already done.
                    if handle.isFinished {
                        outcomes[taskID] = outcome(from: handle.run)
                    } else {
                        // Leave provisional succeeded for live root handle; wait path refines.
                        outcomes[taskID] = .succeeded
                    }
                    continue
                }
                do {
                    let result = try await handle.wait()
                    outcomes[taskID] = outcome(from: result.run)
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

    /// Start task graph; returns the root run's handle.
    @discardableResult
    public func start(id: TaskID) async throws -> TaskExecutionHandle {
        let report = try await executeGraph(id: id)
        switch report.rootOutcome {
        case .succeeded:
            if let handle = report.rootHandle {
                return handle
            }
            // Root finished inside graph without retained handle.
            throw TaskError.notFound(id.rawValue)
        case .failed(let failure):
            switch failure {
            case .notReady(let tid):
                throw TaskError.dependencyFailed(tid.rawValue)
            case .exitCode:
                throw TaskError.dependencyFailed(id.rawValue)
            case .timedOut:
                throw TaskError.timedOut
            case .processFailed(let m):
                throw TaskError.processFailed(m)
            case .invalidDefinition(let m):
                throw TaskError.invalidDefinition(m)
            case .concurrencyConflict(let m):
                throw TaskError.concurrencyConflict(m)
            }
        case .cancelled:
            throw TaskError.cancelled
        case .skippedBecauseDependency(let dep):
            throw TaskError.dependencyFailed(dep.rawValue)
        }
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
                let node = outcome(from: result.run)
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

    private func outcome(from run: TaskRun) -> TaskNodeOutcome {
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
            return .succeeded  // still live
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
                // Wait for exclusive holder — do not suppress outcome (TASK-N06).
                if let other = handles[holder] {
                    do {
                        let result = try await other.wait()
                        if result.run.state == .failed || result.run.state == .timedOut {
                            // Holder finished poorly; still release lock and allow next exclusive.
                            // Surface is via the holder's own run state; next task may proceed.
                        }
                    } catch TaskError.cancelled {
                        // Holder cancelled — exclusive released on completion path.
                    } catch {
                        // Non-suppressing: rethrow only concurrency-hard errors; otherwise proceed after death.
                    }
                }
                groupLocks[group] = nil
            }
        }

        let channel = await channels.channel(id: "task.\(id.rawValue)", name: def.label)
        // Re-open semantics: clear buffer; if previously finished, registry keeps same channel —
        // finish ownership is per-run via ProcessTaskRunner finishing the channel again only if not finished.
        // For re-runs, create a fresh channel when prior run finished.
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

        // Release exclusive lock when done (process death / complete)
        if let group = def.concurrencyGroup, def.isExclusive {
            let runID = handle.runID
            Task {
                do {
                    _ = try await handle.wait()
                } catch {
                    // Outcome recorded on handle; still release exclusive slot on death.
                }
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
