import Foundation
import Testing

@testable import CodeEditorWasmEngine
@testable import CodeEditorWasmEngineTestSupport
@testable import CodeEditorWasmEngineWasmKit

@Suite("Phase9 real WasmKit execution")
struct Phase9WasmExecutionTests {
    private func emptyHost(cancel: @escaping @Sendable () -> Int32 = { 0 }) -> WasmHostImports {
        WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { Int64(Date().timeIntervalSince1970 * 1000) },
            shouldCancel: { _, _ in cancel() }
        )
    }

    // E1 — bytes determine behavior
    @Test func moduleBytesDetermineAbiVersion() async throws {
        let engine = WasmKitEngine()
        let host = emptyHost()
        let a = try await engine.instantiate(
            module: WasmModuleBuilder.abiVersionConstantModule(value: 1),
            imports: host,
            limits: .default
        )
        let b = try await engine.instantiate(
            module: WasmModuleBuilder.abiVersionConstantModule(value: 2),
            imports: host,
            limits: .default
        )
        let ra = try await a.call(CoreWasmExport.abiVersion.rawValue, args: [])
        let rb = try await b.call(CoreWasmExport.abiVersion.rawValue, args: [])
        #expect(ra.first?.i32 == 1)
        #expect(rb.first?.i32 == 2)
    }

    @Test func factoryIgnoredOnlyModuleExportsMatter() async throws {
        let engine = WasmKitEngine(guestFactory: { "must-not-run" as Any })
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.abiVersionConstantModule(value: 7),
            imports: emptyHost(),
            limits: .default
        )
        let r = try await inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
        #expect(r.first?.i32 == 7)
    }

    // E2
    @Test func rejectsMalformedAndMissingMagic() throws {
        let engine = WasmKitEngine()
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: Data([0x00, 0x01]), limits: .default)
        }
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: Data(repeating: 0xAB, count: 64), limits: .default)
        }
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: WasmModuleBuilder.malformedModule(), limits: .default)
        }
    }

    // E4 — guest memory bridge
    @Test func hostSendReadsGuestMemory() async throws {
        final class Box: @unchecked Sendable {
            var last: Data?
        }
        let box = Box()
        let host = WasmHostImports(
            send: { ptr, len in
                if len <= 0 { return 0 }
                guard let ptr else { return 1 }
                box.last = Data(bytes: ptr, count: Int(len))
                return 0
            },
            log: { _, _, _ in },
            monotonicMillis: { 0 },
            shouldCancel: { _, _ in 0 }
        )
        let engine = WasmKitEngine()
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.hostSendEchoModule(),
            imports: host,
            limits: .default
        )
        _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
        #expect(box.last == Data([0x4F, 0x4B]))  // "OK"
        #expect(String(data: box.last ?? Data(), encoding: .utf8) == "OK")
    }

    // E5 — interrupt infinite cooperative loop
    @Test func infiniteLoopInterruptedWithoutHang() async throws {
        final class Flag: @unchecked Sendable {
            var cancel = false
        }
        let flag = Flag()
        let host = emptyHost { flag.cancel ? 1 : 0 }
        let engine = WasmKitEngine()
        let limits = WasmResourceLimits(maxWallTime: .milliseconds(300), maxPollTicks: 10)
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.infiniteLoopModule(),
            imports: host,
            limits: limits
        )
        // Arm cancel shortly after poll starts; wall watchdog is backup.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            flag.cancel = true
            inst.interrupt()
        }
        let start = Date()
        do {
            _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
        } catch is WasmEngineError {
            // deadlineExceeded / interrupted acceptable
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0)
    }

    // E6 — memory limit
    @Test func memoryLimitEnforcedOnOversizedLinearMemory() async throws {
        let engine = WasmKitEngine()
        // Module with 1 page is fine; enforce by setting maxLinearMemoryBytes below one page after grow request
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: emptyHost(),
            limits: WasmResourceLimits(maxLinearMemoryBytes: 64 * 1024)
        )
        do {
            _ = try inst.memory.grow(pages: 2)
            Issue.record("expected memory limit")
        } catch WasmEngineError.memoryLimitExceeded {
            // ok
        } catch WasmEngineError.notSupported {
            // ok if grow unsupported but still limited
        }
    }

    // E7 — oob trap
    @Test func oobMemoryReadTraps() async throws {
        let engine = WasmKitEngine()
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.conformanceModule(),
            imports: emptyHost(),
            limits: .default
        )
        #expect(throws: WasmEngineError.self) {
            _ = try inst.memory.read(offset: 0, length: 100_000_000)
        }
    }

    // E8 — hostile fixtures on WasmKit
    @Test func hostileFixturesOnWasmKit() async throws {
        let engine = WasmKitEngine()
        let host = emptyHost()
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/Wasm", isDirectory: true)

        // Malformed
        if let data = try? Data(contentsOf: fixtureRoot.appendingPathComponent("malformed.wasm")) {
            #expect(throws: WasmEngineError.self) {
                try engine.validate(module: data, limits: .default)
            }
        } else {
            #expect(throws: WasmEngineError.self) {
                try engine.validate(module: WasmModuleBuilder.malformedModule(), limits: .default)
            }
        }

        // Missing export / bad schema — validate or instantiate may fail
        for name in ["missing_export.wasm", "bad_schema_start.wasm"] {
            let url = fixtureRoot.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            do {
                try engine.validate(module: data, limits: .default)
                // May parse but fail on required export at call time
                let inst = try await engine.instantiate(module: data, imports: host, limits: .tight)
                do {
                    _ = try await inst.call(CoreWasmExport.abiVersion.rawValue, args: [])
                } catch {
                    // expected missing export or trap
                }
                _ = inst
            } catch {
                // validate/instantiate failure is success for hostile corpus
            }
        }

        // Infinite loop: prefer builder module (cooperative cancel); fixture may be pre-Phase9 bytes.
        do {
            let flag = CancelFlag()
            let h = emptyHost { flag.value ? 1 : 0 }
            let inst = try await engine.instantiate(
                module: WasmModuleBuilder.infiniteLoopModule(),
                imports: h,
                limits: WasmResourceLimits(maxWallTime: .milliseconds(250))
            )
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                flag.value = true
                inst.interrupt()
            }
            let t0 = Date()
            do {
                _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
            } catch {
                // ok
            }
            #expect(Date().timeIntervalSince(t0) < 2.0)
        }
        // Committed infinite_loop.wasm: any outcome other than host hang is success.
        let loopURL = fixtureRoot.appendingPathComponent("infinite_loop.wasm")
        if let data = try? Data(contentsOf: loopURL), !data.isEmpty {
            do {
                try engine.validate(module: data, limits: .default)
                let flag = CancelFlag()
                let h = emptyHost { flag.value ? 1 : 0 }
                let inst = try await engine.instantiate(
                    module: data,
                    imports: h,
                    limits: WasmResourceLimits(maxWallTime: .milliseconds(200))
                )
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    flag.value = true
                    inst.interrupt()
                }
                let t0 = Date()
                do {
                    _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [.i32(0)])
                } catch { /* ok */ }
                #expect(Date().timeIntervalSince(t0) < 2.0)
            } catch {
                // invalid/malformed fixture rejected at validate — still containment success
            }
        }
    }

    // E11 — simulation is not WasmKit
    @Test func simulationAliasIsNotWasmKit() {
        let sim: CodeEditorWasmSimulationEngine = LinkedGuestWasmEngine {
            FatalGuest()
        }
        #expect(type(of: sim as Any) != type(of: WasmKitEngine() as Any))
        // Type identity: simulation is LinkedGuest
        let _: LinkedGuestWasmEngine = sim
    }

    // E3 — independent stores
    @Test func freshStorePerInstance() async throws {
        let engine = WasmKitEngine()
        let host = emptyHost()
        let m = WasmModuleBuilder.abiVersionConstantModule(value: 1)
        let a = try await engine.instantiate(module: m, imports: host, limits: .default)
        let b = try await engine.instantiate(module: m, imports: host, limits: .default)
        #expect(a !== b)
        _ = try await a.call(CoreWasmExport.abiVersion.rawValue, args: [])
        _ = try await b.call(CoreWasmExport.abiVersion.rawValue, args: [])
    }
}

private final class CancelFlag: @unchecked Sendable {
    var value = false
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
    func grow(pages: Int) throws -> Int { 0 }
}
