import Darwin
import Foundation

// MARK: - Process launch configuration

public enum ProcessLaunchMode: Sendable, Hashable {
    /// Execute `executable` with raw `arguments` (no shell).
    case direct
    /// Run via `/bin/sh -c` with POSIX shell quoting of argv.
    case shell
}

public struct ProcessLaunchRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var mode: ProcessLaunchMode
    public var currentDirectory: URL?
    public var environment: [String: String]
    /// When true, merge `environment` over the current process environment.
    public var mergeEnvironment: Bool
    public var timeout: Duration?
    public var maxStdoutBytes: Int
    public var maxStderrBytes: Int
    public var capabilityKind: PlatformCapabilityKind

    public init(
        executable: String,
        arguments: [String] = [],
        mode: ProcessLaunchMode = .direct,
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        mergeEnvironment: Bool = true,
        timeout: Duration? = nil,
        maxStdoutBytes: Int = 8 * 1024 * 1024,
        maxStderrBytes: Int = 2 * 1024 * 1024,
        capabilityKind: PlatformCapabilityKind = .localProcess
    ) {
        self.executable = executable
        self.arguments = arguments
        self.mode = mode
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.mergeEnvironment = mergeEnvironment
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
        self.capabilityKind = capabilityKind
    }
}

public enum ProcessOutputEvent: Sendable, Hashable {
    case stdout(Data)
    case stderr(Data)
    case exited(code: Int32, timedOut: Bool)
}

public enum ProcessServiceError: Error, Sendable, Equatable {
    case invalidWorkingDirectory(String)
    case launchFailed(String)
    case timedOut
    case cancelled
    case alreadyExited
    /// Foundation.Process is unavailable on this platform (e.g. iOS).
    case unavailableOnPlatform
}

/// POSIX shell single-argument quoting for shell launch mode.
public enum ShellQuoting {
    public static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        // Prefer single quotes; escape embedded ' as '\''
        if argument.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)  // 0-9
                || (v >= 0x41 && v <= 0x5A)  // A-Z
                || (v >= 0x61 && v <= 0x7A)  // a-z
                || scalar == "_" || scalar == "-" || scalar == "." || scalar == "/" || scalar == "+" || scalar == "="
                || scalar == "@" || scalar == "%"
        }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func joinCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }
}

#if os(macOS)
    /// Live handle for a launched process with streaming output and process-group teardown.
    public final class ProcessHandle: @unchecked Sendable {
        public let id: UUID
        public private(set) var processIdentifier: Int32
        private let process: Process
        private let stdoutPipe: Pipe
        private let stderrPipe: Pipe
        private let lock = NSLock()
        private var _terminated = false
        private var continuation: AsyncStream<ProcessOutputEvent>.Continuation?
        public let events: AsyncStream<ProcessOutputEvent>
        private var timeoutTask: Task<Void, Never>?
        private var stdoutBytes = 0
        private var stderrBytes = 0
        private let maxStdout: Int
        private let maxStderr: Int

        fileprivate init(
            id: UUID = UUID(),
            process: Process,
            stdout: Pipe,
            stderr: Pipe,
            maxStdout: Int,
            maxStderr: Int,
            timeout: Duration?,
            launch: Bool = true
        ) {
            self.id = id
            self.process = process
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            self.processIdentifier = process.processIdentifier
            self.maxStdout = maxStdout
            self.maxStderr = maxStderr
            var cont: AsyncStream<ProcessOutputEvent>.Continuation!
            self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
            self.continuation = cont

            let outHandle = stdout.fileHandleForReading
            let errHandle = stderr.fileHandleForReading
            outHandle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    return
                }
                self?.emitStdout(data)
            }
            errHandle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    return
                }
                self?.emitStderr(data)
            }

            process.terminationHandler = { [weak self] proc in
                self?.drainAndFinish(code: proc.terminationStatus, timedOut: false)
            }

            if let timeout {
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, !Task.isCancelled else { return }
                    if !self.isTerminated {
                        self.terminateProcessGroup()
                        self.drainAndFinish(code: 124, timedOut: true)
                    }
                }
            }
            _ = launch
        }

        fileprivate func noteLaunched() {
            processIdentifier = process.processIdentifier
            let pid = processIdentifier
            if pid > 0 {
                _ = setpgid(pid, pid)
            }
            // If the process already finished before the handler was observed, finish now.
            if !process.isRunning {
                let code = process.terminationStatus
                drainAndFinish(code: code, timedOut: false)
            }
        }

        public var isTerminated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _terminated
        }

        public func waitUntilExit() async -> (code: Int32, timedOut: Bool) {
            for await event in events {
                if case .exited(let code, let timedOut) = event {
                    return (code, timedOut)
                }
            }
            return (process.terminationStatus, false)
        }

        /// Cancel and **wait for process death** before finishing the event stream
        /// so exclusive task slots are not released early (TASK-003 / §18.4).
        public func cancel() {
            if isTerminated { return }
            terminateProcessGroup()
            // Block until the OS reaps the process (or it already exited).
            if process.isRunning {
                process.waitUntilExit()
            }
            let code = process.terminationStatus
            // Prefer SIGTERM convention when the process had no normal exit code.
            drainAndFinish(code: code == 0 ? 143 : code, timedOut: false)
        }

        /// TERM process group, then KILL after grace.
        public func terminateProcessGroup() {
            let pid = process.processIdentifier
            guard pid > 0 else {
                if process.isRunning { process.terminate() }
                return
            }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [process] in
                if process.isRunning {
                    kill(-pid, SIGKILL)
                    if process.isRunning { process.terminate() }
                }
            }
        }

        private func emitStdout(_ data: Data) {
            lock.lock()
            if _terminated {
                lock.unlock()
                return
            }
            stdoutBytes += data.count
            let over = stdoutBytes > maxStdout
            let cont = continuation
            lock.unlock()
            if over {
                cont?.yield(.stderr(Data("… stdout capped\n".utf8)))
                return
            }
            cont?.yield(.stdout(data))
        }

        private func emitStderr(_ data: Data) {
            lock.lock()
            if _terminated {
                lock.unlock()
                return
            }
            stderrBytes += data.count
            let over = stderrBytes > maxStderr
            let cont = continuation
            lock.unlock()
            if over { return }
            cont?.yield(.stderr(data))
        }

        private func drainAndFinish(code: Int32, timedOut: Bool) {
            lock.lock()
            if _terminated {
                lock.unlock()
                return
            }
            _terminated = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            timeoutTask?.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Drain remaining buffered pipe data.
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !out.isEmpty { cont?.yield(.stdout(out)) }
            let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !err.isEmpty { cont?.yield(.stderr(err)) }
            cont?.yield(.exited(code: code, timedOut: timedOut))
            cont?.finish()
        }

        deinit {
            if process.isRunning {
                terminateProcessGroup()
            }
        }
    }
