import Foundation
import Testing

/// Phase 0 release-truth regression tests (PKG-N01, REL-N01…REL-N08).
/// These assert gates cannot pass on authored status strings alone.
@Suite("Release truth gates (Phase 0)")
struct ReleaseTruthTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ReleaseTruthTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo
    }

    private static func read(_ relative: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relative).path)
    }

    private static func runBash(
        _ scriptBody: String,
        env: [String: String] = [:],
        cwd: URL? = nil
    ) throws -> (exit: Int32, stdout: String, stderr: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rel-truth-\(UUID().uuidString).sh")
        try scriptBody.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tmp.path]
        process.currentDirectoryURL = cwd ?? repoRoot
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - PKG-N01

    @Test func test_PKG_N01_cleanArchiveRehearsalRequiresEmptyCacheAndAllProducts() throws {
        let script = try Self.read("scripts/export-source-archive-rehearsal.sh")
        #expect(script.contains("HOME="), "must isolate HOME for clean resolve")
        #expect(script.contains("swift package resolve"))
        #expect(script.contains("swift build --product"))
        #expect(script.contains("-c release") || script.contains("release"), "must build release configuration")
        #expect(script.contains("swift test") || script.contains("--filter"), "must exercise tests on clean tree")
        #expect(script.contains("codeeditor-extension") || script.contains("CodeEditorExtensionCLI"))
        #expect(script.contains("--version"))
        #expect(script.contains("dependency-graph") || script.contains("Package.resolved") || script.contains("fingerprint"))
        #expect(!script.contains("continue-on-error"), "clean archive must hard-fail")
        // Must not rely on developer bootstrap mutating the source tree as a prerequisite.
        #expect(!script.contains("update-grammars.sh"))
    }

    @Test func test_PKG_N01_ciEmptyCacheAndArchiveJobsExist() throws {
        let ci = try Self.read(".github/workflows/ci.yml")
        #expect(ci.contains("resolve-empty-cache") || ci.contains("Empty-cache"))
        #expect(ci.contains("source-archive-rehearsal") || ci.contains("export-source-archive-rehearsal"))
        #expect(ci.contains("HOME") || ci.contains("empty cache") || ci.contains("empty-cache"))
    }

    // MARK: - REL-N01

    @Test func test_REL_N01_compatibilityProfileIsPreAlphaNotPhase16RC() throws {
        let profile = try Self.read("Docs/Architecture/CompatibilityProfile.toml")
        #expect(!profile.contains("phase-16-rc"), "must not claim phase-16-rc")
        #expect(
            profile.contains("status = \"experimental\"")
                || profile.contains("status = \"pre-alpha\"")
                || profile.contains("status = \"pre_alpha\""),
            "status must be experimental/pre-alpha"
        )
        #expect(!profile.contains("S0_package = \"passing\""))
        #expect(!profile.contains("S1_data = \"passing\""))
        #expect(!profile.contains("S2_swift_api_parity = \"passing\""))
        #expect(!profile.contains("S3_behavioral = \"passing\""))
        #expect(!profile.contains("S4_operational = \"passing\""))
        // Split qualification axes present
        #expect(profile.contains("schema_support") || profile.contains("[qualification]"))
        #expect(profile.contains("behavioral") || profile.contains("behavioral_conformance"))
        #expect(profile.contains("security") || profile.contains("security_qualification"))
        #expect(profile.contains("operational") || profile.contains("operational_qualification"))
        // Features must not mass-claim stable for pre-alpha
        let stableFeatureCount = profile.split(separator: "\n").filter {
            $0.contains("=") && $0.contains("\"stable\"") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }.count
        #expect(stableFeatureCount == 0, "pre-alpha profile must not mark features stable (found \(stableFeatureCount))")
    }

    @Test func test_REL_N01_readmeAndProfileAgreeOnMaturity() throws {
        let readme = try Self.read("README.md").lowercased()
        let profile = try Self.read("Docs/Architecture/CompatibilityProfile.toml").lowercased()
        #expect(readme.contains("pre-alpha") || readme.contains("experimental"))
        #expect(profile.contains("pre-alpha") || profile.contains("experimental"))
        #expect(!profile.contains("phase-16-rc"))
    }

    // MARK: - REL-N02

    @Test func test_REL_N02_scorecardGateRejectsFailWithEmptyResidual() throws {
        let script = try Self.read("scripts/check-product-scorecards.sh")
        #expect(
            script.contains("residual") && (script.contains("fail") || script.contains("partial")),
            "must reason about fail/partial vs residual"
        )
        #expect(script.contains("CodeEditorTerminalGhostty") || script.contains("TerminalGhostty"))
        #expect(script.contains("codeeditor-extension") || script.contains("CodeEditorExtensionCLI"))
        #expect(script.contains("ConformanceExtensionGuest"))
        #expect(script.contains("artifact") || script.contains("evidence"))
        #expect(
            script.contains("RELEASE_CERTIFY") || script.contains("certification"),
            "must distinguish pre-alpha honesty from release certification"
        )
        // Must not accept pass|partial|fail indiscriminately as OK with empty residual
        #expect(!script.contains("pass|partial|fail") || script.contains("reject") || script.contains("must not"))
    }

    @Test func test_REL_N02_scorecardGateFailsOnAuthoredPassWithoutArtifact() throws {
        // Fixture: pass status without real artifact path → checker must fail.
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("scorecard-fake-\(UUID().uuidString).toml")
        let body = """
            schema_version = 2
            certification = "pre-alpha"
            program = "fixture"

            [[product]]
            name = "CodeEditorCore"
            tier = "Pre-alpha"
            open_p0 = 0
            open_p1 = 0
            api = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-api.json" }
            correctness = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-correctness.json" }
            concurrency = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-concurrency.json" }
            tests = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-tests.json" }
            platform = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-platform.json" }
            operations = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-operations.json" }
            docs = { status = "pass", artifact = "Baselines/evidence/DOES-NOT-EXIST-docs.json" }
            residual = []
            """
        try body.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try Self.runBash(
            """
            set -euo pipefail
            export SCORECARD_PATH="\(fixture.path)"
            ./scripts/check-product-scorecards.sh
            """,
            env: ["SCORECARD_PATH": fixture.path]
        )
        #expect(result.exit != 0, "authored pass without artifacts must fail; out=\(result.stdout)\n\(result.stderr)")
    }

    @Test func test_REL_N02_liveScorecardsPassStructuralHonestyGate() throws {
        let result = try Self.runBash("./scripts/check-product-scorecards.sh")
        #expect(result.exit == 0, "live scorecards must be structurally honest: \(result.stdout)\n\(result.stderr)")
    }

    // MARK: - REL-N03

    @Test func test_REL_N03_defectGateRequiresRegressionTestsForFixed() throws {
        let script = try Self.read("scripts/check-defects.sh")
        #expect(script.contains("regression_tests") || script.contains("regression-tests"))
        #expect(script.contains("defects.json"))
        #expect(
            script.contains("Tests/") || script.contains("rg ") || script.contains("exists"),
            "must verify regression tests exist"
        )
        #expect(script.contains("XCTSkip") || script.contains("skipped") || script.contains("skip"))
    }

    @Test func test_REL_N03_defectGateRejectsFixedWithoutRegressionTests() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("defects-fake-\(UUID().uuidString).json")
        let body = """
            {
              "schema_version": 2,
              "defects": [
                {
                  "id": "FAKE-001",
                  "severity": "P0",
                  "product": "Package",
                  "status": "fixed",
                  "summary": "claims fixed without tests",
                  "regression_tests": []
                }
              ]
            }
            """
        try body.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = try Self.runBash(
            """
            set -euo pipefail
            export DEFECTS_JSON="\(fixture.path)"
            export DEFECTS_MD="/dev/null"
            ./scripts/check-defects.sh
            """,
            env: ["DEFECTS_JSON": fixture.path, "DEFECTS_MD": "/dev/null"]
        )
        #expect(result.exit != 0, "fixed without regression_tests must fail")
    }

    @Test func test_REL_N03_liveDefectsLinkRegressionTests() throws {
        let result = try Self.runBash("./scripts/check-defects.sh")
        // Gate itself must be sound; open P0/P1 may still fail release until remediated.
        // Structural mode: DEFECTS_ALLOW_OPEN=1 validates links without requiring zero open blockers.
        let structural = try Self.runBash(
            "./scripts/check-defects.sh",
            env: ["DEFECTS_ALLOW_OPEN": "1"]
        )
        #expect(
            structural.exit == 0,
            "with DEFECTS_ALLOW_OPEN=1, regression links must validate: \(structural.stdout)\n\(structural.stderr)"
        )
        // Full gate exit is acceptable either 0 (no open blockers) or 1 (honest open P0/P1).
        #expect(result.exit == 0 || result.exit == 1)
        if result.exit == 1 {
            #expect(
                result.stdout.contains("open P0/P1") || result.stderr.contains("open P0/P1")
                    || result.stdout.contains("FAIL"),
                "failure must be about open blockers or validation, not crash"
            )
        }
    }

    // MARK: - REL-N04

    @Test func test_REL_N04_accessibilityGateIsMoreThanTokenGrep() throws {
        let script = try Self.read("scripts/check-accessibility.sh")
        #expect(
            script.contains("focus") || script.contains("FocusOrder") || script.contains("keyboard"),
            "must validate keyboard/focus order"
        )
        #expect(
            script.contains("rotor") || script.contains("Rotor") || script.contains("hierarchy"),
            "must validate VO-relevant hierarchy/rotor surface"
        )
        #expect(
            script.contains("ReleaseTruth") || script.contains("swift test") || script.contains("Phase16Accessibility")
                || script.contains("AccessibilityHierarchy"),
            "must invoke executable accessibility tests"
        )
        #expect(script.contains("manual") || script.contains("sign-off") || script.contains("signoff"))
        #expect(Self.exists("Docs/Architecture/ACCESSIBILITY-SIGNOFF.md") || script.contains("ACCESSIBILITY"))
    }

    @Test func test_REL_N04_workbenchAccessibilityHierarchyModel() throws {
        // Executable hierarchy contract (not XCUI, but real model assertions).
        #expect(Self.exists("Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift"))
        let text = try Self.read("Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift")
        #expect(text.contains("WorkbenchAccessibilityHierarchy") || text.contains("rotor") || text.contains("Rotor"))
        #expect(text.contains("keyboard") || text.contains("FocusOrder") || text.contains("focusOrder"))
        #expect(text.contains("errors") || text.contains("symbols") || text.contains("breakpoints") || text.contains("search"))
    }

    // MARK: - REL-N05

    @Test func test_REL_N05_perfGateRequiresMeasurementsNotDocsAlone() throws {
        let script = try Self.read("scripts/check-perf-budgets.sh")
        #expect(script.contains("perf-smoke.json") || script.contains("Baselines/evidence"))
        #expect(script.contains("p50") || script.contains("P50") || script.contains("p95") || script.contains("P95"))
        #expect(script.contains("p99") || script.contains("P99"))
        #expect(
            script.contains("FAIL") && (script.contains("missing") || script.contains("not yet present") == false
                || script.contains("required")),
            "missing measurements must hard-fail"
        )
        // Soft note path that exits 0 without sample is forbidden.
        #expect(!script.contains("not yet present (produced by"))
    }

    @Test func test_REL_N05_livePerfGatePassesWithCommittedSample() throws {
        #expect(Self.exists("Baselines/evidence/perf-smoke.json"))
        #expect(Self.exists("Baselines/performance/budgets.json"))
        let result = try Self.runBash("./scripts/check-perf-budgets.sh")
        #expect(result.exit == 0, "\(result.stdout)\n\(result.stderr)")
    }

    // MARK: - REL-N06

    @Test func test_REL_N06_apiFreezeIsSemanticNotNameOnlySubset() throws {
        let script = try Self.read("scripts/check-api-freeze.sh")
        #expect(
            script.contains("symbol") || script.contains("signature") || script.contains("Sendable")
                || script.contains("availability") || script.contains("digester") || script.contains("semantic"),
            "must perform semantic surface validation"
        )
        // Must cover all public library products, not a tiny Stable subset alone.
        let productsTxt = try Self.read("Baselines/api/PRODUCTS.txt")
        let listed = productsTxt.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(listed.count >= 26, "API inventory must cover public libraries, got \(listed.count)")
        #expect(script.contains("CodeEditorDAP") || productsTxt.contains("CodeEditorDAP"))
        #expect(script.contains("CodeEditorExtensionHost") || productsTxt.contains("CodeEditorExtensionHost"))
    }

    @Test func test_REL_N06_apiFreezeScriptRuns() throws {
        let result = try Self.runBash("./scripts/check-api-freeze.sh")
        #expect(result.exit == 0, "\(result.stdout)\n\(result.stderr)")
    }

    // MARK: - REL-N07

    @Test func test_REL_N07_strictConcurrencyIsWarningsAsErrors() throws {
        let ci = try Self.read(".github/workflows/ci.yml")
        #expect(
            ci.contains("warnings-as-errors") || ci.contains("Werror") || ci.contains("-warnings-as-errors"),
            "CI must enable warnings-as-errors for concurrency"
        )
        #expect(!ci.contains("warnings-as-errors deferred"))
        let script = try Self.read("scripts/check-unchecked-sendable.sh")
        #expect(script.contains("dossier") || Self.exists("Docs/Architecture/dossiers/unchecked-sendable.md"))
        #expect(script.contains("allowlist"))
        // Ratchet: no new sites without approval (fail on added)
        #expect(script.contains("added") || script.contains("new"))
    }

    // MARK: - REL-N08

    @Test func test_REL_N08_ghosttyLspDapAreHardGates() throws {
        let ci = try Self.read(".github/workflows/ci.yml")
        // Ghostty must not be continue-on-error for the linked path.
        let ghosttySection: String = {
            if let r = ci.range(of: "ghostty") {
                return String(ci[r.lowerBound...].prefix(1200))
            }
            return ci
        }()
        #expect(
            !ghosttySection.contains("continue-on-error: true")
                || ci.contains("REQUIRE_GHOSTTY=1")
                || ci.contains("ghostty-linked"),
            "Ghostty linked build must not soft-fail on release paths"
        )
        let lsp = try Self.read("scripts/check-real-lsp.sh")
        let dap = try Self.read("scripts/check-real-dap.sh")
        #expect(lsp.contains("initialize") || lsp.contains("REQUIRE_REAL_LSP"))
        #expect(dap.contains("initialize") || dap.contains("REQUIRE_REAL_DAP"))
        // Hard default for release verify scripts.
        let stable = try Self.read("scripts/verify-stable.sh")
        #expect(stable.contains("REQUIRE_REAL_LSP=1") || stable.contains("REQUIRE_REAL_LSP"))
        #expect(stable.contains("REQUIRE_REAL_DAP=1") || stable.contains("REQUIRE_REAL_DAP"))
        #expect(stable.contains("check-ghostty") || stable.contains("GHOSTTY") || stable.contains("ghostty"))
    }

    @Test func test_REL_N08_realLspScriptHardFailsWhenRequiredAndMissing() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-lsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = try Self.runBash(
            """
            set -euo pipefail
            export REQUIRE_REAL_LSP=1
            export CODEEDITOR_LSP_SEARCH_PATH="\(empty.path)"
            ./scripts/check-real-lsp.sh
            """,
            env: [
                "REQUIRE_REAL_LSP": "1",
                "CODEEDITOR_LSP_SEARCH_PATH": empty.path,
            ]
        )
        #expect(result.exit != 0, "must hard-fail when required and no server under search path; out=\(result.stdout)\n\(result.stderr)")
        #expect(
            result.stdout.contains("FAIL") || result.stderr.contains("FAIL"),
            "failure message required"
        )
    }

    @Test func test_REL_N08_productionMocksNotDefaultInProtocolDAPModules() throws {
        // Mocks must live under Tests/ (or clearly non-default test support), not as production defaults.
        let mockDAP = Self.exists("Sources/CodeEditorDAP/Testing/MockDebugAdapter.swift")
        let mockWire = try? Self.read("Sources/CodeEditorExtensionProtocol/MockWireTransport.swift")
        if mockDAP {
            Issue.record("MockDebugAdapter still under Sources/CodeEditorDAP/Testing — move to Tests/")
        }
        #expect(!mockDAP, "MockDebugAdapter must not ship as production source")
        if let mockWire {
            #expect(
                mockWire.contains("#if") && mockWire.contains("TEST"),
                "MockWireTransport must not be unconditional production API"
            )
        } else {
            // Moved out of Sources — good.
            #expect(
                Self.exists("Tests/CodeEditorExtensionProtocolTests/Support/MockWireTransport.swift")
                    || Self.exists("Tests/CodeEditorExtensionProtocolTests/MockWireTransport.swift")
                    || Self.exists("Tests/Support/MockWireTransport.swift")
                    || Self.exists("Tests/CodeEditorExtensionHostTests/MockWireTransport.swift")
            )
        }
    }
}
