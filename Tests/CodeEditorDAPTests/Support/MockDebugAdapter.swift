import CodeEditorDAP
import Foundation

/// Scripted DAP adapter covering the claimed protocol surface for fixtures.
public actor MockDebugAdapter {
    private let transport: any DAPTransport
    private var readerTask: Task<Void, Never>?
    private let decoder = DAPMessageFraming.Decoder()
    private var seq: Int = 1
    private var running = false
    private var stopped = false
    /// When true, issues reverse `runInTerminal` after launch.
    public var issueRunInTerminalOnLaunch: Bool = false
    /// Added to requested line when verifying source breakpoints (DAP-N06 fixtures).
    public var breakpointLineOffset: Int = 0
    /// When true, all source breakpoints are returned unverified (DAP-N06).
    public var rejectAllBreakpoints: Bool = false
    public private(set) var receivedCommands: [String] = []
    public private(set) var reverseRunInTerminalResult: DAPJSONObject?

    public func setIssueRunInTerminalOnLaunch(_ value: Bool) {
        issueRunInTerminalOnLaunch = value
    }

    public func setBreakpointLineOffset(_ value: Int) {
        breakpointLineOffset = value
    }

    public func setRejectAllBreakpoints(_ value: Bool) {
        rejectAllBreakpoints = value
    }

    public init(transport: any DAPTransport) {
        self.transport = transport
    }

    public func start() {
        guard readerTask == nil else { return }
        running = true
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleInbound(chunk)
            }
        }
    }

    public func stop() async {
        running = false
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
    }

    private func handleInbound(_ chunk: Data) async {
        let messages = decoder.append(chunk)
        for body in messages {
            await handleMessage(body)
        }
    }

    private func handleMessage(_ body: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        // Host → adapter reverse-request responses
        if type == "response" {
            let requestSeq =
                (obj["request_seq"] as? Int)
                ?? (obj["request_seq"] as? NSNumber)?.intValue
            if let requestSeq {
                let bodyDict = obj["body"] as? [String: Any] ?? [:]
                reverseResponses[requestSeq] = bodyDict
            }
            return
        }

        guard type == "request",
            let command = obj["command"] as? String
        else { return }
        let requestSeq = (obj["seq"] as? Int) ?? (obj["seq"] as? NSNumber)?.intValue ?? 0
        guard requestSeq != 0 || obj["seq"] != nil else { return }

        receivedCommands.append(command)
        let args = obj["arguments"] as? [String: Any] ?? [:]

        switch command {
        case "initialize":
            try? await respond(requestSeq: requestSeq, command: command, body: fullCapabilities())
            try? await sendEvent("initialized", body: [:])
        case "launch":
            // Respond to launch first so the host is not blocked while we reverse-request.
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
            stopped = true
            try? await sendEvent(
                "stopped",
                body: [
                    "reason": "entry",
                    "threadId": 1,
                    "allThreadsStopped": true,
                ])
            if issueRunInTerminalOnLaunch {
                do {
                    let result = try await reverseRequest(
                        "runInTerminal",
                        arguments: [
                            "kind": "integrated",
                            "title": "Debug Console",
                            "args": ["echo", "debug"],
                            "cwd": args["cwd"] as? String ?? "/tmp",
                        ])
                    reverseRunInTerminalResult = DAPJSONObject(result)
                } catch {
                    reverseRunInTerminalResult = DAPJSONObject(["error": String(describing: error)])
                }
            }
        case "attach":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
            try? await sendEvent("stopped", body: ["reason": "attach", "threadId": 1])
        case "configurationDone":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
        case "disconnect", "terminate":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
            try? await sendEvent("terminated", body: [:])
        case "restart":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
        case "setBreakpoints":
            let bps = (args["breakpoints"] as? [[String: Any]]) ?? []
            let out = bps.enumerated().map { i, bp -> [String: Any] in
                let requested = bp["line"] as? Int ?? 1
                if rejectAllBreakpoints {
                    return [
                        "id": i + 1,
                        "verified": false,
                        "line": requested,
                        "message": "rejected by mock adapter",
                    ] as [String: Any]
                }
                return [
                    "id": i + 1,
                    "verified": true,
                    "line": requested + breakpointLineOffset,
                ] as [String: Any]
            }
            try? await respond(requestSeq: requestSeq, command: command, body: ["breakpoints": out])
        case "setFunctionBreakpoints":
            let bps = (args["breakpoints"] as? [[String: Any]]) ?? []
            let out = bps.enumerated().map { i, _ in ["id": 100 + i, "verified": true] as [String: Any] }
            try? await respond(requestSeq: requestSeq, command: command, body: ["breakpoints": out])
        case "setExceptionBreakpoints":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
        case "setInstructionBreakpoints":
            let bps = (args["breakpoints"] as? [[String: Any]]) ?? []
            let out = bps.enumerated().map { i, _ in ["id": 200 + i, "verified": true] as [String: Any] }
            try? await respond(requestSeq: requestSeq, command: command, body: ["breakpoints": out])
        case "setDataBreakpoints":
            let bps = (args["breakpoints"] as? [[String: Any]]) ?? []
            let out = bps.enumerated().map { i, _ in ["id": 300 + i, "verified": true] as [String: Any] }
            try? await respond(requestSeq: requestSeq, command: command, body: ["breakpoints": out])
        case "threads":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "threads": [["id": 1, "name": "main"]]
                ])
        case "stackTrace":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "stackFrames": [
                        [
                            "id": 1,
                            "name": "main",
                            "line": 10,
                            "column": 1,
                            "source": ["path": "/tmp/main.swift", "name": "main.swift"],
                        ]
                    ],
                    "totalFrames": 1,
                ])
        case "scopes":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "scopes": [
                        [
                            "name": "Locals",
                            "variablesReference": 1000,
                            "expensive": false,
                        ]
                    ]
                ])
        case "variables":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "variables": [
                        [
                            "name": "x",
                            "value": "42",
                            "type": "Int",
                            "variablesReference": 0,
                        ]
                    ]
                ])
        case "evaluate":
            let expr = args["expression"] as? String ?? ""
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "result": "eval(\(expr))",
                    "type": "String",
                    "variablesReference": 0,
                ])
        case "setVariable":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "value": args["value"] as? String ?? "",
                    "type": "String",
                    "variablesReference": 0,
                ])
        case "continue":
            stopped = false
            try? await respond(requestSeq: requestSeq, command: command, body: ["allThreadsContinued": true])
            try? await sendEvent("continued", body: ["threadId": args["threadId"] as? Int ?? 1])
        case "next", "stepIn", "stepOut":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
            try? await sendEvent("stopped", body: ["reason": "step", "threadId": args["threadId"] as? Int ?? 1])
        case "pause":
            try? await respond(requestSeq: requestSeq, command: command, body: [:])
            try? await sendEvent("stopped", body: ["reason": "pause", "threadId": args["threadId"] as? Int ?? 1])
        case "source":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "content": "func main() {}",
                    "mimeType": "text/x-swift",
                ])
        case "modules":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "modules": [["id": "1", "name": "App"]]
                ])
        case "loadedSources":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "sources": [["path": "/tmp/main.swift", "name": "main.swift"]]
                ])
        case "disassemble":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "instructions": [["address": "0x1000", "instruction": "nop"]]
                ])
        case "readMemory":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "address": args["memoryReference"] as? String ?? "0x0",
                    "data": "AAEC",
                ])
        case "writeMemory":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "bytesWritten": 2
                ])
        case "completions":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "targets": [["label": "print", "text": "print", "type": "function"]]
                ])
        case "exceptionInfo":
            try? await respond(
                requestSeq: requestSeq, command: command,
                body: [
                    "exceptionId": "EXC_BAD_ACCESS",
                    "description": "mock exception",
                    "breakMode": "always",
                ])
        default:
            try? await respond(requestSeq: requestSeq, command: command, success: false, message: "unknown \(command)")
        }
    }

    private func fullCapabilities() -> [String: Any] {
        [
            "supportsConfigurationDoneRequest": true,
            "supportsFunctionBreakpoints": true,
            "supportsConditionalBreakpoints": true,
            "supportsHitConditionalBreakpoints": true,
            "supportsEvaluateForHovers": true,
            "supportsSetVariable": true,
            "supportsCompletionsRequest": true,
            "supportsModulesRequest": true,
            "supportsRestartRequest": true,
            "supportsLoadedSourcesRequest": true,
            "supportsTerminateRequest": true,
            "supportsDataBreakpoints": true,
            "supportsReadMemoryRequest": true,
            "supportsWriteMemoryRequest": true,
            "supportsDisassembleRequest": true,
            "supportsCancelRequest": true,
            "supportsInstructionBreakpoints": true,
            "supportsExceptionInfoRequest": true,
            "supportTerminateDebuggee": true,
        ]
    }

    private func respond(
        requestSeq: Int,
        command: String,
        body: [String: Any] = [:],
        success: Bool = true,
        message: String? = nil
    ) async throws {
        seq += 1
        var obj: [String: Any] = [
            "seq": seq,
            "type": "response",
            "request_seq": requestSeq,
            "success": success,
            "command": command,
            "body": body,
        ]
        if let message { obj["message"] = message }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await transport.send(DAPMessageFraming.encode(data))
    }

    private func sendEvent(_ event: String, body: [String: Any]) async throws {
        seq += 1
        let obj: [String: Any] = [
            "seq": seq,
            "type": "event",
            "event": event,
            "body": body,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await transport.send(DAPMessageFraming.encode(data))
    }

    private func reverseRequest(_ command: String, arguments: [String: Any]) async throws -> [String: Any] {
        seq += 1
        let requestSeq = seq
        let obj: [String: Any] = [
            "seq": requestSeq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await transport.send(DAPMessageFraming.encode(data))

        // Wait for reverse response by scanning subsequent inbound (simplified: short sleep + drain)
        // The host connection handles reverse response asynchronously; we parse from transport peer.
        // For in-process pair, host will respond; collect next response matching request_seq.
        return try await waitForResponse(requestSeq: requestSeq)
    }

    private func waitForResponse(requestSeq: Int) async throws -> [String: Any] {
        // Poll decoder by reading more inbound with timeout
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            // Non-blocking: messages already processed in handleInbound; store reverse responses
            if let cached = reverseResponses[requestSeq] {
                reverseResponses[requestSeq] = nil
                return cached
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw DAPError.timeout(method: "runInTerminal")
    }

    private var reverseResponses: [Int: [String: Any]] = [:]

    // Re-process responses that are reverse replies in handleMessage for type==response
}
