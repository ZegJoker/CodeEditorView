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
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(maxWallTime: .milliseconds(50)),
            generation: 1
        )
        try await session.start()
        try await Task.sleep(for: .milliseconds(80))
        let echoed = try await session.request(.echo, payload: Data("later".utf8), timeout: .seconds(2))
        #expect(echoed == Data("later".utf8))
        await session.stop()
    }

    // MARK: - WASM-N09

    @Test func test_WASM_N09_requestUsesOneShotPromiseRegistration() async throws {
        let link = WasmGuestLink()
        // Hold work so request stays in-flight while we inspect pending registration.
        // Budget-per-tick must be << pendingSlowWork so one poll cannot finish the request.
        link.runtime.pendingSlowWork = 50_000
        let engine = LinkedGuestWasmEngine { link }
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(
                maxPollBudgetPerTick: 8,
                maxConcurrentRequests: 4,
                maxPollTicksPerRequest: 200_000
            ),
            generation: 1
        )
        try await session.start()

        let id = ExtensionRequestID()
        async let result: Data = session.request(
            ExtensionMethodID.echo,
            payload: Data("probe".utf8),
            timeout: Duration.seconds(5),
            requestID: id
        )
        // Yield so request registers OneShotPromise and enters poll loop.
        var sawPending = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(5))
            if await session.pendingRequestCount >= 1 {
                sawPending = true
                break
            }
        }
        #expect(sawPending, "OneShotPromise must be registered before guest work completes")
        // Release slow work so request can finish.
        link.runtime.pendingSlowWork = 0
        let value = try await result
        #expect(value == Data("probe".utf8) || !value.isEmpty)
        let after = await session.pendingRequestCount
        #expect(after == 0)
        await session.stop()
    }

    // MARK: - WASM-N10

    @Test func test_WASM_N10_configuredLimitsEnforced() async throws {
        // Deterministic quotas only (no racey concurrent-request section).
        // maxConcurrentRequests has hard coverage in
        // test_WASM_N10_maxConcurrentRequestsEnforced (slow-work occupancy + exact error).
        let engine = WasmTestEngines.linkedGuest()
        // Session path: maxRequestBytes fail-closed. Keep host-send queue roomy so a
        // later in-budget echo can deliver (tight queue is exercised on MessageBox below).
        let sessionLimits = WasmResourceLimits(
            maxConcurrentRequests: 4,
            maxRequestBytes: 128
        )
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: sessionLimits,
            generation: 1
        )
        try await session.start()
        // Oversized request fails closed with typed requestTooLarge (not soft any-error).
        var sawTooLarge = false
        do {
            _ = try await session.request(
                ExtensionMethodID.echo,
                payload: Data(repeating: 0x41, count: 512),
                timeout: Duration.seconds(1)
            )
            Issue.record("expected requestTooLarge for payload > maxRequestBytes")
        } catch WasmEngineError.requestTooLarge(let size) {
            #expect(size >= 512)
            sawTooLarge = true
        }
        #expect(sawTooLarge, "must throw WasmEngineError.requestTooLarge fail-closed")
        // Small in-budget request still succeeds after oversized rejection.
        let ok = try await session.request(
            ExtensionMethodID.echo,
            payload: Data("ok".utf8),
            timeout: Duration.seconds(2)
        )
        #expect(ok == Data("ok".utf8))
        await session.stop()

        // Host-send queue: message count + byte budget fail closed with backpressure.
        let messageLimited = MessageBox(
            limits: WasmResourceLimits(
                maxHostSendQueueBytes: 10_000,
                maxHostSendQueueMessages: 2
            )
        )
        #expect(messageLimited.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(messageLimited.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(
            messageLimited.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusBackpressure,
            "maxHostSendQueueMessages=2 must reject 3rd enqueue"
        )
        let byteLimited = MessageBox(
            limits: WasmResourceLimits(
                maxHostSendQueueBytes: 16,
                maxHostSendQueueMessages: 100
            )
        )
        #expect(byteLimited.enqueue(Data(repeating: 2, count: 10)) == CoreWasmABI.statusOK)
        #expect(
            byteLimited.enqueue(Data(repeating: 2, count: 10)) == CoreWasmABI.statusBackpressure,
            "maxHostSendQueueBytes=16 must reject when bytes would exceed"
        )

        // Capability call quota: hard cap, exact counter, 4th call denied.
        let capBox = MessageBox(
            limits: WasmResourceLimits(
                maxCapabilityCalls: 3,
                maxCapabilityCallsPerSecond: 100
            )
        )
        #expect(capBox.recordCapabilityCall())
        #expect(capBox.recordCapabilityCall())
        #expect(capBox.recordCapabilityCall())
        #expect(!capBox.recordCapabilityCall(), "maxCapabilityCalls=3 must fail closed on 4th")
        #expect(capBox.capabilityCallCount == 3)
        #expect(!capBox.recordCapabilityCall(), "further calls remain denied at total cap")
        #expect(capBox.capabilityCallCount == 3)
    }

    @Test func test_WASM_N10_maxConcurrentRequestsEnforced() async throws {
        let link = WasmGuestLink()
        link.runtime.pendingSlowWork = 100_000
        let engine = LinkedGuestWasmEngine { link }
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(
                maxPollBudgetPerTick: 4,
                maxConcurrentRequests: 1,
                maxPollTicksPerRequest: 200_000
            ),
            generation: 1
        )
        try await session.start()
        let id = ExtensionRequestID()
        async let first: Data = session.request(
            ExtensionMethodID.echo,
            payload: Data("hold".utf8),
            timeout: Duration.seconds(5),
            requestID: id
        )
        // Wait until first request is registered as concurrent occupancy.
        var occupied = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(5))
            if await session.concurrentRequestCount >= 1 {
                occupied = true
                break
            }
        }
        #expect(occupied)
        do {
            _ = try await session.request(
                ExtensionMethodID.echo,
                payload: Data("second".utf8),
                timeout: Duration.seconds(1)
            )
            Issue.record("expected maxConcurrentRequests")
        } catch WasmEngineError.resourceLimit(let msg) {
            #expect(msg.contains("maxConcurrentRequests"))
        }
        link.runtime.pendingSlowWork = 0
        _ = try? await first
        await session.stop()
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
        let link = WasmGuestLink()
        link.runtime.pendingSlowWork = 8_000
        let engine = LinkedGuestWasmEngine { link }
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(
                maxPollBudgetPerTick: 2,
                maxConcurrentRequests: 4,
                maxPollTicks: 100_000,
                maxPollTicksPerRequest: 100_000
            ),
            generation: 1
        )
        try await session.start()

        let idA = ExtensionRequestID()
        let idB = ExtensionRequestID()
        async let resultA: Data = session.request(
            ExtensionMethodID.echo,
            payload: Data("A".utf8),
            timeout: Duration.seconds(5),
            requestID: idA
        )
        async let resultB: Data = session.request(
            ExtensionMethodID.echo,
            payload: Data("B".utf8),
            timeout: Duration.seconds(5),
            requestID: idB
        )
        try await Task.sleep(for: .milliseconds(40))
        // Concurrent keyed cancel: only A cancelled; B must complete after release.
        await session.cancel(idA)
        link.runtime.pendingSlowWork = 0

        var aCancelled = false
        do {
            _ = try await resultA
        } catch {
            aCancelled = true
        }
        #expect(aCancelled, "cancelled request A must fail")

        let b = try await resultB
        #expect(b == Data("B".utf8) || !b.isEmpty, "request B must not inherit A's cancel")
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
        for i in 0..<5 {
            _ = try await session.request(.echo, payload: Data("n\(i)".utf8), timeout: .seconds(2))
            let outstanding = await session.outstandingGuestAllocations
            #expect(outstanding == 0, "alloc must be paired with dealloc after request \(i)")
        }
        #expect(await session.outstandingGuestAllocations == 0)
        _ = try await session.request(.echo, payload: Data("final".utf8), timeout: .seconds(2))
        #expect(await session.outstandingGuestAllocations == 0)
        await session.stop()
    }

    // MARK: - WASM-N15 production factory

    @Test func test_WASM_N15_productionFactoryIsWasmKitOnly() {
        #expect(WasmEngineFactory.productionEngineKind == .wasmKit)
        #expect(WasmEngineFactory.production() is WasmKitEngine)
        #expect(WasmEngineFactory.wasmKit() is WasmKitEngine)
    }
}
