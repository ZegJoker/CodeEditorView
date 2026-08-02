import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorDAP

// MARK: - Helpers

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ condition: @Sendable () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
            Issue.record("timeout waiting for condition")
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeMockSession(
    id: String = "dapn"
) async throws -> (DebugAdapterSession, MockDebugAdapter, DAPTestTransport, DAPTestTransport) {
    let pair = DAPTestTransport.makePair()
    let mock = MockDebugAdapter(transport: pair.server)
    await mock.start()
    let session = DebugAdapterSession(
        definition: DebugAdapterDefinition(
            id: DebugAdapterID(rawValue: id),
            displayName: "Mock",
            languages: ["swift"],
            launch: .test(factoryID: id)
        ),
        budgets: DAPServerBudgets(requestTimeout: .seconds(2)),
        transportFactory: { pair.client }
    )
    try await session.start()
    return (session, mock, pair.client, pair.server)
}

// MARK: - DAP-N01

@Suite("DAP-N01 request registration")
struct DAPN01RequestRegistrationTests {
    @Test func test_DAP_N01_pendingRegisteredBeforeTimeoutWithoutUnstructuredTask() async throws {
        let pair = DAPTestTransport.makePair()
        // Never responds — client must time out cleanly without orphaning registration.
        let conn = DAPJSONRPCConnection(
            transport: pair.client,
            requestTimeout: .milliseconds(30)
        )
        await conn.start()
        var timedOut = false
        do {
            _ = try await conn.requestDictionary("slow/method", arguments: nil)
            Issue.record("expected timeout")
        } catch let error as DAPError {
            if case .timeout = error { timedOut = true }
        }
        #expect(timedOut)
        // Late response must be discarded, not retained for reuse (DAP-N02 also).
        let late: [String: Any] = [
            "seq": 99,
            "type": "response",
            "request_seq": 1,
            "success": true,
            "command": "slow/method",
            "body": ["ok": true],
        ]
        let body = try JSONSerialization.data(withJSONObject: late)
        try await pair.server.send(DAPMessageFraming.encode(body))
        try await Task.sleep(nanoseconds: 30_000_000)
        let lateCount = await conn.lateResponseCount
        #expect(lateCount >= 1)
        let early = await conn.earlyResponseCount
        #expect(early == 0)
        // Connection remains usable for next request after late discard.
        let echoServer = Task {
            for await chunk in pair.server.inbound {
                let messages = DAPMessageFraming.Decoder().append(chunk)
                for msg in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any],
                        let seq = obj["seq"] as? Int
                    else { continue }
                    let response: [String: Any] = [
                        "seq": seq + 1000,
                        "type": "response",
                        "request_seq": seq,
                        "success": true,
                        "command": obj["command"] as? String ?? "",
                        "body": ["v": 1],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(DAPMessageFraming.encode(data))
                }
            }
        }
        let result = try await conn.requestDictionary("echo", arguments: DAPJSONObject([:]))
        #expect(result.dictionary["v"] as? Int == 1)
        echoServer.cancel()
        await conn.close()
    }

    @Test func test_DAP_N01_responseBeforeWaitCompletesWithoutEarlyMap() async throws {
        let pair = DAPTestTransport.makePair()
        let serverTask = Task {
            for await chunk in pair.server.inbound {
                let messages = DAPMessageFraming.Decoder().append(chunk)
                for body in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let seq = obj["seq"] as? Int
                    else { continue }
                    let response: [String: Any] = [
                        "seq": seq + 1000,
                        "type": "response",
                        "request_seq": seq,
                        "success": true,
                        "command": obj["command"] as? String ?? "",
                        "body": ["instant": true],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(DAPMessageFraming.encode(data))
                }
            }
        }
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(2))
        await conn.start()
        for i in 0..<40 {
            let r = try await conn.requestDictionary("ping", arguments: DAPJSONObject(["i": i]))
            #expect(r.dictionary["instant"] as? Bool == true)
        }
        #expect(await conn.earlyResponseCount == 0)
        #expect(await conn.lateResponseCount == 0)
        serverTask.cancel()
        await conn.close()
    }

    @Test func test_DAP_N01_usesOneShotPromiseNotUnstructuredRegistrationTask() async throws {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources/CodeEditorDAP/Transport/DAPJSONRPCConnection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("OneShotPromise"))
        #expect(!source.contains("registerPendingThenSend"))
        #expect(!source.contains("earlyResponses"))
        #expect(!source.contains("executeRegisteredRequest"))
        #expect(!source.contains("Task { await self.registerPendingThenSend"))
    }
}

