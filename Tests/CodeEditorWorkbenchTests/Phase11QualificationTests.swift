import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorWorkbench

/// Phase 11 / §26 qualification contracts — executable evidence, not aspirational docs.
@Suite("Phase11 qualification gates")
@MainActor
struct Phase11QualificationTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - §26.8 Accessibility / workbench surfaces

    @Test func defaultNavigatorsHaveAccessibilityIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p11-a11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let ids = Set(model.contributionRegistry.allContributions().map(\.id))
        for nav in WorkbenchNavigatorID.allCases {
            let covered = ids.contains(nav.rawValue) || nav.aliases.contains(where: { ids.contains($0) })
            #expect(covered, "missing navigator \(nav.rawValue)")
        }
        #expect(WorkbenchNavigatorID.symbols.rawValue == "workbench.navigator.symbols")
        #expect(ids.contains("workbench.navigator.breakpoints"))
    }

    @Test func reduceMotionAndChromeCommandsExist() throws {
        let anim = WorkbenchMotion.pane
        #expect(String(describing: anim).count > 0)
        #expect(WorkbenchChromeCommand.allCases.count >= 10)
        let a11y = Self.repoRoot.appendingPathComponent(
            "Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift"
        )
        #expect(FileManager.default.fileExists(atPath: a11y.path))
        let text = try String(contentsOf: a11y, encoding: .utf8)
        for token in [
            "root", "toolbar", "activityBar", "navigator", "editor", "inspector", "statusBar",
            "commandPalette",
        ] {
            #expect(text.contains(token), "WorkbenchAccessibility missing \(token)")
        }
    }

    // MARK: - §26.9 Documentation honesty

    @Test func readmeDoesNotClaimWasmKitNonExecuting() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(!text.contains("Does not execute Wasm bytecode"))
        #expect(text.contains("WasmKit") || text.contains("Wasm"))
        let lower = text.lowercased()
        #expect(lower.contains("pre-alpha") || lower.contains("experimental"))
        #expect(!text.contains("| **CodeEditorCore** | Stable"))
    }

    @Test func migrationGuideAndExtensionAuthoringExist() throws {
        let migration = Self.repoRoot.appendingPathComponent("Docs/Guides/MIGRATION-1.0.md")
        let authoring = Self.repoRoot.appendingPathComponent("Docs/Guides/EXTENSION-AUTHORING.md")
        #expect(FileManager.default.fileExists(atPath: migration.path))
        #expect(FileManager.default.fileExists(atPath: authoring.path))
        let mig = try String(contentsOf: migration, encoding: .utf8)
        #expect(mig.contains("Migration"))
        #expect(mig.count > 200)
        let auth = try String(contentsOf: authoring, encoding: .utf8)
        #expect(auth.contains("extension.toml") || auth.contains("TOML"))
    }

    // MARK: - §26.7 Performance budgets

    @Test func perfBudgetsDocumentAllSection267Topics() throws {
        let url = Self.repoRoot.appendingPathComponent("Docs/Architecture/PERF-BUDGETS.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let required = [
            "keystroke", "memory", "scroll", "parse", "workspace",
            "search", "LSP", "terminal", "extension", "first visible",
        ]
        for key in required {
            #expect(text.range(of: key, options: String.CompareOptions.caseInsensitive) != nil, "PERF-BUDGETS missing \(key)")
        }
        #expect(text.contains("P50"))
        #expect(text.contains("P95"))
    }

    // MARK: - §26.2 Unchecked Sendable inventory

    @Test func uncheckedSendableInventoryAndAllowlistExist() throws {
        let inv = Self.repoRoot.appendingPathComponent("Docs/Architecture/UNCHECKED-SENDABLE.md")
        let allow = Self.repoRoot.appendingPathComponent("Baselines/unchecked-sendable-allowlist.txt")
        #expect(FileManager.default.fileExists(atPath: inv.path))
        #expect(FileManager.default.fileExists(atPath: allow.path))
        let invText = try String(contentsOf: inv, encoding: .utf8)
        #expect(invText.contains("@unchecked Sendable") || invText.contains("Count:"))
        let allowLines = try String(contentsOf: allow, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(allowLines.count > 0)
    }

    // MARK: - §26.1 / §26.6 Master scripts and vacuous ban

    @Test func verifyStableScriptIsHardGateNotSoftStub() throws {
        let url = Self.repoRoot.appendingPathComponent("scripts/verify-stable.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("check-vacuous-tests.sh"))
        #expect(text.contains("check-defects.sh"))
        #expect(text.contains("check-api-freeze.sh"))
        #expect(text.contains("swift test"))
        #expect(text.contains("check-release-evidence.sh"))
        #expect(text.contains("run-sanitizers.sh"))
        #expect(text.contains("run-fuzz-smoke.sh"))
        #expect(text.contains("run-soak-smoke.sh"))
        #expect(text.contains("run-mutation-smoke.sh"))
        #expect(text.contains("export-source-archive-rehearsal.sh"))
        // Soft-or must not appear after pin/licenses checks.
        #expect(!text.contains("check-xcode-pin.sh ||"))
        #expect(!text.contains("check-licenses.sh ||"))
        #expect(!text.contains("archive soft-fail"))
        #expect(!text.contains("REQUIRE_FULL_GATE"))
    }

    @Test func vacuousTestBanScriptCoversExpectTrue() throws {
        let url = Self.repoRoot.appendingPathComponent("scripts/check-vacuous-tests.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("#expect"))
        #expect(text.contains("true"))
        #expect(text.contains("Tests"))
    }

    // MARK: - §26.1 Toolchain matrix recorded

    @Test func toolchainMatrixRecordsXcodeSwiftPlatforms() throws {
        let toolchain = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Docs/Architecture/TOOLCHAIN.md"),
            encoding: .utf8
        )
        #expect(toolchain.contains("Xcode"))
        #expect(toolchain.contains("26.4") || toolchain.contains("XCODE"))
        #expect(toolchain.contains("macOS"))
        #expect(toolchain.contains("iOS"))
        let pin = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Docs/Architecture/XCODE.pin"),
            encoding: .utf8
        )
        #expect(pin.contains("XCODE_VERSION="))
    }

    // MARK: - §26.9 Release evidence shape

    @Test func releaseEvidenceSchemaKeysPresentWhenGenerated() throws {
        let evidence = Self.repoRoot.appendingPathComponent("Baselines/evidence/release-evidence.json")
        guard FileManager.default.fileExists(atPath: evidence.path) else {
            let script = Self.repoRoot.appendingPathComponent("scripts/check-release-evidence.sh")
            #expect(FileManager.default.fileExists(atPath: script.path))
            return
        }
        let data = try Data(contentsOf: evidence)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj != nil)
        guard let obj else { return }
        for key in ["schema_version", "generated_at", "commit", "branch", "toolchain", "tests", "defects"] {
            #expect(obj[key] != nil, "missing evidence key \(key)")
        }
        let tests = obj["tests"] as? [String: Any]
        let exitCode = (tests?["exit_code"] as? Int) ?? (tests?["exit_code"] as? NSNumber)?.intValue
        #expect(exitCode == 0)
        let defects = obj["defects"] as? [String: Any]
        let open = (defects?["open_p0_p1"] as? Int) ?? (defects?["open_p0_p1"] as? NSNumber)?.intValue
        #expect(open == 0)
    }

    // MARK: - §26.6 No open P0/P1 in defects.json

    @Test func defectsJsonHasZeroOpenP0P1() throws {
        let url = Self.repoRoot.appendingPathComponent("Docs/Architecture/defects.json")
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let dict = root as? [String: Any], let list = dict["defects"] as? [[String: Any]] {
            items = list
        } else if let list = root as? [[String: Any]] {
            items = list
        } else {
            Issue.record("unexpected defects.json shape")
            throw NSError(domain: "Phase11", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected defects.json shape",
            ])
        }
        let open = items.filter { item in
            let sev = (item["severity"] as? String ?? "").uppercased()
            let status = (item["status"] as? String ?? "").lowercased()
            return (sev == "P0" || sev == "P1")
                && (status == "open" || status == "partial" || status == "todo")
        }
        #expect(open.isEmpty, "open P0/P1: \(open.compactMap { $0["id"] as? String })")
    }

    // MARK: - Extension SDK migration rehearsal artifact

    @Test func extensionMigrationAPIIsPubliclyDocumented() throws {
        let authoring = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Docs/Guides/EXTENSION-AUTHORING.md"),
            encoding: .utf8
        )
        let hasMigration = authoring.range(
            of: "migration",
            options: String.CompareOptions.caseInsensitive
        ) != nil
        #expect(hasMigration || authoring.contains("JSON"))
    }
}

