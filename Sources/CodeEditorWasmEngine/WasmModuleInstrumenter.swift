import Foundation

/// Instruments Wasm modules so pure noncooperative loops observe host cancellation (WASM-N01).
///
/// After every `loop` opcode, injects:
/// ```
/// i64.const 0 ; i64.const 0 ; call <should_cancel> ; if ; unreachable ; end
/// ```
/// so wall-time interrupt flags are observed without relying on guest cooperation.
///
/// Modules that cannot be instrumented safely are rejected fail-closed.
public enum WasmModuleInstrumenter {
    public static let pageSize = 64 * 1024

    /// Result of structural validation prior to instantiation.
    public struct ValidationReport: Sendable, Equatable {
        public var hasMemoryExport: Bool
        public var memoryMinPages: Int?
        public var memoryMaxPages: Int?
        public var hasShouldCancelImport: Bool
        public var shouldCancelImportIndex: Int?
        public var importCount: Int
        public var functionCount: Int
        public var exportNames: [String]
        public var tableMaxElements: Int?
    }

    /// Validate ABI structure and resource declarations (WASM-N02/N03).
    public static func validateStructure(
        module: Data,
        limits: WasmResourceLimits
    ) throws -> ValidationReport {
        guard module.count >= 8 else {
            throw WasmEngineError.invalidModule("module too short")
        }
        guard module.count <= limits.maxModuleBytes else {
            throw WasmEngineError.moduleTooLarge(module.count)
        }
        let bytes = [UInt8](module)
        guard bytes.starts(with: [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]) else {
            throw WasmEngineError.invalidModule("bad magic/version")
        }

        var report = ValidationReport(
            hasMemoryExport: false,
            memoryMinPages: nil,
            memoryMaxPages: nil,
            hasShouldCancelImport: false,
            shouldCancelImportIndex: nil,
            importCount: 0,
            functionCount: 0,
            exportNames: [],
            tableMaxElements: nil
        )

        var offset = 8
        while offset < bytes.count {
            let id = bytes[offset]
            offset += 1
            let (size, sizeLen) = try readULEB(bytes, at: offset)
            offset += sizeLen
            let end = offset + Int(size)
            guard end <= bytes.count else {
                throw WasmEngineError.invalidModule("section overrun")
            }
            let body = Array(bytes[offset..<end])
            switch id {
            case 2:  // imports
                try parseImports(body, into: &report)
            case 3:  // functions
                var i = 0
                let (count, n) = try readULEB(body, at: i)
                i += n
                report.functionCount = Int(count)
                _ = i
            case 4:  // tables
                try parseTables(body, into: &report, limits: limits)
            case 5:  // memory
                try parseMemories(body, into: &report, limits: limits)
            case 7:  // exports
                try parseExports(body, into: &report)
            default:
                break
            }
            offset = end
        }

        // Continuous ResourceLimiter imposes runtime max (WASM-N02). Only initial min must fit;
        // declared max may exceed host limit — growth is denied by the limiter.
        if let min = report.memoryMinPages, min * pageSize > limits.maxLinearMemoryBytes {
            throw WasmEngineError.memoryLimitExceeded
        }

        return report
    }

