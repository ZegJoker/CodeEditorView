import CodeEditorTasks
import Foundation

/// Test-only runner (TASK-005) — not shipped in production product.
public struct FakeTaskRunner: TaskRunner, Sendable {
    public var stdoutChunks: [String]
    public var stderrChunks: [String]
    public var exitCode: Int32
    public var chunkDelayNanoseconds: UInt64
    public var hangUntilCancelled: Bool

    public init(
        stdoutChunks: [String] = ["ok\n"],
        stderrChunks: [String] = [],
        exitCode: Int32 = 0,
        chunkDelayNanoseconds: UInt64 = 0,
        hangUntilCancelled: Bool = false
    ) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
        self.exitCode = exitCode
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.hangUntilCancelled = hangUntilCancelled
    }

    public func start(
        _ definition: TaskDefinition,
        output: OutputChannel
    ) async throws -> TaskExecutionHandle {
        // TASK-N05: fail closed on invalid readiness before any emission.
        _ = try TaskError.validateReadinessPattern(definition.readinessPattern)

        let run = TaskRun(definitionID: definition.id, state: .running, startedAt: Date())
        let handle = try TaskExecutionHandle(
            run: run,
            processHandle: nil,
            readinessPattern: definition.readinessPattern
        )
        let chunks = stdoutChunks
        let errChunks = stderrChunks
        let delay = chunkDelayNanoseconds
        let hang = hangUntilCancelled
        let code = exitCode
        Task {
            if hang {
                while true {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if handle.run.state == .cancelled {
                        // cancel() without process finishes the handle.
                        return
                    }
                }
            }
            var out = ""
            var err = ""
            for chunk in chunks {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                if handle.run.state == .cancelled { return }
                handle.emit(stdout: chunk)
                output.append(text: chunk, isError: false)
                out += chunk
            }
            for chunk in errChunks {
                handle.emit(stderr: chunk)
                output.append(text: chunk, isError: true)
                err += chunk
            }
            var done = handle.run
            done.state = code == 0 ? .succeeded : .failed
            done.exitCode = Int(code)
            done.endedAt = Date()
            handle.complete(run: done, stdout: out, stderr: err)
            output.finish(reason: .completed)
        }
        return handle
    }
}
