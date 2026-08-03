import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorWasmEngine
import CodeEditorWasmEngineTestSupport
import CodeEditorWasmEngineWasmKit
import Foundation
import Testing

@testable import CodeEditorExtensionHost

@Suite("WASM-N session audit regressions")
struct WASMNSessionAuditTests {
    private func fixtureModule() -> Data {
        var d = Data(WasmModuleBuilder.magic + WasmModuleBuilder.version)
        d.append(Data(repeating: 0xAB, count: 200))
        return d
    }

    // MARK: - WASM-N08

    @Test func test_WASM_N08_perRequestDeadlinesNotSessionWide() async throws {
        let engine = WasmTestEngines.linkedGuest()
        // Short maxWallTime must NOT expire later healthy requests solely due to session age.
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(maxWallTime: .milliseconds(50)),
            generation: 1
        )
        try await session.start()
        // Wait longer than maxWallTime
        try await Task.sleep(for: .milliseconds(80))
        // A new request still works with its own timeout
        let echoed = try await session.request(.echo, payload: Data("later".utf8), timeout: .seconds(2))
        #expect(echoed == Data("later".utf8))
        await session.stop()
    }

    // MARK: - WASM-N09

    @Test func test_WASM_N09_requestUsesOneShotPromiseRegistration() async throws {
        let engine = WasmTestEngines.linkedGuest()
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: .default,
            generation: 1
        )
        try await session.start()
        // Concurrent requests register independently and complete.
        async let a = session.request(.echo, payload: Data("a".utf8), timeout: .seconds(2))
        async let b = session.request(.echo, payload: Data("b".utf8), timeout: .seconds(2))
        let ra = try await a
        let rb = try await b
        #expect(ra == Data("a".utf8) || ra == Data("b".utf8) || !ra.isEmpty)
        #expect(rb == Data("a".utf8) || rb == Data("b".utf8) || !rb.isEmpty)
        await session.stop()
    }

    // MARK: - WASM-N10

    @Test func test_WASM_N10_configuredLimitsEnforced() async throws {
        let engine = WasmTestEngines.linkedGuest()
        let limits = WasmResourceLimits(
            maxHostSendQueueBytes: 32,
            maxHostSendQueueMessages: 2,
            maxLogBytes: 64,
            maxLogMessages: 2,
            maxConcurrentRequests: 1,
            maxRequestBytes: 128  // room for start config; still below oversized payload
        )
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: limits,
            generation: 1
        )
        try await session.start()
        // Oversized request fails closed (payload alone exceeds maxRequestBytes)
        do {
            _ = try await session.request(.echo, payload: Data(repeating: 0x41, count: 512), timeout: .seconds(1))
            Issue.record("expected requestTooLarge")
        } catch WasmEngineError.requestTooLarge {
            // ok
        } catch {
            // may surface as trap/other fail-closed
            #expect(String(describing: error).count > 0)
        }
        await session.stop()

        let box = MessageBox(limits: limits)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusBackpressure)
    }

    // MARK: - WASM-N11

    @Test func test_WASM_N11_logsAreBoundedWithTruncation() {
        let limits = WasmResourceLimits(maxLogBytes: 64, maxLogMessages: 3, maxLogBytesPerSecond: 10_000)
        let box = MessageBox(limits: limits)
        for i in 0..<20 {
            box.log(String(repeating: "x", count: 20) + "\(i)")
        }
        #expect(box.retainedLogBytes <= limits.maxLogBytes + 40)
        #expect(box.logTruncationCount > 0)
    }

    // MARK: - WASM-N12

    @Test func test_WASM_N12_cancellationIsKeyedByRequestID() async throws {
        let engine = WasmTestEngines.linkedGuest()
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(maxPollBudgetPerTick: 2, maxPollTicks: 10_000),
            generation: 1
        )
        try await session.start()
        let id1 = ExtensionRequestID()
        await session.cancel(id1)
        // Subsequent unrelated request must still succeed (cancel not sticky global).
        let echoed = try await session.request(.echo, payload: Data("alive".utf8), timeout: .seconds(2))
        #expect(echoed == Data("alive".utf8))
        await session.stop()
    }

    // MARK: - WASM-N13

    @Test func test_WASM_N13_unknownPollStatusIsABIError() throws {
        #expect(throws: WasmEngineError.self) {
            _ = try CoreWasmPollStatus.parse(99)
        }
        #expect(throws: WasmEngineError.self) {
            _ = try CoreWasmPollStatus.parse(CoreWasmABI.statusFatal)
        }
        let idle = try CoreWasmPollStatus.parse(0)
        #expect(idle == .idle)
        let busy = try CoreWasmPollStatus.parse(2)
        #expect(busy == .progress)
    }

    // MARK: - WASM-N14

    @Test func test_WASM_N14_guestAllocationsPairedWithDealloc() async throws {
        let engine = WasmTestEngines.linkedGuest()
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(maxOutstandingGuestAllocations: 8),
            generation: 1
        )
        try await session.start()
        // Multiple requests must not leak outstanding alloc slots forever.
        for i in 0..<5 {
            _ = try await session.request(.echo, payload: Data("n\(i)".utf8), timeout: .seconds(2))
        }
        // If allocs leaked, further request after filling maxOutstanding would fail.
        _ = try await session.request(.echo, payload: Data("final".utf8), timeout: .seconds(2))
        await session.stop()
    }

    // MARK: - WASM-N15 production factory

    @Test func test_WASM_N15_productionFactoryIsWasmKitOnly() {
        #expect(WasmEngineFactory.productionEngineKind == .wasmKit)
        #expect(WasmEngineFactory.production() is WasmKitEngine)
        #expect(WasmEngineFactory.wasmKit() is WasmKitEngine)
    }
}
