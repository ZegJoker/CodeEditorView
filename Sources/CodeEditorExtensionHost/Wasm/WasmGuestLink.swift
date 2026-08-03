import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorWasmEngine
import CodeEditorWasmEngineWasmKit
import Foundation

/// Production Wasm engine factory (EXT-N20). Simulation / LinkedGuest lives in
/// ``CodeEditorWasmEngineTestSupport`` and test helpers only — never a production default.
public enum WasmEngineFactory {
    public enum EngineKind: String, Sendable {
        case wasmKit
    }

    /// Production default engine kind: real WasmKit isolation path.
    public static let productionEngineKind: EngineKind = .wasmKit

    /// Production real WasmKit engine — module bytes determine behavior.
    public static func wasmKit() -> WasmKitEngine {
        WasmKitEngine()
    }

    /// Production engine selection — always WasmKit (never simulation).
    public static func production() -> WasmKitEngine {
        wasmKit()
    }
}
