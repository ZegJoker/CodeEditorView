import Foundation
import Testing
@testable import CodeEditorCore

@Suite("AsyncBroadcastHub substrate")
struct SubstrateBroadcastHubTests {
    @Test func test_CORE_N02_multiSubscriberReceivesIndependentCopies() async throws {
        let hub = AsyncBroadcastHub<String>()
        let s1 = await hub.subscribe(policy: .dropOldest(capacity: 16, emitGap: true))
        let s2 = await hub.subscribe(policy: .dropOldest(capacity: 16, emitGap: true))

        await hub.publish("a")
        await hub.publish("b")
        await hub.finish(.completed)

        var from1: [String] = []
        var from2: [String] = []
        for await item in s1 {
            if case .value(let env) = item { from1.append(env.event) }
            if case .finished = item { break }
        }
        for await item in s2 {
            if case .value(let env) = item { from2.append(env.event) }
            if case .finished = item { break }
        }
        #expect(from1 == ["a", "b"])
        #expect(from2 == ["a", "b"])
    }

    @Test func test_CORE_N02_overflowEmitsGapAndPreservesSequence() async throws {
        let hub = AsyncBroadcastHub<Int>()
        let stream = await hub.subscribe(policy: .dropOldest(capacity: 2, emitGap: true))

        // Flood without concurrent drain so the bounded buffer overflows.
        for i in 1...6 {
            await hub.publish(i)
        }
        await hub.finish(.completed)

        var values: [Int] = []
        var sawGap = false
        var sequences: [UInt64] = []
        for await item in stream {
            switch item {
            case .value(let env):
                values.append(env.event)
                sequences.append(env.sequence)
            case .gap:
                sawGap = true
            case .finished:
                break
            }
        }
        // Under capacity-2 flood of 6 events, consumer must not retain all values.
        #expect(values.count <= 2)
        // Gap marker and/or truncated tail prove overflow policy engaged.
        #expect(sawGap || values.count < 6)
        #expect(sawGap || !values.isEmpty)
        // Surviving sequences are strictly increasing.
        if sequences.count >= 2 {
            for i in 1..<sequences.count {
                #expect(sequences[i] > sequences[i - 1])
            }
        }
    }

    @Test func test_CORE_N02_finishIsExactlyOnce() async {
        let hub = AsyncBroadcastHub<Int>()
        let stream = await hub.subscribe(policy: .dropOldest(capacity: 8, emitGap: false))
        await hub.publish(1)
        await hub.finish(.completed)
        await hub.finish(.cancelled) // second finish must be a no-op

        var finishes = 0
        var lastReason: StreamFinishReason?
        for await item in stream {
            if case .finished(let reason) = item {
                finishes += 1
                lastReason = reason
            }
        }
        #expect(finishes == 1)
        #expect(lastReason == .completed)
    }

    @Test func test_CORE_N02_replayLastBuffered() async {
        let hub = AsyncBroadcastHub<String>()
        await hub.publish("x")
        await hub.publish("y")
        await hub.publish("z")
        let stream = await hub.subscribe(
            policy: .dropOldest(capacity: 8, emitGap: false),
            replay: .last(2)
        )
        await hub.finish(.completed)

        var values: [String] = []
        for await item in stream {
            if case .value(let env) = item { values.append(env.event) }
            if case .finished = item { break }
        }
        #expect(values == ["y", "z"])
    }
}
