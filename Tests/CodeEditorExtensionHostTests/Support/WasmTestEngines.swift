import CodeEditorExtensionHost
import CodeEditorWasmEngine
import CodeEditorWasmEngineWasmKit
import Foundation

/// Test-only Wasm engine helpers (EXT-N20). Not part of the production host surface.
public enum WasmTestEngines {
    public static func inProcess() -> InProcessCoreWasmEngine {
        InProcessCoreWasmEngine()
    }

    public static func simulation() -> LinkedGuestWasmEngine {
        WasmEngineFactory.linkedGuest()
    }

    public static func linkedGuest() -> LinkedGuestWasmEngine {
        WasmEngineFactory.linkedGuest()
    }
}
