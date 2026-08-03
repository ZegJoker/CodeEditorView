import CodeEditorWasmEngine
import CodeEditorWasmEngineWasmKit
import Foundation

/// Killable Wasm invoke helper (WASM-N01 / WASM-N16).
///
/// Usage:
///   codeeditor-wasm-harness --module PATH --export NAME [--timeout-ms N] [--arg-i32 V]
///
/// Exit codes:
///   0 — call returned normally
///   2 — deadline / interrupted / trap (contained)
///   3 — instantiate / validate failure
///   4 — usage error
///
/// Outer harnesses (tests / CI) may SIGKILL this process if containment fails.

func usage() -> Never {
    fputs(
        """
        usage: codeeditor-wasm-harness --module PATH --export NAME [--timeout-ms N] [--arg-i32 V]
        """,
        stderr
    )
    exit(4)
}

var modulePath: String?
var exportName = CoreWasmExport.poll.rawValue
var timeoutMS: Int = 250
var argI32: Int32 = 0
var dumpFixturesDir: String?

var i = 1
let args = CommandLine.arguments
while i < args.count {
    let a = args[i]
    i += 1
    switch a {
    case "--module":
        guard i < args.count else { usage() }
        modulePath = args[i]
        i += 1
    case "--export":
        guard i < args.count else { usage() }
        exportName = args[i]
        i += 1
    case "--timeout-ms":
        guard i < args.count, let v = Int(args[i]) else { usage() }
        timeoutMS = v
        i += 1
    case "--arg-i32":
        guard i < args.count, let v = Int32(args[i]) else { usage() }
        argI32 = v
        i += 1
    case "--dump-fixtures":
        guard i < args.count else { usage() }
        dumpFixturesDir = args[i]
        i += 1
    case "--help", "-h":
        usage()
    default:
        usage()
    }
}

if let dir = dumpFixturesDir {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pairs: [(String, Data)] = [
        ("deep_recursion.wasm", WasmModuleBuilder.deepRecursionModule()),
        ("huge_table.wasm", WasmModuleBuilder.hugeTableModule()),
        ("oob_memory.wasm", WasmModuleBuilder.oobMemoryAccessModule()),
        ("capability_flood.wasm", WasmModuleBuilder.capabilityCallFloodModule()),
        ("infinite_loop_pure.wasm", WasmModuleBuilder.pureNoncooperativeLoopModule()),
    ]
    for (name, data) in pairs {
        try! data.write(to: root.appendingPathComponent(name))
        print("wrote \(name) (\(data.count) bytes)")
    }
    exit(0)
}

guard let modulePath else { usage() }
guard let module = try? Data(contentsOf: URL(fileURLWithPath: modulePath)) else {
    fputs("failed to read module\n", stderr)
    exit(3)
}

let engine = WasmKitEngine()
let host = WasmHostImports(
    send: { _, _ in 0 },
    log: { _, _, _ in },
    monotonicMillis: { WasmMonotonicClock.nowMillis() },
    shouldCancel: { _, _ in 0 }
)
let limits = WasmResourceLimits(
    maxWallTime: .milliseconds(timeoutMS),
    maxFuel: 5_000_000,
    requireMemoryMaximum: false
)

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 2

Task {
    do {
        let inst = try await engine.instantiate(module: module, imports: host, limits: limits)
        let callArgs: [WasmValue] =
            (exportName == CoreWasmExport.poll.rawValue || exportName == CoreWasmExport.alloc.rawValue)
            ? [.i32(argI32)] : []
        _ = try await inst.call(exportName, args: callArgs)
        exitCode = 0
    } catch is WasmEngineError {
        exitCode = 2
    } catch {
        exitCode = 2
    }
    sem.signal()
}

// Hard outer kill: if the task group never returns, OS process still exits via alarm.
let outer = DispatchWorkItem {
    fputs("harness outer timeout — exiting\n", stderr)
    exit(2)
}
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMS + 2_000), execute: outer)
sem.wait()
outer.cancel()
exit(exitCode)
