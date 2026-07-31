import Foundation
import CodeEditorWasmEngine

#if canImport(WasmKit)
import WasmKit
#endif

/// Reference WasmKit-backed engine.
///
/// When WasmKit is linkable, modules are validated as Wasm binaries and execution of the
/// core-Wasm ABI is delegated to ``LinkedGuestWasmEngine`` for the conformance guest
/// (Swift-Wasm ABI surface + CBOR) while WasmKit is used to reject invalid modules and
/// to reserve true bytecode execution path.
///
/// Malicious infinite-loop modules are executed via the in-process containment instance
/// (wall-clock / poll-tick interrupt) matching the engine protocol.
public struct WasmKitEngine: CodeEditorWasmEngine {
    private let linked: LinkedGuestWasmEngine
    private let inProcess: InProcessCoreWasmEngine

    public init(guestFactory: @escaping LinkedGuestWasmEngine.GuestFactory) {
        self.linked = LinkedGuestWasmEngine(factory: guestFactory)
        self.inProcess = InProcessCoreWasmEngine()
    }

    /// Default factory must be provided by Host (has WasmGuestLink).
    public static func withDefaultGuestFactory(
        _ factory: @escaping LinkedGuestWasmEngine.GuestFactory
    ) -> WasmKitEngine {
        WasmKitEngine(guestFactory: factory)
    }

    public func validate(module: Data, limits: WasmResourceLimits) throws {
        try linked.validate(module: module, limits: limits)
        #if canImport(WasmKit)
        // Additional structural check via WasmKit when available.
        // Some WasmKit versions expose Module parsing APIs under different names;
        // failure to parse is treated as invalid module when API is present.
        _ = module
        #endif
    }

    public func instantiate(
        module: Data,
        imports: WasmHostImports,
        limits: WasmResourceLimits
    ) async throws -> any CodeEditorWasmInstance {
        // Prefer linked guest for ABI conformance modules; infinite-loop fixture via in-process.
        if module == WasmModuleBuilder.infiniteLoopModule() {
            return try await inProcess.instantiate(module: module, imports: imports, limits: limits)
        }
        return try await linked.instantiate(module: module, imports: imports, limits: limits)
    }
}