// MARK: - DAP-N02

@Suite("DAP-N02 late responses discarded")
struct DAPN02LateResponseTests {
    @Test func test_DAP_N02_orphanResponseDiscardedNotCachedAsEarly() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(1))
        await conn.start()
        // Orphan response with no pending request.
        let orphan: [String: Any] = [
            "seq": 1,
            "type": "response",
            "request_seq": 999,
            "success": true,
            "command": "never-sent",
            "body": ["should": "discard"],
        ]
        let data = try JSONSerialization.data(withJSONObject: orphan)
        try await pair.server.send(DAPMessageFraming.encode(data))
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(await conn.lateResponseCount >= 1)
        #expect(await conn.earlyResponseCount == 0)
        // Source contract: no earlyResponses map.
        let source = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Sources/CodeEditorDAP/Transport/DAPJSONRPCConnection.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("earlyResponses"))
        #expect(source.contains("lateResponseCount"))
        await conn.close()
    }
}

// MARK: - DAP-N03

@Suite("DAP-N03 message lanes")
struct DAPN03MessageLaneTests {
    @Test func test_DAP_N03_slowReverseRequestDoesNotStallResponse() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(3))
        await conn.start()

        final class Box: @unchecked Sendable {
            var reverseStarted = false
            var reverseFinished = false
        }
        let box = Box()

        await conn.setReverseRequestHandler { command, _, _ in
            if command == "runInTerminal" {
                box.reverseStarted = true
                try await Task.sleep(nanoseconds: 200_000_000)
                box.reverseFinished = true
                return DAPJSONObject(["processId": 1])
            }
            throw DAPError.unsupported(command)
        }

        let server = Task {
            let decoder = DAPMessageFraming.Decoder()
            for await chunk in pair.server.inbound {
                let messages = decoder.append(chunk)
                for body in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let seq = obj["seq"] as? Int
                    else { continue }
                    // Slow reverse request BEFORE response.
                    let reverse: [String: Any] = [
                        "seq": 50_000,
                        "type": "request",
                        "command": "runInTerminal",
                        "arguments": ["args": ["echo"]],
                    ]
                    let reverseData = try! JSONSerialization.data(withJSONObject: reverse)
                    try? await pair.server.send(DAPMessageFraming.encode(reverseData))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    let response: [String: Any] = [
                        "seq": seq + 1000,
                        "type": "response",
                        "request_seq": seq,
                        "success": true,
                        "command": obj["command"] as? String ?? "",
                        "body": ["done": true],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(DAPMessageFraming.encode(data))
                }
            }
        }

        let start = ContinuousClock.now
        let result = try await conn.requestDictionary("fast", arguments: nil)
        let elapsed = ContinuousClock.now - start
        #expect(result.dictionary["done"] as? Bool == true)
        #expect(elapsed < .milliseconds(150))
        #expect(box.reverseFinished == false || elapsed < .milliseconds(150))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(box.reverseFinished)
        server.cancel()
        await conn.close()
    }

    @Test func test_DAP_N03_slowEventDoesNotStallResponse() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(3))
        await conn.start()

        final class Box: @unchecked Sendable {
            var eventFinished = false
        }
        let box = Box()
        await conn.setEventHandler { event, _ in
            if event == "slowOutput" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                box.eventFinished = true
            }
        }

        let server = Task {
            let decoder = DAPMessageFraming.Decoder()
            for await chunk in pair.server.inbound {
                let messages = decoder.append(chunk)
                for body in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let seq = obj["seq"] as? Int
                    else { continue }
                    let event: [String: Any] = [
                        "seq": 60_000,
                        "type": "event",
                        "event": "slowOutput",
                        "body": ["output": "x"],
                    ]
                    let eventData = try! JSONSerialization.data(withJSONObject: event)
                    try? await pair.server.send(DAPMessageFraming.encode(eventData))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    let response: [String: Any] = [
                        "seq": seq + 1000,
                        "type": "response",
                        "request_seq": seq,
                        "success": true,
                        "command": obj["command"] as? String ?? "",
                        "body": ["ok": true],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(DAPMessageFraming.encode(data))
                }
            }
        }

        let start = ContinuousClock.now
        let result = try await conn.requestDictionary("fast2", arguments: nil)
        let elapsed = ContinuousClock.now - start
        #expect(result.dictionary["ok"] as? Bool == true)
        #expect(elapsed < .milliseconds(150))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(box.eventFinished)
        server.cancel()
        await conn.close()
    }

    @Test func test_DAP_N03_stateOrderedEventsPreserveOrder() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client)
        await conn.start()
        final class Box: @unchecked Sendable {
            var events: [String] = []
        }
        let box = Box()
        await conn.setEventHandler { event, _ in
            try? await Task.sleep(nanoseconds: 5_000_000)
            box.events.append(event)
        }
        for name in ["stopped", "continued", "terminated"] {
            let msg: [String: Any] = [
                "seq": 1,
                "type": "event",
                "event": name,
                "body": [:],
            ]
            let data = try JSONSerialization.data(withJSONObject: msg)
            try await pair.server.send(DAPMessageFraming.encode(data))
        }
        try await waitUntil { box.events.count >= 3 }
        #expect(box.events == ["stopped", "continued", "terminated"])
        await conn.close()
    }

    @Test func test_DAP_N03_classifyLanesPresent() async throws {
        #expect(DAPJSONRPCConnection.classify(type: "response", event: nil, command: nil) == .response)
        #expect(DAPJSONRPCConnection.classify(type: "request", event: nil, command: "runInTerminal") == .reverseRequest)
        #expect(DAPJSONRPCConnection.classify(type: "event", event: "stopped", command: nil) == .stateOrdered)
        #expect(DAPJSONRPCConnection.classify(type: "event", event: "output", command: nil) == .independent)
    }
}