#else
    /// Placeholder handle on platforms without Foundation.Process (iOS).
    public final class ProcessHandle: @unchecked Sendable {
        public let id: UUID
        public private(set) var processIdentifier: Int32 = -1
        public let events: AsyncStream<ProcessOutputEvent>

        fileprivate init(id: UUID = UUID()) {
            self.id = id
            self.events = AsyncStream { $0.finish() }
        }

        public var isTerminated: Bool { true }

        public func waitUntilExit() async -> (code: Int32, timedOut: Bool) {
            (-1, false)
        }

        public func cancel() {}
        public func terminateProcessGroup() {}
    }
#endif

/// Launches local processes with streaming I/O and process-group lifecycle.
/// Shared non-PTY process supervisor used by tasks, Git, and helpers (PROC-001 / §18.10).
///
/// Provides process-group launch, streaming I/O with byte caps, timeout, and
/// cancellation that waits for process death before releasing exclusivity.
public typealias ProcessSupervisor = ProcessService

public struct ProcessService: Sendable {
    public var profile: PlatformCapabilityProfile

    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }

    public func launch(_ request: ProcessLaunchRequest) throws -> ProcessHandle {
        try profile.requireLocal(request.capabilityKind)

        #if os(macOS)
            if let cwd = request.currentDirectory {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
                    throw ProcessServiceError.invalidWorkingDirectory(cwd.path)
                }
            }

            let process = Process()
            switch request.mode {
            case .direct:
                process.executableURL = URL(fileURLWithPath: request.executable)
                process.arguments = request.arguments
            case .shell:
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                let cmd = ShellQuoting.joinCommand(executable: request.executable, arguments: request.arguments)
                process.arguments = ["-c", cmd]
            }

            if let cwd = request.currentDirectory {
                process.currentDirectoryURL = cwd
            }

            if request.mergeEnvironment {
                var env = ProcessInfo.processInfo.environment
                for (k, v) in request.environment { env[k] = v }
                process.environment = env
            } else if !request.environment.isEmpty {
                process.environment = request.environment
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            process.qualityOfService = .userInitiated

            // Construct handle before run so terminationHandler is installed first.
            let handle = ProcessHandle(
                process: process,
                stdout: stdout,
                stderr: stderr,
                maxStdout: request.maxStdoutBytes,
                maxStderr: request.maxStderrBytes,
                timeout: request.timeout,
                launch: false
            )
            do {
                try process.run()
            } catch {
                throw ProcessServiceError.launchFailed(String(describing: error))
            }
            handle.noteLaunched()
            return handle
        #else
            throw ProcessServiceError.unavailableOnPlatform
        #endif
    }

    /// Convenience: run to completion collecting UTF-8 output.
    public func runCollecting(
        _ request: ProcessLaunchRequest
    ) async throws -> (stdout: String, stderr: String, code: Int32) {
        let handle = try launch(request)
        var out = Data()
        var err = Data()
        var code: Int32 = -1
        var timedOut = false
        for await event in handle.events {
            switch event {
            case .stdout(let d): out.append(d)
            case .stderr(let d): err.append(d)
            case .exited(let c, let t):
                code = c
                timedOut = t
            }
        }
        if timedOut { throw ProcessServiceError.timedOut }
        if Task.isCancelled {
            handle.cancel()
            throw ProcessServiceError.cancelled
        }
        let stdout = String(data: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
        let stderr = String(data: err, encoding: .utf8) ?? String(decoding: err, as: UTF8.self)
        return (stdout, stderr, code)
    }
}
