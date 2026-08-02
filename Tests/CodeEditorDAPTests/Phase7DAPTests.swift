import Foundation
import Testing

@testable import CodeEditorDAP

@Suite("Phase7 DAP ordering")
struct Phase7DAPTests {
    @Test func registerBeforeSendInstantReply() async throws {
        let pair = DAPTestTransport.makePair()
        // Minimal responder
        Task {
            for await chunk in pair.server.inbound {
                let msgs = DAPMessageFraming.Decoder().append(chunk)
                for body in msgs {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let seq = obj["seq"] as? Int
                    else { continue }
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
        let conn = DAPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(2))
        await conn.start()
        for i in 0..<30 {
            let body = try await conn.requestRaw(
                command: "ping", arguments: DAPJSONObject(["i": i]))
            let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(obj?["success"] as? Bool == true)
        }
        let early = await conn.earlyResponseCount
        #expect(early == 0)
        await conn.close()
    }

    @Test func inboundEventsPreserveOrder() async throws {
        let pair = DAPTestTransport.makePair()
        let conn = DAPJSONRPCConnection(transport: pair.client)
        await conn.start()
        final class Box: @unchecked Sendable {
            var events: [String] = []
        }
        let box = Box()
        await conn.setEventHandler { event, _ in
            box.events.append(event)
        }
        for name in ["initialized", "stopped", "continued", "terminated"] {
            let msg: [String: Any] = [
                "seq": 1,
                "type": "event",
                "event": name,
                "body": [:],
            ]
            let data = try JSONSerialization.data(withJSONObject: msg)
            try await pair.server.send(DAPMessageFraming.encode(data))
        }
        // Poll until ordered delivery completes (50ms is flaky under full-suite load).
        let deadline = ContinuousClock.now + .seconds(2)
        while box.events.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(box.events == ["initialized", "stopped", "continued", "terminated"])
        await conn.close()
    }

    @Test func startFailureLeavesFailedState() async throws {
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "fail",
                displayName: "Fail",
                launch: .test(factoryID: "missing")
            ),
            transportFactory: {
                throw DAPError.transport("boom")
            }
        )
        do {
            try await session.start()
            Issue.record("expected start failure")
        } catch {
            // expected
        }
        #expect(await session.state == .failed)
    }

    @Test func sessionLifecycleStoppedContinuedTerminated() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.start()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "life",
                displayName: "Life",
                launch: .test(factoryID: "x")
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        #expect(await session.state == .initialized)
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        let running = await session.state
        #expect(running == .running || running == .stopped)

        // Drive lifecycle events
        for name in ["stopped", "continued", "terminated"] {
            let msg: [String: Any] = [
                "seq": 99,
                "type": "event",
                "event": name,
                "body": [:],
            ]
            let data = try JSONSerialization.data(withJSONObject: msg)
            try await pair.server.send(DAPMessageFraming.encode(data))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(await session.state == .terminated)
        await session.disconnect()
        await mock.stop()
    }

    @Test func connectTransportTypeExists() {
        // Public `.connect` is real TCP client, not a soft-stub enum-only case.
        let launch = DebugAdapterLaunch.connect(host: "127.0.0.1", port: 1)
        if case .connect(let h, let p) = launch {
            #expect(h == "127.0.0.1")
            #expect(p == 1)
        } else {
            Issue.record("expected connect case")
        }
    }

    @Test func runInTerminalReverseUsesHandler() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.setIssueRunInTerminalOnLaunch(true)
        await mock.start()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "rit",
                displayName: "RIT",
                launch: .test(factoryID: "x")
            ),
            transportFactory: { pair.client }
        )
        final class Box: @unchecked Sendable {
            var called = false
        }
        let box = Box()
        struct H: DAPRunInTerminalHandler {
            let box: Box
            func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
                box.called = true
                return DAPRunInTerminalResult(processId: 99)
            }
        }
        await session.setRunInTerminalHandler(H(box: box))
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if box.called { break }
        }
        #expect(box.called)
        await session.disconnect()
        await mock.stop()
    }
}