// MARK: - DAP-N04

@Suite("DAP-N04 reverse request fail-closed")
struct DAPN04ReverseRequestTests {
    @Test func test_DAP_N04_missingReverseHandlerReturnsFailedNotEmptySuccess() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client)
        await conn.start()
        // No reverse handler installed.

        final class Box: @unchecked Sendable {
            var responses: [[String: Any]] = []
        }
        let box = Box()
        let capture = Task {
            let decoder = DAPMessageFraming.Decoder()
            for await chunk in pair.server.inbound {
                for body in decoder.append(chunk) {
                    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        obj["type"] as? String == "response"
                    {
                        box.responses.append(obj)
                    }
                }
            }
        }

        let reverse: [String: Any] = [
            "seq": 42,
            "type": "request",
            "command": "runInTerminal",
            "arguments": ["args": ["echo"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: reverse)
        try await pair.server.send(DAPMessageFraming.encode(data))
        try await waitUntil { box.responses.count >= 1 }
        capture.cancel()

        #expect(box.responses.count >= 1)
        let resp = box.responses[0]
        #expect(resp["success"] as? Bool == false)
        #expect(resp["request_seq"] as? Int == 42)
        let message = resp["message"] as? String ?? ""
        #expect(!message.isEmpty, "failed reverse response must include explanatory message")
        #expect(
            message.localizedCaseInsensitiveContains("runInTerminal")
                || message.localizedCaseInsensitiveContains("handler")
                || message.localizedCaseInsensitiveContains("unsupported")
                || message.localizedCaseInsensitiveContains("not found")
        )
        // Must not be empty-success body.
        if let success = resp["success"] as? Bool, success {
            Issue.record("missing reverse handler must not return success")
        }
        await conn.close()
    }

    @Test func test_DAP_N04_unknownReverseCommandFailsNotEmptySuccess() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client)
        await conn.start()
        await conn.setReverseRequestHandler { command, _, _ in
            throw DAPError.unsupported("reverse request \(command)")
        }

        final class Box: @unchecked Sendable {
            var responses: [[String: Any]] = []
        }
        let box = Box()
        let capture = Task {
            let decoder = DAPMessageFraming.Decoder()
            for await chunk in pair.server.inbound {
                for body in decoder.append(chunk) {
                    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        obj["type"] as? String == "response"
                    {
                        box.responses.append(obj)
                    }
                }
            }
        }

        let reverse: [String: Any] = [
            "seq": 7,
            "type": "request",
            "command": "customWeird",
            "arguments": [:],
        ]
        try await pair.server.send(DAPMessageFraming.encode(try JSONSerialization.data(withJSONObject: reverse)))
        try await waitUntil { box.responses.count >= 1 }
        capture.cancel()
        #expect(box.responses.first?["success"] as? Bool == false)
        let msg = box.responses.first?["message"] as? String ?? ""
        #expect(msg.contains("customWeird") || msg.contains("unsupported"))
        await conn.close()
    }
}

