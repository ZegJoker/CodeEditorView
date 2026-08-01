import Foundation
import Testing
@testable import CodeEditorWasmEngine
@testable import CodeEditorWasmEngineWasmKit

@Suite("Real WasmKit execution (WASM-002)")
struct RealWasmExecutionTests {
    @Test func parseAndCallAbiVersionFromConformanceModule() async throws {
        let engine = WasmKitEngine()
        let module = WasmModuleBuilder.conformanceModule()
        try engine.validate(module: module, limits: .default)
        let host = WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { Int64(Date().timeIntervalSince1970 * 1000) },
            shouldCancel: { _, _ in 0 }
        )
        let instance = try await engine.instantiate(module: module, imports: host, limits: .default)
        let result = try await instance.call(CoreWasmExport.abiVersion.rawValue, args: [])
        #expect(result.first?.i32 == 1)
    }

    @Test func rejectsMalformedModule() throws {
        let engine = WasmKitEngine()
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: Data([0x00, 0x01, 0x02]), limits: .default)
        }
    }

    @Test func rejectsMissingMagic() throws {
        let engine = WasmKitEngine()
        var bytes = [UInt8](repeating: 0xAB, count: 64)
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: Data(bytes), limits: .default)
        }
        _ = bytes
    }

    @Test func moduleBytesDetermineBehaviorNotFactory() async throws {
        // Factory is ignored — only module exports matter.
        let engine = WasmKitEngine(guestFactory: { "should-not-run" as Any })
        let module = WasmModuleBuilder.abiVersionOnlyModule()
        let host = WasmHostImports(
            send: { _, _ in 0 },
            log: { _, _, _ in },
            monotonicMillis: { 0 },
            shouldCancel: { _, _ in 0 }
        )
        let instance = try await engine.instantiate(module: module, imports: host, limits: .default)
        let result = try await instance.call(CoreWasmExport.abiVersion.rawValue, args: [])
        #expect(result.first?.i32 == 1)
    }
}