    /// Inject metering probes into every loop body. Returns original module if no loops found.
    public static func instrumentLoopsForCancellation(_ module: Data) throws -> Data {
        let bytes = [UInt8](module)
        guard bytes.count >= 8,
            bytes.starts(with: [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        else {
            throw WasmEngineError.invalidModule("bad magic")
        }

        // Locate should_cancel import index and code section.
        var importFuncCount = 0
        var shouldCancelIndex: Int?
        var codeSectionRange: Range<Int>?
        var offset = 8
        while offset < bytes.count {
            let id = bytes[offset]
            offset += 1
            let (size, sizeLen) = try readULEB(bytes, at: offset)
            offset += sizeLen
            let start = offset
            let end = offset + Int(size)
            guard end <= bytes.count else {
                throw WasmEngineError.invalidModule("section overrun")
            }
            if id == 2 {
                var i = 0
                let body = Array(bytes[start..<end])
                let (count, n) = try readULEB(body, at: i)
                i += n
                for _ in 0..<count {
                    let (mod, mLen) = try readName(body, at: i)
                    i += mLen
                    let (name, nLen) = try readName(body, at: i)
                    i += nLen
                    guard i < body.count else { throw WasmEngineError.invalidModule("import trunc") }
                    let kind = body[i]
                    i += 1
                    if kind == 0x00 {
                        let (_, tLen) = try readULEB(body, at: i)
                        i += tLen
                        if mod == CoreWasmImport.moduleName,
                            name == CoreWasmImport.hostShouldCancel.rawValue
                        {
                            shouldCancelIndex = importFuncCount
                        }
                        importFuncCount += 1
                    } else if kind == 0x01 {
                        // table
                        i += 1  // reftype
                        i = try skipLimits(body, at: i)
                    } else if kind == 0x02 {
                        i = try skipLimits(body, at: i)
                    } else if kind == 0x03 {
                        i += 1  // valtype
                        guard i < body.count else { throw WasmEngineError.invalidModule("global trunc") }
                        i += 1  // mut
                    } else {
                        throw WasmEngineError.invalidModule("unknown import kind")
                    }
                }
            } else if id == 10 {
                codeSectionRange = start..<end
            }
            offset = end
        }

        guard let cancelIdx = shouldCancelIndex else {
            // No cancel import: cannot instrument; callers that need hard interrupt must use process isolation.
            return module
        }
        guard let codeRange = codeSectionRange else {
            return module
        }

        let codeBody = Array(bytes[codeRange])
        var i = 0
        let (fnCount, n0) = try readULEB(codeBody, at: i)
        i += n0
        var newCodeBody: [UInt8] = encodeULEB(UInt32(fnCount))
        var mutated = false

        for _ in 0..<fnCount {
            let (bodySize, sLen) = try readULEB(codeBody, at: i)
            i += sLen
            let bodyStart = i
            let bodyEnd = i + Int(bodySize)
            guard bodyEnd <= codeBody.count else {
                throw WasmEngineError.invalidModule("code body overrun")
            }
            let fnBody = Array(codeBody[bodyStart..<bodyEnd])
            let instrumented = try instrumentFunctionBody(fnBody, cancelImportIndex: cancelIdx)
            if instrumented != fnBody { mutated = true }
            newCodeBody += encodeULEB(UInt32(instrumented.count))
            newCodeBody += instrumented
            i = bodyEnd
        }

        guard mutated else { return module }

        // Rebuild module with replaced code section.
        var out: [UInt8] = Array(bytes[0..<8])
        offset = 8
        while offset < bytes.count {
            let id = bytes[offset]
            offset += 1
            let (size, sizeLen) = try readULEB(bytes, at: offset)
            offset += sizeLen
            let start = offset
            let end = offset + Int(size)
            if id == 10 {
                out.append(10)
                out += encodeULEB(UInt32(newCodeBody.count))
                out += newCodeBody
            } else {
                out.append(id)
                out += encodeULEB(UInt32(size))
                out += bytes[start..<end]
            }
            offset = end
        }
        return Data(out)
    }

    // MARK: - Function body instrumentation

    private static func instrumentFunctionBody(_ body: [UInt8], cancelImportIndex: Int) throws -> [UInt8] {
        // body = local decls + expr
        guard !body.isEmpty else { return body }
        var i = 0
        let (localGroups, lgLen) = try readULEB(body, at: i)
        i += lgLen
        for _ in 0..<localGroups {
            let (_, cLen) = try readULEB(body, at: i)
            i += cLen
            guard i < body.count else { throw WasmEngineError.invalidModule("locals trunc") }
            i += 1  // valtype
        }
        let locals = Array(body[0..<i])
        let expr = Array(body[i...])
        let newExpr = try injectLoopMeters(expr, cancelImportIndex: cancelImportIndex)
        return locals + newExpr
    }

    private static func injectLoopMeters(_ expr: [UInt8], cancelImportIndex: Int) throws -> [UInt8] {
        // Inject after each `loop` (0x03) + blocktype.
        var out: [UInt8] = []
        var i = 0
        let probe = meterProbe(cancelImportIndex: cancelImportIndex)

        while i < expr.count {
            let op = expr[i]
            out.append(op)
            i += 1
            switch op {
            case 0x02, 0x03, 0x04:  // block, loop, if
                // blocktype: 0x40 | valtype | s33 type index
                guard i < expr.count else { throw WasmEngineError.invalidModule("blocktype trunc") }
                let bt = expr[i]
                out.append(bt)
                i += 1
                // Multi-byte s33 only if high bit set and not single-byte valtype/empty
                if bt != 0x40, bt != 0x7F, bt != 0x7E, bt != 0x7D, bt != 0x7C, bt != 0x7B {
                    // typed via type index (sleb); if first byte had continuation, consume
                    if bt & 0x80 != 0 {
                        while i < expr.count {
                            let b = expr[i]
                            out.append(b)
                            i += 1
                            if b & 0x80 == 0 { break }
                        }
                    }
                }
                if op == 0x03 {
                    out += probe
                }
            case 0x0C, 0x0D:  // br, br_if
                let (idx, len) = try readULEB(expr, at: i)
                out += encodeULEB(idx)
                i += len
            case 0x0E:  // br_table
                let (count, len) = try readULEB(expr, at: i)
                out += encodeULEB(count)
                i += len
                for _ in 0..<(Int(count) + 1) {
                    let (idx, l) = try readULEB(expr, at: i)
                    out += encodeULEB(idx)
                    i += l
                }
            case 0x10, 0x11, 0x12:  // call, call_indirect, return_call
                let (idx, len) = try readULEB(expr, at: i)
                out += encodeULEB(idx)
                i += len
                if op == 0x11 || op == 0x12 {
                    // table index may follow for call_indirect in some encodings; Wasm MVP: typeidx + 0x00
                    if op == 0x11 {
                        guard i < expr.count else { throw WasmEngineError.invalidModule("call_indirect") }
                        out.append(expr[i])
                        i += 1
                    }
                }
            case 0x41:  // i32.const
                let (_, len) = try readSLEB(expr, at: i)
                out += Array(expr[i..<(i + len)])
                i += len
            case 0x42:  // i64.const
                let (_, len) = try readSLEB(expr, at: i)
                out += Array(expr[i..<(i + len)])
                i += len
            case 0x43:  // f32.const
                guard i + 4 <= expr.count else { throw WasmEngineError.invalidModule("f32.const") }
                out += Array(expr[i..<(i + 4)])
                i += 4
            case 0x44:  // f64.const
                guard i + 8 <= expr.count else { throw WasmEngineError.invalidModule("f64.const") }
                out += Array(expr[i..<(i + 8)])
                i += 8
            case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:  // local/global get/set/tee
                let (idx, len) = try readULEB(expr, at: i)
                out += encodeULEB(idx)
                i += len
            case 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
                0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
                0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E:  // load/store
                let (a, l1) = try readULEB(expr, at: i)
                out += encodeULEB(a)
                i += l1
                let (o, l2) = try readULEB(expr, at: i)
                out += encodeULEB(o)
                i += l2
            case 0x3F, 0x40:  // memory.size / memory.grow
                guard i < expr.count else { throw WasmEngineError.invalidModule("memory op") }
                out.append(expr[i])
                i += 1
            case 0xFC:  // multibyte prefix — copy remaining carefully (bulk mem etc.)
                let (sub, len) = try readULEB(expr, at: i)
                out += encodeULEB(sub)
                i += len
                // Best-effort: copy common forms' immediates via residual passthrough of known sizes is hard;
                // fall back to rejecting instrument for complex FC bodies.
                throw WasmEngineError.invalidModule("uninstrumentable opcode 0xFC")
            default:
                // opcodes without immediates
                break
            }
        }
        return out
    }

    private static func meterProbe(cancelImportIndex: Int) -> [UInt8] {
        // i64.const 0; i64.const 0; call N; if; unreachable; end
        var b: [UInt8] = [0x42, 0x00, 0x42, 0x00, 0x10]
        b += encodeULEB(UInt32(cancelImportIndex))
        b += [0x04, 0x40, 0x00, 0x0B]
        return b
    }

    // MARK: - Section parsers

    private static func parseImports(_ body: [UInt8], into report: inout ValidationReport) throws {
        var i = 0
        let (count, n) = try readULEB(body, at: i)
        i += n
        report.importCount = Int(count)
        var funcIdx = 0
        for _ in 0..<count {
            let (mod, mLen) = try readName(body, at: i)
            i += mLen
            let (name, nLen) = try readName(body, at: i)
            i += nLen
            guard i < body.count else { throw WasmEngineError.invalidModule("import") }
            let kind = body[i]
            i += 1
            switch kind {
            case 0x00:
                let (_, tLen) = try readULEB(body, at: i)
                i += tLen
                if mod == CoreWasmImport.moduleName, name == CoreWasmImport.hostShouldCancel.rawValue {
                    report.hasShouldCancelImport = true
                    report.shouldCancelImportIndex = funcIdx
                }
                funcIdx += 1
            case 0x01:
                i += 1
                i = try skipLimits(body, at: i)
            case 0x02:
                i = try skipLimits(body, at: i)
            case 0x03:
                i += 2
            default:
                throw WasmEngineError.invalidModule("import kind")
            }
        }
    }

    private static func parseMemories(
        _ body: [UInt8],
        into report: inout ValidationReport,
        limits: WasmResourceLimits
    ) throws {
        var i = 0
        let (count, n) = try readULEB(body, at: i)
        i += n
        if count > 1 {
            throw WasmEngineError.abiValidation("multiple memories not supported")
        }
        if count == 0 { return }
        let (min, max, next) = try readLimits(body, at: i)
        i = next
        report.memoryMinPages = Int(min)
        report.memoryMaxPages = max.map { Int($0) }
        if Int(min) * pageSize > limits.maxLinearMemoryBytes {
            throw WasmEngineError.memoryLimitExceeded
        }
        _ = i
    }

    private static func parseTables(
        _ body: [UInt8],
        into report: inout ValidationReport,
        limits: WasmResourceLimits
    ) throws {
        var i = 0
        let (count, n) = try readULEB(body, at: i)
        i += n
        for _ in 0..<count {
            guard i < body.count else { throw WasmEngineError.invalidModule("table") }
            i += 1  // reftype
            let (min, max, next) = try readLimits(body, at: i)
            i = next
            let cap = Int(max ?? min)
            report.tableMaxElements = cap
            if cap > limits.maxTableElements {
                throw WasmEngineError.resourceLimit("table elements \(cap) > \(limits.maxTableElements)")
            }
        }
    }

    private static func parseExports(_ body: [UInt8], into report: inout ValidationReport) throws {
        var i = 0
        let (count, n) = try readULEB(body, at: i)
        i += n
        for _ in 0..<count {
            let (name, nLen) = try readName(body, at: i)
            i += nLen
            guard i + 1 <= body.count else { throw WasmEngineError.invalidModule("export") }
            let kind = body[i]
            i += 1
            let (_, idxLen) = try readULEB(body, at: i)
            i += idxLen
            report.exportNames.append(name)
            if kind == 0x02, name == CoreWasmABI.requiredMemoryExport {
                report.hasMemoryExport = true
            }
        }
    }

    // MARK: - LEB helpers

    private static func readLimits(_ body: [UInt8], at i: Int) throws -> (UInt32, UInt32?, Int) {
        guard i < body.count else { throw WasmEngineError.invalidModule("limits") }
        let flags = body[i]
        var j = i + 1
        let (min, mLen) = try readULEB(body, at: j)
        j += mLen
        if flags & 0x01 != 0 {
            let (max, xLen) = try readULEB(body, at: j)
            j += xLen
            return (min, max, j)
        }
        return (min, nil, j)
    }

    private static func skipLimits(_ body: [UInt8], at i: Int) throws -> Int {
        let (_, _, next) = try readLimits(body, at: i)
        return next
    }

    private static func readName(_ body: [UInt8], at i: Int) throws -> (String, Int) {
        let (len, n) = try readULEB(body, at: i)
        let start = i + n
        let end = start + Int(len)
        guard end <= body.count else { throw WasmEngineError.invalidModule("name") }
        let s = String(bytes: body[start..<end], encoding: .utf8) ?? ""
        return (s, n + Int(len))
    }

    private static func readULEB(_ bytes: [UInt8], at i: Int) throws -> (UInt32, Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var j = i
        while j < bytes.count {
            let b = bytes[j]
            j += 1
            result |= UInt32(b & 0x7F) << shift
            if b & 0x80 == 0 {
                return (result, j - i)
            }
            shift += 7
            if shift > 35 { throw WasmEngineError.invalidModule("uleb overflow") }
        }
        throw WasmEngineError.invalidModule("uleb trunc")
    }

    private static func readSLEB(_ bytes: [UInt8], at i: Int) throws -> (Int64, Int) {
        var result: Int64 = 0
        var shift: Int64 = 0
        var j = i
        var b: UInt8 = 0
        repeat {
            guard j < bytes.count else { throw WasmEngineError.invalidModule("sleb trunc") }
            b = bytes[j]
            j += 1
            result |= Int64(b & 0x7F) << shift
            shift += 7
        } while b & 0x80 != 0 && shift < 64
        if shift < 64, b & 0x40 != 0 {
            result |= -1 << shift
        }
        return (result, j - i)
    }

    public static func encodeULEB(_ value: UInt32) -> [UInt8] {
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
}