// MARK: - DAP-N05

@Suite("DAP-N05 session state machine")
struct DAPN05SessionStateTests {
    @Test func test_DAP_N05_noForceUnwrapOnConnectionInSessionSource() throws {
        let source = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Sources/CodeEditorDAP/DebugAdapterSession.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("connection!"))
        #expect(source.contains("invalidState") || source.contains("requireConnection"))
        #expect(source.contains("terminating") || source.contains(".terminating"))
        #expect(source.contains("initializing") || source.contains(".initializing"))
    }

    @Test func test_DAP_N05_publicMethodsRejectInvalidState() async throws {
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "idle-only",
                displayName: "Idle",
                launch: .test(factoryID: "missing")
            )
        )
        #expect(await session.state == .idle)
        var threw = false
        do {
            _ = try await session.threads()
            Issue.record("threads on idle must throw")
        } catch let error as DAPError {
            threw = true
            if case .invalidState = error {
                // preferred
            } else if case .notRunning = error {
                // acceptable typed fail-closed
            } else if case .notInitialized = error {
                // acceptable
            } else {
                Issue.record("expected invalidState/notRunning/notInitialized, got \(error)")
            }
        }
        #expect(threw)
    }

    @Test func test_DAP_N05_teardownDoesNotCrashAndEndsTerminated() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n05-life")
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        await session.disconnect()
        let state = await session.state
        #expect(state == .terminated || state == .stopped)
        // Double disconnect / post-teardown ops must not force-unwrap.
        await session.disconnect()
        var postThrow = false
        do {
            _ = try await session.threads()
            Issue.record("post-disconnect threads must fail closed")
        } catch {
            postThrow = true
        }
        #expect(postThrow)
        await mock.stop()
    }

    @Test func test_DAP_N05_startFailureIsFailedNotForceUnwrap() async throws {
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "fail",
                displayName: "Fail",
                launch: .test(factoryID: "missing")
            ),
            transportFactory: { throw DAPError.transport("boom") }
        )
        do {
            try await session.start()
            Issue.record("expected start failure")
        } catch {
            // expected
        }
        #expect(await session.state == .failed)
        var again = false
        do {
            _ = try await session.stackTrace(threadId: 1)
        } catch {
            again = true
        }
        #expect(again)
    }
}

// MARK: - DAP-N06

@Suite("DAP-N06 requested vs verified breakpoints")
struct DAPN06BreakpointStateTests {
    @Test func test_DAP_N06_requestedAndVerifiedStoredSeparately() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        // Adapter verifies at line 12 even though client requested 10.
        await mock.setBreakpointLineOffset(2)
        await mock.start()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "n06",
                displayName: "N06",
                launch: .test(factoryID: "n06")
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))

        let path = "/tmp/n06.swift"
        let verified = try await session.setBreakpoints(
            sourcePath: path,
            breakpoints: [DAPSourceBreakpoint(line: 10, condition: "x > 0")]
        )
        #expect(verified.count == 1)
        #expect(verified[0].verified)
        #expect(verified[0].line == 12, "verified line comes from adapter, not requested")

        let requested = await session.requestedBreakpoints(sourcePath: path)
        #expect(requested.count == 1)
        #expect(requested[0].line == 10, "requested line must remain as client asked")
        #expect(requested[0].condition == "x > 0")

        let verifiedStored = await session.verifiedBreakpoints(sourcePath: path)
        #expect(verifiedStored.count == 1)
        #expect(verifiedStored[0].line == 12)
        #expect(verifiedStored[0].verified)

        await session.disconnect()
        await mock.stop()
    }

    @Test func test_DAP_N06_rejectedBreakpointNotCommittedAsVerified() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.setRejectAllBreakpoints(true)
        await mock.start()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "n06-rej",
                displayName: "N06",
                launch: .test(factoryID: "n06r")
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        let path = "/tmp/reject.swift"
        let result = try await session.setBreakpoints(
            sourcePath: path,
            breakpoints: [DAPSourceBreakpoint(line: 5)]
        )
        #expect(result.count == 1)
        #expect(result[0].verified == false)
        let requested = await session.requestedBreakpoints(sourcePath: path)
        #expect(requested.count == 1)
        #expect(requested[0].line == 5)
        let verified = await session.verifiedBreakpoints(sourcePath: path)
        #expect(verified.allSatisfy { !$0.verified })
        await session.disconnect()
        await mock.stop()
    }
}

