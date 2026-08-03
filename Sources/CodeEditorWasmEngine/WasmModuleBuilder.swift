import Foundation

/// Minimal WebAssembly binary encoder for core modules used as fixtures.
public struct WasmModuleBuilder: Sendable {
    public init() {}

    public static let magic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]  // \0asm
    public static let version: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    // MARK: - Public fixtures

    /// Minimal valid module exporting `codeeditor_abi_version` → 1 and empty stubs for required exports.
    /// Memory export `memory` + import host functions.
    public static func conformanceModule() -> Data {
        // Type section: (func) (), (func i32)->i32, (func i32 i32)->i32, (func i32 i32), (func i32), (func i32 i32)->i32 host send, (func i32 i32 i32), (func)->i64, (func i64 i64)->i32
        var types: [[UInt8]] = []
        types.append(funcType([], []))  // 0 stop-like
        types.append(funcType([], [.i32]))  // 1 abi_version
        types.append(funcType([.i32], [.i32]))  // 2 alloc, poll
        types.append(funcType([.i32, .i32], []))  // 3 dealloc
        types.append(funcType([.i32, .i32], [.i32]))  // 4 start, receive, host_send
        types.append(funcType([.i32], []))  // 5 stop
        types.append(funcType([.i32, .i32, .i32], []))  // 6 host_log
        types.append(funcType([.i64, .i64], [.i32]))  // 7 should_cancel
        types.append(funcType([], [.i64]))  // 8 millis (i64 — WASM-N07)

        // Import 4 host funcs from "codeeditor"
        var imports: [UInt8] = []
        imports += importFunc("codeeditor", CoreWasmImport.hostSend.rawValue, typeIndex: 4)
        imports += importFunc("codeeditor", CoreWasmImport.hostLog.rawValue, typeIndex: 6)
        imports += importFunc("codeeditor", CoreWasmImport.hostMonotonicMillis.rawValue, typeIndex: 8)
        imports += importFunc("codeeditor", CoreWasmImport.hostShouldCancel.rawValue, typeIndex: 7)

        // Function section: 7 guest funcs type indices
        // 0 abi_version ty1, 1 alloc ty2, 2 dealloc ty3, 3 start ty4, 4 receive ty4, 5 poll ty2, 6 stop ty5
        let funcTypes: [UInt8] = [1, 2, 3, 4, 4, 2, 5]

        // Memory: 1 page min, max 2
        let memory: [UInt8] = [0x01, 0x01, 0x01, 0x02]  // 1 memory, limits min=1 max=2

        // Export section
        var exports: [UInt8] = []
        exports += exportFunc(CoreWasmExport.abiVersion.rawValue, index: 4)  // after 4 imports
        exports += exportFunc(CoreWasmExport.alloc.rawValue, index: 5)
        exports += exportFunc(CoreWasmExport.dealloc.rawValue, index: 6)
        exports += exportFunc(CoreWasmExport.start.rawValue, index: 7)
        exports += exportFunc(CoreWasmExport.receive.rawValue, index: 8)
        exports += exportFunc(CoreWasmExport.poll.rawValue, index: 9)
        exports += exportFunc(CoreWasmExport.stop.rawValue, index: 10)
        exports += exportMemory("memory", index: 0)

        // Code for each function
        // abi_version: i32.const 1; return
        let abiCode = funcBody([0x41, 0x01, 0x0B])  // i32.const 1; end
        // alloc(len): return fixed heap pointer 1024 (ignore free list for fixture)
        let allocCode = funcBody([0x41, 0x80, 0x08, 0x0B])  // i32.const 1024; end
        // dealloc: nop
        let deallocCode = funcBody([0x0B])
        // start: return 0
        let startCode = funcBody([0x41, 0x00, 0x0B])
        // receive: store ptr/len at 0/4 then return 0
        // local.get 0; i32.const 0; i32.store; local.get 1; i32.const 4; i32.store; i32.const 0
        let receiveCode = funcBody([
            0x20, 0x00, 0x41, 0x00, 0x36, 0x02, 0x00,  // local.get 0; i32.const 0; i32.store align2 offset0
            0x20, 0x01, 0x41, 0x04, 0x36, 0x02, 0x00,  // local.get 1; i32.const 4; i32.store
            0x41, 0x00, 0x0B,
        ])
        // poll: load len at 4; if zero return 0; else call host_send(ptr,len); store 0 at 4; return 0
        // i32.const 4; i32.load; local.tee 1; i32.eqz; if; i32.const 0; return; end;
        // i32.const 0; i32.load; local.get 1; call 0; drop; i32.const 0; i32.const 4; i32.store; i32.const 0
        let pollCode = funcBody([
            0x01, 0x01, 0x7F,  // locals: 1 x i32
            0x41, 0x04, 0x28, 0x02, 0x00,  // i32.const 4; i32.load
            0x22, 0x01,  // local.tee 1
            0x45,  // i32.eqz
            0x04, 0x40,  // if
            0x41, 0x00, 0x0F,  // i32.const 0; return
            0x0B,  // end if
            0x41, 0x00, 0x28, 0x02, 0x00,  // i32.const 0; i32.load ptr
            0x20, 0x01,  // local.get 1 len
            0x10, 0x00,  // call 0 host_send
            0x1A,  // drop
            0x41, 0x00, 0x41, 0x04, 0x36, 0x02, 0x00,  // clear len
            0x41, 0x00, 0x0B,
        ])
        // stop: nop
        let stopCode = funcBody([0x0B])

        var codes: [UInt8] = []
        codes += vector([abiCode, allocCode, deallocCode, startCode, receiveCode, pollCode, stopCode])

        var module: [UInt8] = []
        module += magic
        module += version
        module += section(1, vector(types.map { Array($0) }.map { $0 }))  // need flatten types properly

        // Rebuild type section carefully
        module = []
        module += magic + version
        module += section(1, encodeVector(types))
        module += section(2, encodeVectorRaw(imports, count: 4))
        module += section(3, encodeVectorBytes(funcTypes.map { [$0] }))
        module += section(5, Array(memory.dropFirst()))  // memory section body without recount - fix below

        // Fix memory section: count + limits
        module = []
        module += magic + version
        module += section(1, encodeVector(types))
        module += section(2, encodeCounted(imports, count: 4))
        module += section(3, encodeCounted(funcTypes.flatMap { uleb(UInt32($0)) }, count: funcTypes.count))
        module += section(5, encodeCounted([0x01, 0x01, 0x02], count: 1))  // 1 mem, min1 max2 flags=1
        module += section(7, encodeCounted(exports, count: 8))
        module += section(
            10,
            encodeCounted(
                abiCode + allocCode + deallocCode + startCode + receiveCode + pollCode + stopCode,
                count: 7
            ))
        return Data(module)
    }

    public static func abiVersionOnlyModule() -> Data {
        abiVersionConstantModule(value: 1)
    }

    /// Module exporting `codeeditor_abi_version` returning a fixed i32 plus required memory (E1 proof).
    public static func abiVersionConstantModule(value: Int32) -> Data {
        var module: [UInt8] = []
        module += magic + version
        let types = [funcType([], [.i32])]
        module += section(1, encodeVector(types))
        module += section(3, encodeCounted(uleb(0), count: 1))
        module += section(5, encodeCounted([0x01, 0x01, 0x02], count: 1))  // memory min1 max2
        var exports: [UInt8] = []
        exports += exportFunc(CoreWasmExport.abiVersion.rawValue, index: 0)
        exports += exportMemory("memory", index: 0)
        module += section(7, encodeCounted(exports, count: 2))
        // i32.const value; end — encode small immediates
        var body: [UInt8] = [0x41]
        body += sleb(Int(value))
        body += [0x0B]
        module += section(10, encodeCounted(funcBody(body), count: 1))
        return Data(module)
    }

    /// Guest uses data segment "OK" at offset 0 then host_send(0,2) — proves memory bridge (E4).
    public static func hostSendEchoModule() -> Data {
        var module: [UInt8] = []
        module += magic + version
        let types = standardTypes()
        module += section(1, encodeVector(types))
        var imports: [UInt8] = []
        imports += importFunc("codeeditor", CoreWasmImport.hostSend.rawValue, typeIndex: 4)
        imports += importFunc("codeeditor", CoreWasmImport.hostLog.rawValue, typeIndex: 6)
        imports += importFunc("codeeditor", CoreWasmImport.hostMonotonicMillis.rawValue, typeIndex: 8)
        imports += importFunc("codeeditor", CoreWasmImport.hostShouldCancel.rawValue, typeIndex: 7)
        module += section(2, encodeCounted(imports, count: 4))
        let funcTypes: [UInt8] = [1, 2, 3, 4, 4, 2, 5]
        module += section(3, encodeCounted(funcTypes.flatMap { uleb(UInt32($0)) }, count: 7))
        module += section(5, encodeCounted([0x01, 0x01, 0x02], count: 1))
        var exports: [UInt8] = []
        exports += exportFunc(CoreWasmExport.abiVersion.rawValue, index: 4)
        exports += exportFunc(CoreWasmExport.alloc.rawValue, index: 5)
        exports += exportFunc(CoreWasmExport.dealloc.rawValue, index: 6)
        exports += exportFunc(CoreWasmExport.start.rawValue, index: 7)
        exports += exportFunc(CoreWasmExport.receive.rawValue, index: 8)
        exports += exportFunc(CoreWasmExport.poll.rawValue, index: 9)
        exports += exportFunc(CoreWasmExport.stop.rawValue, index: 10)
        exports += exportMemory("memory", index: 0)
        module += section(7, encodeCounted(exports, count: 8))
        // poll: host_send(0, 2); drop; return 0
        let pollCode = funcBody([
            0x41, 0x00,  // i32.const 0
            0x41, 0x02,  // i32.const 2
            0x10, 0x00,  // call 0 host_send
            0x1A,  // drop
            0x41, 0x00, 0x0B,
        ])
        module += section(
            10,
            encodeCounted(
                funcBody([0x41, 0x01, 0x0B]) + funcBody([0x41, 0x00, 0x0B]) + funcBody([0x0B])
                    + funcBody([0x41, 0x00, 0x0B]) + funcBody([0x41, 0x00, 0x0B]) + pollCode
                    + funcBody([0x0B]),
                count: 7
            ))
        // data section: active segment at offset 0 with "OK"
        var dataSec: [UInt8] = []
        dataSec += uleb(1)  // count
        dataSec += [0x00]  // memory index 0 (legacy active form)
        dataSec += [0x41, 0x00, 0x0B]  // i32.const 0; end
        dataSec += uleb(2) + [0x4F, 0x4B]  // "OK"
        module += section(11, dataSec)
        return Data(module)
    }

    /// Cooperative infinite loop that polls `host_should_cancel` (legacy).
    public static func infiniteLoopModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 2),
            pollBody: [
                0x03, 0x40,  // loop
                0x42, 0x00,  // i64.const 0
                0x42, 0x00,  // i64.const 0
                0x10, 0x03,  // call 3 host_should_cancel
                0x04, 0x40,  // if
                0x41, 0x00, 0x0F,  // i32.const 0; return
                0x0B,  // end if
                0x0C, 0x00,  // br 0
                0x0B,  // end loop
                0x41, 0x00, 0x0B,
            ]
        )
    }

    /// Pure noncooperative `loop { br 0 }` — no host calls in the loop body (WASM-N01).
    /// Still imports should_cancel so the instrumenter can inject probes.
    public static func pureNoncooperativeLoopModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 2),
            pollBody: [
                0x03, 0x40,  // loop
                0x0C, 0x00,  // br 0
                0x0B,  // end loop
                0x41, 0x00, 0x0B,  // i32.const 0; end (unreachable)
            ]
        )
    }

    /// Module that attempts unbounded memory.grow (WASM-N02 / N16).
    public static func memoryGrowHostileModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 256),
            pollBody: [
                0x03, 0x40,  // loop
                0x41, 0x10,  // i32.const 16 pages
                0x40, 0x00,  // memory.grow
                0x1A,  // drop
                0x0C, 0x00,  // br 0
                0x0B,
                0x41, 0x00, 0x0B,
            ]
        )
    }

    /// Module without exported memory (WASM-N03).
    public static func missingMemoryExportModule() -> Data {
        var module: [UInt8] = []
        module += magic + version
        let types = standardTypes()
        module += section(1, encodeVector(types))
        var imports: [UInt8] = []
        imports += importFunc("codeeditor", CoreWasmImport.hostSend.rawValue, typeIndex: 4)
        imports += importFunc("codeeditor", CoreWasmImport.hostLog.rawValue, typeIndex: 6)
        imports += importFunc("codeeditor", CoreWasmImport.hostMonotonicMillis.rawValue, typeIndex: 8)
        imports += importFunc("codeeditor", CoreWasmImport.hostShouldCancel.rawValue, typeIndex: 7)
        module += section(2, encodeCounted(imports, count: 4))
        let funcTypes: [UInt8] = [1, 2, 3, 4, 4, 2, 5]
        module += section(3, encodeCounted(funcTypes.flatMap { uleb(UInt32($0)) }, count: 7))
        module += section(5, encodeCounted([0x01, 0x01, 0x02], count: 1))
        var exports: [UInt8] = []
        exports += exportFunc(CoreWasmExport.abiVersion.rawValue, index: 4)
        exports += exportFunc(CoreWasmExport.alloc.rawValue, index: 5)
        exports += exportFunc(CoreWasmExport.dealloc.rawValue, index: 6)
        exports += exportFunc(CoreWasmExport.start.rawValue, index: 7)
        exports += exportFunc(CoreWasmExport.receive.rawValue, index: 8)
        exports += exportFunc(CoreWasmExport.poll.rawValue, index: 9)
        exports += exportFunc(CoreWasmExport.stop.rawValue, index: 10)
        // deliberately no memory export
        module += section(7, encodeCounted(exports, count: 7))
        module += section(
            10,
            encodeCounted(
                funcBody([0x41, 0x01, 0x0B]) + funcBody([0x41, 0x80, 0x08, 0x0B]) + funcBody([0x0B])
                    + funcBody([0x41, 0x00, 0x0B]) + funcBody([0x41, 0x00, 0x0B])
                    + funcBody([0x41, 0x00, 0x0B]) + funcBody([0x0B]),
                count: 7
            ))
        return Data(module)
    }

    /// Module exporting memory.grow helper for host-side growth tests (WASM-N05).
    public static func growHelperModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 4),
            pollBody: [0x41, 0x00, 0x0B],
            extraExports: [("codeeditor_memory_grow", 11)],
            extraFuncs: [
                // grow(pages i32) -> i32 : local.get 0; memory.grow; end
                (type: 2, body: funcBody([0x20, 0x00, 0x40, 0x00, 0x0B])),
            ]
        )
    }

    /// Flood host_send (WASM-N10/N16).
    public static func hostSendFloodModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 2),
            pollBody: [
                0x03, 0x40,
                0x41, 0x00,  // ptr
                0x41, 0x10,  // len 16
                0x10, 0x00,  // host_send
                0x1A,
                0x0C, 0x00,
                0x0B,
                0x41, 0x00, 0x0B,
            ]
        )
    }

    /// Log flood (WASM-N11/N16).
    public static func logFloodModule() -> Data {
        coreModule(
            memoryLimits: (min: 1, max: 2),
            pollBody: [
                0x03, 0x40,
                0x41, 0x00,  // level
                0x41, 0x00,  // ptr
                0x41, 0x20,  // len 32
                0x10, 0x01,  // host_log
                0x0C, 0x00,
                0x0B,
                0x41, 0x00, 0x0B,
            ]
        )
    }

    public static func malformedModule() -> Data {
        Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF])
    }

    public static func missingExportModule() -> Data {
        abiVersionOnlyModule()
    }

    // MARK: - Shared core module builder

    private static func standardTypes() -> [[UInt8]] {
        [
            funcType([], []),  // 0
            funcType([], [.i32]),  // 1 abi
            funcType([.i32], [.i32]),  // 2 alloc/poll/grow
            funcType([.i32, .i32], []),  // 3 dealloc
            funcType([.i32, .i32], [.i32]),  // 4 start/receive/send
            funcType([.i32], []),  // 5 stop
            funcType([.i32, .i32, .i32], []),  // 6 log
            funcType([.i64, .i64], [.i32]),  // 7 cancel
            funcType([], [.i64]),  // 8 millis i64
        ]
    }

    private static func coreModule(
        memoryLimits: (min: Int, max: Int?),
        pollBody: [UInt8],
        extraExports: [(String, Int)] = [],
        extraFuncs: [(type: UInt8, body: [UInt8])] = []
    ) -> Data {
        var module: [UInt8] = []
        module += magic + version
        module += section(1, encodeVector(standardTypes()))
        var imports: [UInt8] = []
        imports += importFunc("codeeditor", CoreWasmImport.hostSend.rawValue, typeIndex: 4)
        imports += importFunc("codeeditor", CoreWasmImport.hostLog.rawValue, typeIndex: 6)
        imports += importFunc("codeeditor", CoreWasmImport.hostMonotonicMillis.rawValue, typeIndex: 8)
        imports += importFunc("codeeditor", CoreWasmImport.hostShouldCancel.rawValue, typeIndex: 7)
        module += section(2, encodeCounted(imports, count: 4))
        var funcTypes: [UInt8] = [1, 2, 3, 4, 4, 2, 5]
        for f in extraFuncs { funcTypes.append(f.type) }
        module += section(3, encodeCounted(funcTypes.flatMap { uleb(UInt32($0)) }, count: funcTypes.count))
        var memLimits: [UInt8]
        if let max = memoryLimits.max {
            memLimits = [0x01] + uleb(UInt32(memoryLimits.min)) + uleb(UInt32(max))
        } else {
            memLimits = [0x00] + uleb(UInt32(memoryLimits.min))
        }
        module += section(5, encodeCounted(memLimits, count: 1))
        var exports: [UInt8] = []
        exports += exportFunc(CoreWasmExport.abiVersion.rawValue, index: 4)
        exports += exportFunc(CoreWasmExport.alloc.rawValue, index: 5)
        exports += exportFunc(CoreWasmExport.dealloc.rawValue, index: 6)
        exports += exportFunc(CoreWasmExport.start.rawValue, index: 7)
        exports += exportFunc(CoreWasmExport.receive.rawValue, index: 8)
        exports += exportFunc(CoreWasmExport.poll.rawValue, index: 9)
        exports += exportFunc(CoreWasmExport.stop.rawValue, index: 10)
        exports += exportMemory("memory", index: 0)
        var exportCount = 8
        for (name, idx) in extraExports {
            exports += exportFunc(name, index: idx)
            exportCount += 1
        }
        module += section(7, encodeCounted(exports, count: exportCount))
        var code = funcBody([0x41, 0x01, 0x0B])  // abi
            + funcBody([0x41, 0x80, 0x08, 0x0B])  // alloc 1024
            + funcBody([0x0B])  // dealloc
            + funcBody([0x41, 0x00, 0x0B])  // start
            + funcBody([0x41, 0x00, 0x0B])  // receive
            + funcBody(pollBody)
            + funcBody([0x0B])  // stop
        for f in extraFuncs { code += f.body }
        module += section(10, encodeCounted(code, count: 7 + extraFuncs.count))
        return Data(module)
    }

    // MARK: - Encoding helpers

    private enum ValType: UInt8 {
        case i32 = 0x7F
        case i64 = 0x7E
        case f32 = 0x7D
        case f64 = 0x7C
    }

    private static func funcType(_ params: [ValType], _ results: [ValType]) -> [UInt8] {
        var b: [UInt8] = [0x60]
        b += uleb(UInt32(params.count))
        b += params.map(\.rawValue)
        b += uleb(UInt32(results.count))
        b += results.map(\.rawValue)
        return b
    }

    private static func funcBody(_ expr: [UInt8]) -> [UInt8] {
        // locals count 0 unless first bytes are local decls already included
        // If expr starts with local decl pattern we assume full body after size
        var body: [UInt8]
        if expr.first == 0x01 || expr.first == 0x00 {
            body = expr
        } else {
            body = [0x00] + expr  // 0 local entries
        }
        return uleb(UInt32(body.count)) + body
    }

    private static func importFunc(_ module: String, _ name: String, typeIndex: Int) -> [UInt8] {
        var b: [UInt8] = []
        b += nameBytes(module)
        b += nameBytes(name)
        b += [0x00]  // func
        b += uleb(UInt32(typeIndex))
        return b
    }

    private static func exportFunc(_ name: String, index: Int) -> [UInt8] {
        var b: [UInt8] = []
        b += nameBytes(name)
        b += [0x00]  // func
        b += uleb(UInt32(index))
        return b
    }

    private static func exportMemory(_ name: String, index: Int) -> [UInt8] {
        var b: [UInt8] = []
        b += nameBytes(name)
        b += [0x02]  // memory
        b += uleb(UInt32(index))
        return b
    }

    private static func nameBytes(_ s: String) -> [UInt8] {
        let utf = Array(s.utf8)
        return uleb(UInt32(utf.count)) + utf
    }

    private static func section(_ id: UInt8, _ content: [UInt8]) -> [UInt8] {
        [id] + uleb(UInt32(content.count)) + content
    }

    private static func encodeVector(_ items: [[UInt8]]) -> [UInt8] {
        var b = uleb(UInt32(items.count))
        for i in items { b += i }
        return b
    }

    private static func encodeVectorBytes(_ items: [[UInt8]]) -> [UInt8] {
        encodeVector(items)
    }

    private static func encodeVectorRaw(_ raw: [UInt8], count: Int) -> [UInt8] {
        uleb(UInt32(count)) + raw
    }

    private static func encodeCounted(_ raw: [UInt8], count: Int) -> [UInt8] {
        uleb(UInt32(count)) + raw
    }

    private static func vector(_ items: [[UInt8]]) -> [UInt8] {
        encodeVector(items)
    }

    private static func uleb(_ value: UInt32) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    /// Signed LEB128 for i32.const immediates.
    private static func sleb(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        var more = true
        while more {
            var b = UInt8(v & 0x7F)
            v >>= 7
            let signBitSet = (b & 0x40) != 0
            if (v == 0 && !signBitSet) || (v == -1 && signBitSet) {
                more = false
            } else {
                b |= 0x80
            }
            out.append(b)
        }
        return out
    }
}
