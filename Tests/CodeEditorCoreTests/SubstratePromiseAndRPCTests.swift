import Foundation
import Testing
@testable import CodeEditorCore

@Suite("OneShotPromise and FramedRPCConnection substrate")
struct SubstratePromiseAndRPCTests {
    @Test func test_CORE_N02_oneShotPromiseCompletesExactlyOnce() async throws {
        let promise = OneShotPromise<Int>()
        let waiter = Task {
            try await promise.wait()
        }
        // Yield so waiter is registered.
        await Task.yield()
        let first = promise.complete(.success(42))
        let second = promise.complete(.success(99))
        #expect(first == true)
        #expect(second == false)
        let value = try await waiter.value
        #expect(value == 42)
    }

    @Test func test_CORE_N02_oneShotPromiseResponseBeforeWait() async throws {
        let promise = OneShotPromise<String>()
        _ = promise.complete(.success("early"))
        let value = try await promise.wait()
        #expect(value == "early")
    }

    @Test func test_CORE_N02_oneShotPromiseDeadlineTimeout() async throws {
        let clock = TestDeadlineClock()
        let promise = OneShotPromise<Int>()
        let deadline = await clock.now.advanced(by: .milliseconds(10))
        let task = Task {
            try await promise.wait(until: deadline, clock: clock)
        }
        await clock.advance(by: .milliseconds(20))
        do {
            _ = try await task.value
            Issue.record("expected timeout")
        } catch let error as OneShotPromiseError {
            #expect(error == .timedOut)
        }
    }

    @Test func test_CORE_N02_framedRPCLifecycleCancelTimeoutLateResponse() async throws {
        let transport = InMemoryByteTransport()
        let peer = transport.peer
        let conn = FramedRPCConnection(codec: JSONRPCCodec(), transport: transport)
        await conn.start()

        // Server-side responder — always reply immediately with method tag.
        let server = Task {
            var decoder = ContentLengthFrameDecoder()
            for await chunk in peer.inbound {
                let frames = decoder.append(chunk)
                for frame in frames {
                    guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                        let id = obj["id"] as? Int,
                        let method = obj["method"] as? String
                    else { continue }
                    // Deliberate delay for "slow" so client can timeout/cancel first.
                    if method == "slow" {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                    let response: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": ["method": method, "echo": obj["params"] ?? NSNull()],
                    ]
                    if let body = try? JSONSerialization.data(withJSONObject: response) {
                        try? await peer.write(ContentLengthFraming.encode(body))
                    }
                }
            }
        }

        // Happy path
        let echoed = try await conn.request(
            method: "echo",
            params: ["v": 1],
            deadline: .now + .seconds(5)
        )
        let echoObj = try JSONSerialization.jsonObject(with: echoed) as? [String: Any]
        #expect(echoObj?["method"] as? String == "echo")

        // Timeout path — deadline shorter than server delay.
        var timedOut = false
        do {
            _ = try await conn.request(
                method: "slow",
                params: nil as [String: Any]?,
                deadline: .now + .milliseconds(10)
            )
            Issue.record("expected RPC timeout")
        } catch let error as FramedRPCError {
            timedOut = (error == .timedOut || error == .cancelled)
            #expect(error == .timedOut || error == .cancelled)
        } catch let error as OneShotPromiseError {
            timedOut = (error == .timedOut)
            #expect(error == .timedOut)
        }
        #expect(timedOut)

        // Cancel path
        let pending = Task {
            try await conn.request(
                method: "slow",
                params: nil as [String: Any]?,
                deadline: .now + .seconds(30)
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        pending.cancel()
        var sawCancel = false
        do {
            _ = try await pending.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            sawCancel = true
        } catch let error as FramedRPCError {
            sawCancel = (error == .cancelled)
        } catch let error as OneShotPromiseError {
            sawCancel = (error == .cancelled)
        }
        #expect(sawCancel)

        // Late responses must not crash; connection stays usable after deadline/cancel.
        try await Task.sleep(nanoseconds: 150_000_000)
        let lateMetric = await conn.lateResponseCount
        #expect(lateMetric >= 1)

        let stillWorks = try await conn.request(
            method: "echo",
            params: ["ok": true],
            deadline: .now + .seconds(5)
        )
        let stillObj = try JSONSerialization.jsonObject(with: stillWorks) as? [String: Any]
        #expect(stillObj?["method"] as? String == "echo")

        await conn.close(reason: .clientShutdown)
        server.cancel()
    }

    @Test func test_CORE_N02_boundedByteSpoolCapsAndMetrics() async {
        let spool = BoundedByteSpool(maxBytes: 8)
        let r1 = await spool.append(Data("abcdef".utf8))
        #expect(r1.acceptedBytes == 6)
        #expect(r1.truncated == false)
        let r2 = await spool.append(Data("ghijkl".utf8))
        #expect(r2.truncated || r2.acceptedBytes < 6)
        let total = await spool.storedByteCount
        #expect(total <= 8)
        let dropped = await spool.droppedByteCount
        #expect(dropped > 0)
    }

    @Test func test_TASK_N03_boundedByteSpoolViewportSequenceRanges() async {
        let spool = BoundedByteSpool(maxBytes: 16, overflow: .dropOldest)
        _ = await spool.append(Data("0123456789".utf8))
        let overflow = await spool.append(Data("ABCDEFGHIJ".utf8))
        #expect(overflow.truncated)
        let base = await spool.baseOffset
        #expect(base > 0)
        let stored = await spool.storedByteCount
        #expect(stored <= 16)
        let total = await spool.totalAppendedBytes
        #expect(total == 20)
        let end = await spool.absoluteEndOffset
        #expect(end == total)
        #expect(end == base + UInt64(stored))
        let head = await spool.read(from: 0, maxBytes: 8)
        #expect(head.leadingTruncated)
        #expect(head.absoluteOffset == base)
        #expect(head.data.count == 8)
        #expect(head.availableStart == base)
        #expect(head.availableEnd == end)
        let mid = await spool.read(from: base, maxBytes: 4)
        #expect(!mid.leadingTruncated)
        #expect(mid.data.count == 4)
        let past = await spool.read(from: end + 10, maxBytes: 4)
        #expect(past.data.isEmpty)
        #expect(past.absoluteOffset == end)
    }
}