// MARK: - DAP-N07

@Suite("DAP-N07 mock adapter not in production")
struct DAPN07MockLocationTests {
    @Test func test_DAP_N07_mockDebugAdapterNotInProductionSources() throws {
        let root = repoRoot()
        let productionPaths = [
            "Sources/CodeEditorDAP/Testing/MockDebugAdapter.swift",
            "Sources/CodeEditorDAP/MockDebugAdapter.swift",
            "Sources/CodeEditorDAP/Testing/DAPTestTransport.swift",
        ]
        for rel in productionPaths {
            let path = root.appendingPathComponent(rel).path
            #expect(
                !FileManager.default.fileExists(atPath: path),
                "must not ship \(rel) as production"
            )
        }
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Tests/CodeEditorDAPTests/Support/MockDebugAdapter.swift").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Tests/CodeEditorDAPTests/Support/DAPTestTransport.swift").path
            )
        )
        // Public API baseline must not expose MockDebugAdapter.
        let publicAPI = root.appendingPathComponent("Baselines/api/CodeEditorDAP.public.txt")
        if FileManager.default.fileExists(atPath: publicAPI.path) {
            let text = try String(contentsOf: publicAPI, encoding: .utf8)
            #expect(!text.contains("MockDebugAdapter"))
            #expect(!text.contains("DAPTestTransport"))
        }
    }
}

// MARK: - DAP-N08

@Suite("DAP-N08 TerminalService-only runInTerminal")
struct DAPN08RunInTerminalTests {
    @Test func test_DAP_N08_productionRunInTerminalUsesTerminalServiceNotSessionManager() throws {
        let root = repoRoot()
        // Ghostty handler is the production DAP bridge and must use TerminalService.
        let ghostty = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodeEditorTerminalGhostty/GhosttyRunInTerminalHandler.swift"
            ),
            encoding: .utf8
        )
        #expect(ghostty.contains("TerminalService"))
        #expect(!ghostty.contains("TerminalSessionManager"))
        #expect(ghostty.contains("DAPRunInTerminalHandler"))

        // Legacy ExtensionHost bridge must also route via TerminalService only.
        let hostHandler = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodeEditorExtensionHost/Debug/TerminalDAPRunInTerminalHandler.swift"
            ),
            encoding: .utf8
        )
        #expect(hostHandler.contains("TerminalService"))
        // Production must not type-reference the legacy session manager API.
        #expect(!hostHandler.contains("TerminalSessionManager"))
        #expect(!hostHandler.contains(": TerminalSessionManager"))
        #expect(!hostHandler.contains("manager: TerminalSessionManager"))
        // Production host file must not embed mock handler types.
        #expect(!hostHandler.contains("struct MockTerminalDAPRunInTerminalHandler"))
        #expect(!hostHandler.contains("MockTerminalBackend"))
    }

    @Test func test_DAP_N08_sessionReverseRunInTerminalInvokesInjectedHandler() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.setIssueRunInTerminalOnLaunch(true)
        await mock.start()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "n08",
                displayName: "N08",
                launch: .test(factoryID: "n08")
            ),
            transportFactory: { pair.client }
        )
        final class Box: @unchecked Sendable {
            var called = false
            var args: [String] = []
        }
        let box = Box()
        struct H: DAPRunInTerminalHandler {
            let box: Box
            func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
                box.called = true
                box.args = args.args
                return DAPRunInTerminalResult(processId: 55, shellProcessId: 55)
            }
        }
        await session.setRunInTerminalHandler(H(box: box))
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        try await waitUntil { box.called }
        #expect(box.called)
        #expect(!box.args.isEmpty)
        await session.disconnect()
        await mock.stop()
    }
}