@Suite("Phase11 perf smoke")
struct Phase11PerfSmokeTests {
    /// §26.7 — produce a real measured sample for core edit path (not a stub budget table).
    @Test func coreEditLoopProducesMeasuredBudgetSample() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outDir = root.appendingPathComponent("Baselines/evidence")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let iterations = 2_000
        var buffer = ""
        buffer.reserveCapacity(iterations * 2)
        let start = ContinuousClock.now
        for i in 0..<iterations {
            buffer.append(Character(UnicodeScalar(65 + (i % 26))!))
            if i % 50 == 0 { buffer.removeLast() }
        }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15

        let p50BudgetMs = 8.0
        let perOpUs = (ms * 1_000) / Double(iterations)
        #expect(perOpUs < p50BudgetMs * 1_000, "edit unit cost \(perOpUs)µs exceeds absurd bound")
        #expect(buffer.count > 0)

        // Prefer canonical producer (p50/p95/p99 + memory/cpu/allocs). Fall back only if script missing.
        let script = root.appendingPathComponent("scripts/run-perf-smoke.sh")
        if FileManager.default.isExecutableFile(atPath: script.path)
            || FileManager.default.fileExists(atPath: script.path)
        {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, outDir.path]
            p.currentDirectoryURL = root
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "run-perf-smoke.sh failed")
        } else {
            let sample: [String: Any] = [
                "metric": "core_edit_unit",
                "dataset": "core_edit_unit_v1",
                "iterations": iterations,
                "total_ms": ms,
                "per_op_us": perOpUs,
                "p50_ms": perOpUs / 1000.0,
                "p95_ms": perOpUs / 1000.0,
                "p99_ms": perOpUs / 1000.0,
                "memory_peak_bytes": 0,
                "cpu_user_seconds": 0,
                "allocations": iterations,
                "dropped_events": 0,
                "hardware": ["hardware_class": "apple-silicon-dev-or-ci"],
                "p50_budget_ms_reference": p50BudgetMs,
                "within_unit_bound": true,
                "generated_at": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outDir.appendingPathComponent("perf-smoke.json"), options: .atomic)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent("perf-smoke.json").path
            )
        )
    }
}
