import CodeEditorExtensionProtocol
import CodeEditorWasmEngine
import CodeEditorWasmEngineTestSupport
import Foundation
import Testing

@Suite("Wasm engine limits and modules")
struct WasmEngineTests {
    @Test func rejectsOversizedModule() throws {
        let engine = InProcessCoreWasmEngine()
        let big = Data(repeating: 0, count: 100)
        var module = Data(WasmModuleBuilder.magic + WasmModuleBuilder.version)
        module.append(big)
        // still small - test size limit explicitly
        let huge = Data(repeating: 1, count: 1024)
        var m = Data(WasmModuleBuilder.magic + WasmModuleBuilder.version) + huge
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: m, limits: WasmResourceLimits(maxModuleBytes: 32))
        }
    }

    @Test func rejectsMalformed() throws {
        let engine = InProcessCoreWasmEngine()
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: WasmModuleBuilder.malformedModule(), limits: .default)
        }
    }

    @Test func rejectsMissingExport() async throws {
        let engine = InProcessCoreWasmEngine()
        let imports = WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { 0 },
            shouldCancel: { _, _ in 0 }
        )
        do {
            _ = try await engine.instantiate(
                module: WasmModuleBuilder.missingExportModule(),
                imports: imports,
                limits: .default
            )
            Issue.record("expected missing export")
        } catch WasmEngineError.missingExport {
            // ok
        }
    }

    @Test func infiniteLoopInterruptedByTickCap() async throws {
        let engine = InProcessCoreWasmEngine()
        let imports = WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { 0 },
            shouldCancel: { _, _ in 0 }
        )
        let limits = WasmResourceLimits(maxPollBudgetPerTick: 1, maxPollTicks: 5)
        let inst = try await engine.instantiate(
            module: WasmModuleBuilder.infiniteLoopModule(),
            imports: imports,
            limits: limits
        )
        var threw = false
        for _ in 0..<20 {
            do {
                _ = try await inst.call(CoreWasmExport.poll.rawValue, args: [WasmValue.i32(1)])
            } catch {
                threw = true
                break
            }
        }
        #expect(threw)
        #expect(inst.isInterrupted || threw)
    }
}