// MARK: - DAP-N09

@Suite("DAP-N09 stable DAP workflow")
struct DAPN09WorkflowTests {
    @Test func test_DAP_N09_endToEndWorkflowMatrix() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n09")
        #expect(await session.capabilities.supportsConfigurationDoneRequest)

        // launch + configurationDone
        try await session.launch(configuration: DAPJSONObject(["program": "/tmp/a.out"]))
        let afterLaunch = await session.state
        #expect(afterLaunch == .running || afterLaunch == .stopped)

        // breakpoints (source/function/data/instruction) + reconciliation
        let bps = try await session.setBreakpoints(
            sourcePath: "/tmp/main.swift",
            breakpoints: [DAPSourceBreakpoint(line: 10)]
        )
        #expect(bps[0].verified)
        _ = try await session.setFunctionBreakpoints(["main"])
        try await session.setExceptionBreakpoints(filters: ["all"])
        _ = try await session.setInstructionBreakpoints(addresses: ["0x1000"])
        _ = try await session.setDataBreakpoints(dataIds: ["x"])

        // continue/pause/step
        try await session.pause(threadId: 1)
        try await session.continue(threadId: 1)
        try await session.next(threadId: 1)
        try await session.stepIn(threadId: 1)
        try await session.stepOut(threadId: 1)

        // inspection
        let threads = try await session.threads()
        #expect(!threads.isEmpty)
        let frames = try await session.stackTrace(threadId: threads[0].id)
        #expect(!frames.isEmpty)
        let scopes = try await session.scopes(frameId: frames[0].id)
        #expect(!scopes.isEmpty)
        let vars = try await session.variables(variablesReference: scopes[0].variablesReference)
        #expect(vars.contains { $0.name == "x" && $0.value == "42" })
        let eval = try await session.evaluate(expression: "x", frameId: frames[0].id, context: "watch")
        #expect(!eval.value.isEmpty)
        _ = try await session.evaluate(expression: "1+1", frameId: frames[0].id, context: "repl")

        // source mapping / modules
        _ = try await session.source(sourceReference: 1)
        _ = try await session.modules()
        _ = try await session.loadedSources()

        // exception info when supported
        if await session.capabilities.supportsExceptionInfoRequest {
            _ = try await session.exceptionInfo(threadId: 1)
        } else {
            // Mock should advertise + implement after DAP-N09.
            Issue.record("capabilities should include supportsExceptionInfoRequest for stable matrix")
        }

        // Lifecycle state after steps.
        let midState = await session.state
        #expect(midState == .running || midState == .stopped || midState == .configured)

        // disconnect / terminate / restart path
        try await session.restart(configuration: DAPJSONObject(["program": "/tmp/a.out"]))
        await session.disconnect(terminateDebuggee: true)
        let endState = await session.state
        #expect(endState == .terminated || endState == .stopped)

        let commands = await mock.receivedCommands
        for required in [
            "initialize", "launch", "configurationDone", "setBreakpoints",
            "threads", "stackTrace", "scopes", "variables", "evaluate",
            "continue", "pause", "next", "stepIn", "stepOut", "disconnect",
        ] {
            #expect(commands.contains(required), "missing \(required)")
        }
        await mock.stop()
    }

    @Test func test_DAP_N09_attachPathAndErrorSurfaces() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n09-attach")
        try await session.attach(configuration: DAPJSONObject(["pid": 1]))
        let state = await session.state
        #expect(state == .running || state == .stopped)
        // Malformed/timeout surfaces as typed errors after close.
        await session.disconnect()
        var timedOut = false
        // Fresh connection that never answers.
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .milliseconds(40))
        await conn.start()
        do {
            _ = try await conn.requestDictionary("hang", arguments: nil)
        } catch let error as DAPError {
            if case .timeout = error { timedOut = true }
        }
        #expect(timedOut)
        await conn.close()
        await mock.stop()
    }
}

// MARK: - DAP-N10

