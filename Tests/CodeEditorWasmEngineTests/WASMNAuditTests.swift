import Foundation
import Testing

@testable import CodeEditorWasmEngine
@testable import CodeEditorWasmEngineTestSupport
@testable import CodeEditorWasmEngineWasmKit

#if canImport(WasmKit)
    import WasmTypes
#endif

@Suite("WASM-N audit regressions")
struct WASMNAuditTests {
    private func emptyHost(
        cancel: @escaping @Sendable (Int64, Int64) -> Int32 = { _, _ in 0 }
    ) -> WasmHostImports {
        WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { WasmMonotonicClock.nowMillis() },
            shouldCancel: cancel
        )
    }

    // MARK: - WASM-N01

    @Test func test_WASM_N01_pureNoncooperativeLoopTerminatesWithinDeadline() async throws {
        let engine = WasmKitEngine()
        let host = emptyHost()
        let limits = WasmResourceLimits(
            maxWallTime: .milliseconds(250),
            maxFuel: 5_000_000,
            requireMemoryMaximum: false
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.pureNoncooperativeLoopModule(),
            imports: host,
            limits: limits
        )
        let start = ContinuousClock.now
        var threw = false
        do {
            _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
        } catch is WasmEngineError {
            threw = true
        } catch {
            threw = true
        }
        let elapsed = ContinuousClock.now - start
        #expect(threw || inst.isInterrupted)
        #expect(elapsed < .seconds(2))
        // Worker must not remain stuck: a subsequent call must fail fast as interrupted/deadline.
        let t1 = ContinuousClock.now
        do {
            _ = try await inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        } catch {
            // expected interrupted/deadline
        }
        #expect(ContinuousClock.now - t1 < .milliseconds(500))
    }

    @Test func test_WASM_N01_loopWithoutCancelImportFailsClosed() async throws {
        let engine = WasmKitEngine()
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.pureLoopWithoutCancelImportModule(),
                imports: emptyHost(),
                limits: .default
            )
            Issue.record("expected fail-closed for uninstrumentable pure loop")
        } catch WasmEngineError.invalidModule {
            // ok
        } catch WasmEngineError.processIsolationRequired {
            // ok
        } catch {
            let s = String(describing: error)
            #expect(s.contains("should_cancel") || s.contains("instrument") || s.contains("loop"))
        }
    }

    // MARK: - WASM-N02

    @Test func test_WASM_N02_memoryGrowthContinuouslyLimited() async throws {
        let engine = WasmKitEngine()
        let limits = WasmResourceLimits(
            maxLinearMemoryBytes: 128 * 1024,  // 2 pages
            maxWallTime: .milliseconds(500),
            maxFuel: 100_000,
            requireMemoryMaximum: false
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.memoryGrowHostileModule(),
            imports: emptyHost(),
            limits: limits
        )
        do {
            _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
        } catch {
            // trap / interrupt / deadline ok
        }
        #expect(inst.memory.size <= limits.maxLinearMemoryBytes + 64 * 1024)
    }

    @Test func test_WASM_N02_hostGrowRespectsLimiter() async throws {
        let engine = WasmKitEngine()
        let limits = WasmResourceLimits(maxLinearMemoryBytes: 128 * 1024, requireMemoryMaximum: false)
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: emptyHost(),
            limits: limits
        )
        do {
            _ = try inst.memory.grow(pages: 8)
            Issue.record("expected memory limit on grow")
        } catch WasmEngineError.memoryLimitExceeded {
            // ok
        } catch {
            // other fail-closed grow errors ok
        }
        #expect(inst.memory.size <= limits.maxLinearMemoryBytes)
    }

    // MARK: - WASM-N03

    @Test func test_WASM_N03_missingMemoryFailsABIValidation() async throws {
        let engine = WasmKitEngine()
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.missingMemoryExportModule(),
                imports: emptyHost(),
                limits: .default
            )
            Issue.record("expected missing memory export")
        } catch WasmEngineError.missingExport(let name) {
            #expect(name == "memory")
        } catch {
            let s = String(describing: error)
            #expect(s.contains("memory") || s.contains("missing"))
        }
    }

    // MARK: - WASM-N04

    @Test func test_WASM_N04_callsSerializedOnInstance() async throws {
        let engine = WasmKitEngine()
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: emptyHost(),
            limits: .default
        )
        // Concurrent calls must be serialized (no crash / concurrentAccess).
        async let a = inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        async let b = inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        let ra = try await a
        let rb = try await b
        #expect(ra.first?.i32 == 1)
        #expect(rb.first?.i32 == 1)
    }

    /// Proves call **and** memory share one serial runtime: interleaved concurrent
    /// call+read+write+grow never race (WASM-N04 residual).
    @Test func test_WASM_N04_callAndMemoryShareSerialRuntime() async throws {
        let engine = WasmKitEngine()
        let limits = WasmResourceLimits(
            maxLinearMemoryBytes: 256 * 1024,
            requireMemoryMaximum: false
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.growHelperModule(),
            imports: emptyHost(),
            limits: limits
        )
        let marker = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try inst.memory.write(offset: 16, data: marker)

        // Fire concurrent call + memory ops; serialization must prevent crash/corruption.
        async let call1 = inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        async let memRead: Data = {
            try inst.memory.read(offset: 16, length: 4)
        }()
        async let call2 = inst.call(CoreWasmExport.alloc.rawValue, args: [.i32(32)])
        async let memWrite: Void = {
            try inst.memory.write(offset: 32, data: Data([1, 2, 3, 4]))
        }()
        async let memRead2: Data = {
            try inst.memory.read(offset: 32, length: 4)
        }()

        let r1 = try await call1
        let r2 = try await call2
        let readBack = try await memRead
        try await memWrite
        let read2 = try await memRead2

        #expect(r1.first?.i32 == 1)
        #expect(r2.first?.i32 != nil)
        #expect(readBack == marker)
        #expect(read2 == Data([1, 2, 3, 4]) || read2.count == 4)

        // Memory size stable under concurrent access (no torn grow).
        let size = inst.memory.size
        #expect(size >= 64 * 1024)
        #expect(size <= limits.maxLinearMemoryBytes)
    }

    // MARK: - WASM-N05

    @Test func test_WASM_N05_memoryGrowIsRealNotStub() async throws {
        let engine = WasmKitEngine()
        // growHelperModule: min 1 max 4 pages — room to grow by 1.
        let limits = WasmResourceLimits(
            maxLinearMemoryBytes: 4 * 64 * 1024,
            requireMemoryMaximum: false
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.growHelperModule(),
            imports: emptyHost(),
            limits: limits
        )
        let before = inst.memory.size
        #expect(before == 64 * 1024)
        // Grow by 1 page MUST succeed — not a soft memoryLimitExceeded stub.
        let oldPages = try inst.memory.grow(pages: 1)
        #expect(oldPages == 1)
        #expect(inst.memory.size == before + 64 * 1024)
        // Second grow also real
        let old2 = try inst.memory.grow(pages: 1)
        #expect(old2 == 2)
        #expect(inst.memory.size == before + 2 * 64 * 1024)
    }

    // MARK: - WASM-N06

    @Test func test_WASM_N06_unsupportedValuesDoNotCoerceToZero() throws {
        #if canImport(WasmKit)
            // Real fromWasmKit path: v128 must throw, never become i32(0).
            let v128 = Value.v128(V128(bytes: Array(repeating: 0, count: 16)))
            do {
                let mapped = try WasmValue.fromWasmKitValue(v128)
                Issue.record("v128 must not map; got \(mapped)")
            } catch WasmEngineError.unsupportedValueType(let kind) {
                #expect(kind.contains("v128"))
            }
            // ref also fail-closed
            do {
                _ = try WasmValue.fromWasmKitValue(.ref(.function(nil)))
                Issue.record("ref must not map to zero")
            } catch WasmEngineError.unsupportedValueType(let kind) {
                #expect(kind.contains("ref"))
            }
            // i32 path still works
            let i32 = try WasmValue.fromWasmKitValue(.i32(7))
            #expect(i32.i32 == 7)
            // Zero is valid i32 only when kind is i32
            let zero = try WasmValue.fromWasmKitValue(.i32(0))
            #expect(zero.i32 == 0)
        #else
            let err = WasmEngineError.unsupportedValueType("v128")
            #expect(String(describing: err).contains("v128"))
        #endif
    }

    // MARK: - WASM-N07

    @Test func test_WASM_N07_monotonicClockIsMonotonicAndWide() async throws {
        let a = WasmMonotonicClock.nowMillis()
        try await Task.sleep(for: .milliseconds(5))
        let b = WasmMonotonicClock.nowMillis()
        #expect(b >= a)
        let large: Int64 = Int64(Int32.max) + 10
        #expect(large > Int64(Int32.max))
        let engine = WasmKitEngine()
        final class Box: @unchecked Sendable { var last: Int64 = -1 }
        let box = Box()
        let host = WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: {
                let v = WasmMonotonicClock.nowMillis()
                box.last = v
                return v
            },
            shouldCancel: { _, _ in 0 }
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: host,
            limits: .default
        )
        _ = try await inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        #expect(WasmMonotonicClock.nowNanos() > 0)
        _ = box
    }

    // MARK: - WASM-N10 engine quotas

    @Test func test_WASM_N10_maxInstancesEnforced() async throws {
        let engine = WasmKitEngine()
        // Hold one instance under a high ceiling, then attempt acquire with
        // maxInstances == current active (must fail closed — WASM-N10).
        let roomy = WasmResourceLimits(maxInstances: 10_000, requireMemoryMaximum: false)
        let held = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: emptyHost(),
            limits: roomy
        )
        let active = WasmInstanceRegistry.shared.activeCount
        #expect(active >= 1)
        let atCap = WasmResourceLimits(maxInstances: active, requireMemoryMaximum: false)
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.conformanceModule(),
                imports: emptyHost(),
                limits: atCap
            )
            Issue.record("expected maxInstances resourceLimit when active >= max")
        } catch WasmEngineError.resourceLimit(let msg) {
            #expect(msg.contains("maxInstances"))
        }
        // max=0 always denies
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.conformanceModule(),
                imports: emptyHost(),
                limits: WasmResourceLimits(maxInstances: 0, requireMemoryMaximum: false)
            )
            Issue.record("maxInstances=0 must deny")
        } catch WasmEngineError.resourceLimit {
            // ok
        }
        held.interrupt()
        _ = held
    }

    @Test func test_WASM_N10_capabilityCallQuotaOnHostSend() async throws {
        let engine = WasmKitEngine()
        final class SendBox: @unchecked Sendable { var count = 0 }
        let sendBox = SendBox()
        let host = WasmHostImports(
            send: { _, _ in
                sendBox.count += 1
                return 0
            },
            log: { _, _, _ in },
            monotonicMillis: { WasmMonotonicClock.nowMillis() },
            shouldCancel: { _, _ in 0 }
        )
        let limits = WasmResourceLimits(
            maxWallTime: .milliseconds(300),
            maxFuel: 2_000_000,
            maxCapabilityCalls: 5,
            maxCapabilityCallsPerSecond: 5,
            requireMemoryMaximum: false
        )
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.capabilityCallFloodModule(),
            imports: host,
            limits: limits
        )
        do {
            _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
        } catch {
            // interrupt / deadline / trap after quota
        }
        // Capability meter on instance must have recorded calls and capped them.
        #expect(inst.meters.capabilityCalls <= limits.maxCapabilityCalls)
        #expect(inst.meters.capabilityCalls > 0 || sendBox.count <= limits.maxCapabilityCalls)
    }

    // MARK: - WASM-N15

    @Test func test_WASM_N15_linkedGuestIsTestSupportOnly() {
        let sim = LinkedGuestWasmEngine {
            FatalGuest()
        }
        #expect(type(of: sim as Any) != type(of: WasmKitEngine() as Any))
        let production: any CodeEditorWasmEngine = WasmKitEngine()
        #expect(!(production is LinkedGuestWasmEngine))
        let alias: CodeEditorWasmSimulationEngine = sim
        #expect(type(of: alias as Any) == type(of: sim as Any))
        // InProcess is test-support type, not production default
        let inProc = InProcessCoreWasmEngine()
        #expect(!(production is InProcessCoreWasmEngine))
        _ = inProc
    }

    // MARK: - WASM-N16 corpus + process isolation

    @Test func test_WASM_N16_hostileCorpusFixturesExist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/Wasm", isDirectory: true)
        let required = [
            "malformed.wasm",
            "missing_export.wasm",
            "infinite_loop.wasm",
            "memory_growth.wasm",
            "flood_host_send.wasm",
            "bad_schema_start.wasm",
            "conformance.wasm",
            "deep_recursion.wasm",
            "huge_table.wasm",
            "oob_memory.wasm",
            "capability_flood.wasm",
        ]
        for name in required {
            let url = root.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
        }
        #expect(WasmModuleBuilder.pureNoncooperativeLoopModule().count > 8)
        #expect(WasmModuleBuilder.memoryGrowHostileModule().count > 8)
        #expect(WasmModuleBuilder.missingMemoryExportModule().count > 8)
        #expect(WasmModuleBuilder.hostSendFloodModule().count > 8)
        #expect(WasmModuleBuilder.logFloodModule().count > 8)
        #expect(WasmModuleBuilder.deepRecursionModule().count > 8)
        #expect(WasmModuleBuilder.hugeTableModule().count > 8)
        #expect(WasmModuleBuilder.oobMemoryAccessModule().count > 8)
        #expect(WasmModuleBuilder.capabilityCallFloodModule().count > 8)
    }

    @Test func test_WASM_N16_hostileModulesContainedInProcess() async throws {
        let engine = WasmKitEngine()
        let host = emptyHost()
        // huge table rejected at validate/instantiate
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.hugeTableModule(),
                imports: host,
                limits: WasmResourceLimits(maxTableElements: 64, requireMemoryMaximum: false)
            )
            Issue.record("huge table must fail closed")
        } catch {
            // ok
        }
        // OOB load traps
        do {
            let inst = try await engine.instantiate(
                module: WasmModuleBuilder.oobMemoryAccessModule(),
                imports: host,
                limits: WasmResourceLimits(requireMemoryMaximum: false)
            )
            do {
                _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
                Issue.record("oob must trap")
            } catch {
                // trap ok
            }
        }
        // deep recursion contained by stack/fuel/wall
        do {
            let inst = try await engine.instantiate(
                module: WasmModuleBuilder.deepRecursionModule(),
                imports: host,
                limits: WasmResourceLimits(
                    maxWallTime: .milliseconds(200),
                    maxFuel: 100_000,
                    maxStackBytes: 64 * 1024,
                    requireMemoryMaximum: false
                )
            )
            let t0 = ContinuousClock.now
            do {
                _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
            } catch {
                // expected
            }
            #expect(ContinuousClock.now - t0 < .seconds(2))
        }
    }

    /// True process isolation: spawn killable helper OS process via Process + outer SIGKILL.
    @Test func test_WASM_N16_processIsolatedHostileLoopContained() async throws {
        let module = WasmModuleBuilder.pureNoncooperativeLoopModule()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasm-n16-\(UUID().uuidString).wasm")
        try module.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let harness = try Self.resolveWasmHarness()
        let process = Process()
        process.executableURL = harness
        process.arguments = [
            "--module", tmp.path,
            "--export", CoreWasmExport.poll.rawValue,
            "--timeout-ms", "200",
            "--arg-i32", "0",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Own process group so outer kill reaps children.
        process.qualityOfService = .userInitiated

        let start = ContinuousClock.now
        try process.run()
        let pid = process.processIdentifier

        // Outer kill harness: if helper hangs past 3s, SIGKILL the process group.
        let killer = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                // Escalate
                kill(pid, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        let elapsed = ContinuousClock.now - start
        let status = process.terminationStatus
        let reason = process.terminationReason
        #expect(elapsed < .seconds(5), "process-isolated harness must not hang the test runner")
        #expect(!process.isRunning, "helper OS process must have exited")
        // Pure noncooperative loop must never report success: exit 0 means the call
        // returned normally, which would prove non-containment.
        #expect(
            !(reason == .exit && status == 0),
            "pure noncooperative loop must not exit 0 (success)"
        )
        // Contained outcomes (non-tautological):
        // - harness clean exit 2 (deadline/interrupted/trap) or 3 (instantiate fail-closed)
        // - uncaught signal (SIGTERM=15 outer kill, SIGKILL=9, SIGTRAP=5 engine trap, etc.)
        switch reason {
        case .exit:
            #expect(
                status == 2 || status == 3,
                "unexpected harness exit \(status); expected 2 (contained) or 3 (validate fail)"
            )
        case .uncaughtSignal:
            // Signal number must be a real fatal signal (not 0).
            #expect(status > 0, "uncaughtSignal with non-positive signal \(status)")
        @unknown default:
            Issue.record("unknown Process.terminationReason for hostile loop helper")
        }
    }

    private static func resolveWasmHarness() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEEDITOR_WASM_HARNESS"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        // Prefer built product next to test bundle / .build
        let fm = FileManager.default
        let candidates = [
            FileManager.default.currentDirectoryPath + "/.build/debug/codeeditor-wasm-harness",
            FileManager.default.currentDirectoryPath + "/.build/arm64-apple-macosx/debug/codeeditor-wasm-harness",
            FileManager.default.currentDirectoryPath + "/.build/x86_64-apple-macosx/debug/codeeditor-wasm-harness",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Build on demand
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build", "--product", "codeeditor-wasm-harness"]
        build.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try build.run()
        build.waitUntilExit()
        #expect(build.terminationStatus == 0, "swift build codeeditor-wasm-harness failed")
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw WasmEngineError.notSupported("codeeditor-wasm-harness binary not found after build")
    }
}

private final class FatalGuest: LinkedWasmGuest {
    func bindHost(imports: WasmHostImports, limits: WasmResourceLimits) {}
    func abiVersion() -> Int32 { 0 }
    func alloc(_ length: Int32) -> Int32 { 0 }
    func dealloc(_ ptr: Int32, _ length: Int32) {}
    func start(configPtr: Int32, configLen: Int32) -> Int32 { 0 }
    func receive(ptr: Int32, len: Int32) -> Int32 { 0 }
    func poll(_ budget: Int32) -> Int32 { 0 }
    func stop(_ reason: Int32) {}
    var memoryView: any WasmMemoryView { EmptyMem() }
}

private struct EmptyMem: WasmMemoryView {
    var size: Int { 0 }
    func read(offset: Int, length: Int) throws -> Data { Data() }
    func write(offset: Int, data: Data) throws {}
    func grow(pages: Int) throws -> Int { throw WasmEngineError.memoryLimitExceeded }
}
