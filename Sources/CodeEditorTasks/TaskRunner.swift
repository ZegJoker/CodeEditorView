import Foundation
import CodeEditorCore

public protocol TaskRunner: Sendable {
    func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult
}

public struct ProcessTaskRunner: TaskRunner {
    public let platformProfile: PlatformCapabilityProfile

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
    }

    public func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult {
        try Task.checkCancellation()
        try platformProfile.requireLocal(.localProcess)
        var run = TaskRun(definitionID: definition.id, state: .running, startedAt: Date())

        let process = Process()
        if definition.useShell {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ([definition.executable] + definition.arguments).joined(separator: " ")]
        } else {
            process.executableURL = URL(fileURLWithPath: definition.executable)
            process.arguments = definition.arguments
        }
        if let cwd = definition.cwd {
            process.currentDirectoryURL = cwd
        }
        if !definition.environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in definition.environment { env[k] = v }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            run.state = .failed
            run.endedAt = Date()
            throw TaskError.processFailed(String(describing: error))
        }

        // Wait off main actor
        let result: (stdout: String, stderr: String, code: Int32) = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: (stdout, stderr, proc.terminationStatus))
            }
        }

        if Task.isCancelled {
            process.terminate()
            run.state = .cancelled
            run.endedAt = Date()
            throw TaskError.cancelled
        }

        output.append(text: result.stdout, isError: false)
        output.append(text: result.stderr, isError: true)
        run.exitCode = Int(result.code)
        run.endedAt = Date()
        run.state = result.code == 0 ? .succeeded : .failed
        return TaskRunResult(run: run, stdout: result.stdout, stderr: result.stderr)
    }
}