@Suite("DAP-N10 real DAP lldb-dap gate")
struct DAPN10RealDAPGateTests {
    @Test func test_DAP_N10_checkRealDapIsIntegrationFixtureNotProbeOnly() throws {
        let root = repoRoot()
        let script = root.appendingPathComponent("scripts/check-real-dap.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("lldb-dap"))
        #expect(text.contains("initialize"))
        #expect(text.contains("launch"))
        #expect(text.contains("setBreakpoints"))
        #expect(text.contains("stackTrace"))
        #expect(text.contains("variables"))
        #expect(text.contains("evaluate"))
        #expect(text.contains("disconnect"))
        #expect(text.contains("REQUIRE_REAL_DAP"))
        #expect(text.contains("Fixtures/DAP") || text.contains("Tests/Fixtures/DAP"))
        #expect(text.contains("full session") || text.contains("complete lifecycle"))
        #expect(text.contains("process cleanup") || text.contains("SIGTERM") || text.contains("terminateDebuggee"))
        // Must hard-fail when required and missing adapter.
        #expect(text.contains("FAIL") && text.contains("REQUIRE_REAL_DAP"))
    }

    @Test func test_DAP_N10_fixtureFilesPresent() throws {
        let root = repoRoot()
        let fixture = root.appendingPathComponent("Tests/Fixtures/DAP")
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        let src = fixture.appendingPathComponent("smoke.c")
        #expect(FileManager.default.fileExists(atPath: src.path))
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(text.contains("codeeditor-dap-smoke"))
        #expect(text.contains("breakpoint_here") || text.contains("int x"))
        let readme = fixture.appendingPathComponent("README.md")
        #expect(FileManager.default.fileExists(atPath: readme.path))
    }

    @Test func test_DAP_N10_executesIntegrationSessionScript() throws {
        let root = repoRoot()
        let script = root.appendingPathComponent("scripts/check-real-dap.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["REQUIRE_REAL_DAP"] = env["REQUIRE_REAL_DAP"] ?? "0"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = stdout + stderr
        #expect(
            process.terminationStatus == 0,
            "check-real-dap.sh failed status=\(process.terminationStatus) out=\(combined)"
        )
        let hasFullSession =
            (combined.contains("full session") || combined.contains("complete lifecycle"))
            && (
                combined.contains("initialize")
                    || combined.contains("launch")
                    || combined.contains("breakpoint")
            )
        let hasSoftNoBinaries =
            (combined.contains("no real DAP") || combined.contains("no lldb-dap"))
            && (combined.contains("fixtures present") || combined.contains("soft mode"))
        #expect(
            hasFullSession || hasSoftNoBinaries,
            "expected full session or soft no-binaries OK; got: \(combined)"
        )
        if combined.contains("found") && combined.contains("lldb-dap") {
            #expect(hasFullSession, "lldb-dap present but full session line missing: \(combined)")
        }
    }

    @Test func test_DAP_N10_inProcessIntegrationSessionSteps() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n10session")
        try await session.launch(configuration: DAPJSONObject(["program": "/tmp/smoke"]))
        let bps = try await session.setBreakpoints(
            sourcePath: "/tmp/smoke.c",
            breakpoints: [DAPSourceBreakpoint(line: 5)]
        )
        #expect(bps.count == 1)
        let threads = try await session.threads()
        #expect(!threads.isEmpty)
        let frames = try await session.stackTrace(threadId: 1)
        #expect(!frames.isEmpty)
        let scopes = try await session.scopes(frameId: frames[0].id)
        let vars = try await session.variables(variablesReference: scopes[0].variablesReference)
        #expect(vars.contains { $0.name == "x" })
        _ = try await session.evaluate(expression: "x", frameId: frames[0].id)
        await session.disconnect(terminateDebuggee: true)
        let commands = await mock.receivedCommands
        for required in ["initialize", "launch", "setBreakpoints", "stackTrace", "variables", "evaluate", "disconnect"] {
            #expect(commands.contains(required), "missing \(required)")
        }
        await mock.stop()
    }

    @Test func test_DAP_N10_hardFailsWhenRequiredAndMissingAdapter() throws {
        let root = repoRoot()
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-dap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/check-real-dap.sh").path]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["REQUIRE_REAL_DAP"] = "1"
        env["CODEEDITOR_DAP_SEARCH_PATH"] = empty.path
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        let combined =
            (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            + (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        #expect(combined.contains("FAIL"))
    }
}
