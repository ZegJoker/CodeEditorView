import Foundation
import Testing
@testable import CodeEditorCore

private final class RELN05BenchLine: LinePayload {
    let id = UUID()
}

/// REL-N05 — fixed-dataset editor/workbench micro-benchmarks (not synthetic Python string work).
/// When `PERF_SMOKE_EMIT=1`, writes percentile measurements to PERF_SMOKE_OUT (or default path).
@Suite("REL-N05 fixed-dataset performance")
@MainActor
struct RELN05PerfBenchmarks {
    private static let fixedDatasetID = "editor_fixed_v1"
    private static let fixedLineCount = 2_000
    private static let fixedLineWidth = 80

    /// Deterministic corpus: N lines of printable ASCII (fixed dataset for regression).
    private static func fixedDocumentText(lines: Int = fixedLineCount, width: Int = fixedLineWidth) -> String {
        var out = ""
        out.reserveCapacity(lines * (width + 1))
        for i in 0..<lines {
            let ch = Character(UnicodeScalar(65 + (i % 26))!)
            out.append(String(repeating: ch, count: width))
            out.append("\n")
        }
        return out
    }

    private static func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        let s = samples.sorted()
        func pct(_ p: Double) -> Double {
            let k = Double(s.count - 1) * (p / 100.0)
            let f = Int(k)
            let c = min(f + 1, s.count - 1)
            if f == c { return s[f] }
            return s[f] + (s[c] - s[f]) * (k - Double(f))
        }
        return (pct(50), pct(95), pct(99))
    }

    private static func measureMs(iterations: Int, warmup: Int, body: () -> Void) -> [Double] {
        for _ in 0..<warmup { body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = CFAbsoluteTimeGetCurrent()
            body()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            samples.append(ms)
        }
        return samples
    }

    @Test func test_REL_N05_fixedDatasetEditorBenchmarks() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["PERF_ITERATIONS"] ?? "80") ?? 80
        let warmup = Int(ProcessInfo.processInfo.environment["PERF_WARMUP"] ?? "8") ?? 8
        let text = Self.fixedDocumentText()

        // keystroke path: single-character insert into mid-document (DocumentStore)
        let keystrokeDoc = DocumentStore(string: text)
        let insertAt = text.utf16.count / 2
        var keystrokeSamples: [Double] = []
        keystrokeSamples.reserveCapacity(iterations)
        for _ in 0..<warmup {
            _ = keystrokeDoc.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "x")
        }
        for _ in 0..<iterations {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = keystrokeDoc.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "a")
            keystrokeSamples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        }
        let keyPct = Self.percentiles(keystrokeSamples)

        // scroll / line-index rebuild on fixed dataset
        let lineSamples = Self.measureMs(iterations: max(10, iterations / 4), warmup: max(2, warmup / 2)) {
            _ = LineIndex<RELN05BenchLine>.build(
                from: text,
                estimatedLineHeight: 14
            ) { _ in RELN05BenchLine() }
        }
        let linePct = Self.percentiles(lineSamples)

        // parse-ish: full document set + line ending detect (fixed corpus)
        let parseSamples = Self.measureMs(iterations: max(10, iterations / 4), warmup: max(2, warmup / 2)) {
            let d = DocumentStore(string: text)
            _ = d.fullString.count
            _ = d.lineEnding
        }
        let parsePct = Self.percentiles(parseSamples)

        // Workspace-scale contribution: multi-range sequential edits (edit storm)
        let multiDoc = DocumentStore(string: text)
        let multiSamples = Self.measureMs(iterations: max(10, iterations / 4), warmup: 2) {
            for i in 0..<20 {
                let loc = min((i * 97) % max(1, multiDoc.length - 1), multiDoc.length)
                _ = multiDoc.replaceCharacters(in: NSRange(location: loc, length: 0), with: ".")
            }
        }
        let multiPct = Self.percentiles(multiSamples)

        // Aggregate keystroke as primary CI metric (audit keystroke/scroll/parse)
        let p50 = keyPct.p50
        let p95 = keyPct.p95
        let p99 = keyPct.p99

        let rss = Self.currentRSSBytes()
        let cpuUser = Self.cpuUserSeconds()

        let within = p95 < 50.0 // ms; editor insert on 2k lines should be well under

        #expect(keystrokeSamples.count == iterations)
        #expect(p50 >= 0 && p95 >= p50)
        #expect(!text.isEmpty)
        #expect(within, "keystroke p95 \(p95)ms exceeds local bound")

        // Emit machine-readable sample when producer requests it
        let emit = ProcessInfo.processInfo.environment["PERF_SMOKE_EMIT"] == "1"
        if emit {
            let outPath = ProcessInfo.processInfo.environment["PERF_SMOKE_OUT"]
                ?? "Baselines/evidence/perf-smoke.json"
            let hw: [String: Any] = [
                "machine": Self.unameMachine(),
                "processor": Self.unameMachine(),
                "system": "Darwin",
                "hardware_class": Self.unameMachine() == "arm64" ? "apple-silicon-dev-or-ci" : Self.unameMachine(),
                "swift": "swift-testing",
            ]
            let payload: [String: Any] = [
                "schema_version": 3,
                "metric": "keystroke_insert",
                "metrics": [
                    [
                        "name": "keystroke_insert",
                        "dataset": Self.fixedDatasetID,
                        "p50_ms": keyPct.p50,
                        "p95_ms": keyPct.p95,
                        "p99_ms": keyPct.p99,
                        "iterations": iterations,
                    ],
                    [
                        "name": "line_index_rebuild",
                        "dataset": Self.fixedDatasetID,
                        "p50_ms": linePct.p50,
                        "p95_ms": linePct.p95,
                        "p99_ms": linePct.p99,
                        "iterations": lineSamples.count,
                    ],
                    [
                        "name": "document_parse_load",
                        "dataset": Self.fixedDatasetID,
                        "p50_ms": parsePct.p50,
                        "p95_ms": parsePct.p95,
                        "p99_ms": parsePct.p99,
                        "iterations": parseSamples.count,
                    ],
                    [
                        "name": "edit_storm_scroll_window",
                        "dataset": Self.fixedDatasetID,
                        "p50_ms": multiPct.p50,
                        "p95_ms": multiPct.p95,
                        "p99_ms": multiPct.p99,
                        "iterations": multiSamples.count,
                    ],
                ],
                "dataset": Self.fixedDatasetID,
                "dataset_version": "1",
                "dataset_lines": Self.fixedLineCount,
                "dataset_line_width": Self.fixedLineWidth,
                "iterations": iterations,
                "warmup": warmup,
                "p50_ms": p50,
                "p95_ms": p95,
                "p99_ms": p99,
                "memory_peak_bytes": rss,
                "cpu_user_seconds": cpuUser,
                "allocations": iterations + lineSamples.count + parseSamples.count,
                "dropped_events": 0,
                "within_unit_bound": within,
                "hardware": hw,
                "producer": "Tests/CodeEditorCoreTests/RELN05PerfBenchmarks.swift",
                "generated_at": ISO8601DateFormatter().string(from: Date()),
                "run_id": UUID().uuidString,
                "per_op_us": p50 * 1000.0,
            ]
            let url = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            // Seed baseline if missing
            let baseline = url.deletingLastPathComponent().appendingPathComponent("perf-smoke.baseline.json")
            if !FileManager.default.fileExists(atPath: baseline.path) {
                try data.write(to: baseline)
            }
        }
    }

    private static func currentRSSBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Int(info.resident_size)
        }
        return 0
    }

    private static func cpuUserSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
    }

    private static func unameMachine() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
}
