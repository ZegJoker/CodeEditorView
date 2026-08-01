import Foundation
import Testing
import CodeEditorDAP

private final class TerminalCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _called = false
    private var _argCount = 0
    var called: Bool {
        lock.lock(); defer { lock.unlock() }
        return _called
    }
    var argCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _argCount
    }
    func mark(args: DAPRunInTerminalArgs) {
        lock.lock()
        _called = true
        _argCount = args.args.count
        lock.unlock()
    }
}

private struct RecordingTerminalHandler: DAPRunInTerminalHandler {
    let processId: Int
    let box: TerminalCallBox
    func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
        box.mark(args: args)
        return DAPRunInTerminalResult(processId: processId)
    }
}

@Suite("CodeEditorDAP session")
struct DAPSessionTests {
    @Test func fullRequestMatrixAgainstMock() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.start()

        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "mock",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "unused")
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        #expect(await session.state == .initialized)
        #expect(await session.capabilities.supportsConfigurationDoneRequest)

        try await session.launch(configuration: DAPJSONObject(["program": "/tmp/a.out"]))
        let afterLaunch = await session.state
        #expect(afterLaunch == .running || afterLaunch == .stopped)

        let bps = try await session.setBreakpoints(
            sourcePath: "/tmp/main.swift",
            breakpoints: [DAPSourceBreakpoint(line: 10)]
        )
        #expect(bps.count == 1)
        #expect(bps[0].verified)

        let fbps = try await session.setFunctionBreakpoints(["main"])
        #expect(fbps.count == 1)
        try await session.setExceptionBreakpoints(filters: ["all"])
        let ibps = try await session.setInstructionBreakpoints(addresses: ["0x1000"])
        #expect(ibps.count == 1)
        let dbps = try await session.setDataBreakpoints(dataIds: ["x"])
        #expect(dbps.count == 1)

        let threads = try await session.threads()
        #expect(threads.count == 1)
        let frames = try await session.stackTrace(threadId: 1)
        #expect(frames.count == 1)
        let scopes = try await session.scopes(frameId: frames[0].id)
        #expect(scopes.count == 1)
        let vars = try await session.variables(variablesReference: scopes[0].variablesReference)
        #expect(vars.contains { $0.name == "x" })
        let eval = try await session.evaluate(expression: "1+1", frameId: frames[0].id)
        #expect(eval.value.contains("eval"))
        _ = try await session.setVariable(variablesReference: 1000, name: "x", value: "99")
        _ = try await session.source(sourceReference: 1)
        _ = try await session.modules()
        _ = try await session.loadedSources()
        _ = try await session.disassemble(memoryReference: "0x1000")
        _ = try await session.readMemory(memoryReference: "0x1000", count: 4)
        try await session.writeMemory(memoryReference: "0x1000", data: "AA")
        _ = try await session.completions(text: "pr", column: 2, frameId: 1)

        try await session.next(threadId: 1)
        try await session.stepIn(threadId: 1)
        try await session.stepOut(threadId: 1)
        try await session.pause(threadId: 1)
        try await session.continue(threadId: 1)

        let commands = await mock.receivedCommands
        for required in [
            "initialize", "launch", "setBreakpoints", "setFunctionBreakpoints",
            "setExceptionBreakpoints", "setInstructionBreakpoints", "setDataBreakpoints",
            "threads", "stackTrace", "scopes", "variables", "evaluate", "setVariable",
            "source", "modules", "loadedSources", "disassemble", "readMemory", "writeMemory",
            "completions", "next", "stepIn", "stepOut", "pause", "continue",
        ] {
            #expect(commands.contains(required), "missing \(required)")
        }

        await session.disconnect()
        await mock.stop()
    }

    @Test func reverseRunInTerminal() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.setIssueRunInTerminalOnLaunch(true)
        await mock.start()

        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "mock-term",
                displayName: "Mock",
                launch: .test(factoryID: "x")
            ),
            transportFactory: { pair.client }
        )
        let box = TerminalCallBox()
        await session.setRunInTerminalHandler(RecordingTerminalHandler(processId: 4242, box: box))
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))

        // Reverse request is issued after launch response; wait for host handler.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if box.called { break }
        }
        #expect(box.called)
        #expect(box.argCount >= 1)

        await session.disconnect()
        await mock.stop()
    }

    @Test func poolTestFactoryAndRestart() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.start()
        let pool = DebugAdapterPool()
        let client = pair.client
        await pool.registerTestFactory(id: "f1") { client }

        let session = try await pool.adapter(for: DebugAdapterDefinition(
            id: "p1",
            displayName: "P",
            launch: .test(factoryID: "f1")
        ))
        #expect(await session.state == .initialized)
        try await session.launch(configuration: DAPJSONObject([:]))
        try await pool.restart(id: "p1", configuration: DAPJSONObject([:]))
        await pool.shutdownAll()
        await mock.stop()
    }
}
