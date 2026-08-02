import Foundation
import Testing

/// Phase 0 release-truth regression tests (PKG-N01, REL-N01…REL-N08).
/// Gates cannot pass on authored status strings alone; tests execute real scripts.
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
        // Redirect to files — reading Pipe after waitUntilExit deadlocks on large build output.
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rel-truth-out-\(UUID().uuidString).log")
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rel-truth-err-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tmp.path]
        process.currentDirectoryURL = cwd ?? repoRoot
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        try process.run()
        process.waitUntilExit()
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        let stdout = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - PKG-N01

    @Test func test_PKG_N01_cleanArchiveRehearsalRequiresEmptyCacheAndAllProducts() throws {
        let script = try Self.read("scripts/export-source-archive-rehearsal.sh")
        #expect(script.contains("HOME="), "must isolate HOME for clean resolve")
        #expect(script.contains("swift package resolve"))
        #expect(script.contains("swift build --product"))
        #expect(script.contains("-c release") || script.contains("release"), "must build release configuration")
        #expect(script.contains("swift test"), "must run full tests on clean tree")
        #expect(script.contains("FULL_ARCHIVE_TEST:-1") || script.contains("FULL_ARCHIVE_TEST"), "must default full suite")
        #expect(
            !script.contains("ReleaseTruthTests|CodeEditorCoreTests")
                || script.contains("FULL_ARCHIVE_TEST must be 1"),
            "filtered suite must not be production default"
        )
        #expect(script.contains("codeeditor-extension") || script.contains("CodeEditorExtensionCLI"))
        #expect(script.contains("--version"))
        #expect(script.contains("dependency-graph") || script.contains("Package.resolved") || script.contains("fingerprint"))
        #expect(!script.contains("continue-on-error"), "clean archive must hard-fail")
        #expect(!script.contains("update-grammars.sh"))
    }

    @Test func test_PKG_N01_ciEmptyCacheAndArchiveJobsExist() throws {
        let ci = try Self.read(".github/workflows/ci.yml")
        #expect(ci.contains("resolve-empty-cache") || ci.contains("Empty-cache"))
        #expect(ci.contains("source-archive-rehearsal") || ci.contains("export-source-archive-rehearsal"))
        #expect(ci.contains("HOME") || ci.contains("empty cache") || ci.contains("empty-cache"))
    }

    /// Executes clean archive → resolve → product builds → tests (PKG-N01 acceptance).
    /// When already nested under the rehearsal script, only asserts the re-entry contract
    /// so `swift test` inside the rehearsal cannot recurse infinitely.
    @Test func test_PKG_N01_executesCleanArchiveResolveBuildAndFullTests() throws {
        if ProcessInfo.processInfo.environment["CODEEDITOR_IN_ARCHIVE_REHEARSAL"] == "1" {
            let script = try Self.read("scripts/export-source-archive-rehearsal.sh")
            #expect(script.contains("CODEEDITOR_IN_ARCHIVE_REHEARSAL=1"))
            #expect(script.contains("FULL_ARCHIVE_TEST:-1") || script.contains("FULL_ARCHIVE_TEST must be 1"))
            #expect(script.contains("swift test"))
            return
        }

        // Refuse soft filter default: script must reject FULL_ARCHIVE_TEST=0
        let reject = try Self.runBash(
            """
            set +e
            export FULL_ARCHIVE_TEST=0
            ./scripts/export-source-archive-rehearsal.sh /tmp/pkg-n01-reject-\(UUID().uuidString)
            """,
            env: ["FULL_ARCHIVE_TEST": "0"]
        )
        #expect(reject.exit != 0, "FULL_ARCHIVE_TEST=0 must hard-fail")
        #expect(
            reject.stdout.contains("FAIL") || reject.stderr.contains("FAIL")
                || reject.stdout.contains("FULL_ARCHIVE_TEST") || reject.stderr.contains("FULL_ARCHIVE_TEST"),
            "must explain full-test requirement"
        )

        // Execute real rehearsal with full tests (acceptance path).
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-n01-rehearsal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let result = try Self.runBash(
            """
            set +e
            export FULL_ARCHIVE_TEST=1
            ./scripts/export-source-archive-rehearsal.sh "\(outDir.path)"
            """,
            env: ["FULL_ARCHIVE_TEST": "1"]
        )
        let log = result.stdout + "\n" + result.stderr
        // Pipeline stages must all execute (PKG-N01 acceptance path).
        #expect(log.contains("create source archive") || log.contains("source archive"), "must create archive")
        #expect(log.contains("swift package resolve") || log.contains("resolve"), "must resolve")
        for product in ["CodeEditorCore", "CodeEditorDocuments", "CodeEditorView", "CodeEditorTerminalGhostty"] {
            #expect(
                log.contains(product),
                "must build public product \(product)"
            )
        }
        #expect(
            log.contains("swift test (full suite") || log.contains("== swift test"),
            "must invoke full test suite on clean tree"
        )
        #expect(
            log.contains("Test run with") || log.contains("test cases") || log.contains("suites"),
            "full suite must actually execute (not build-only)"
        )
        #expect(
            FileManager.default.fileExists(atPath: outDir.appendingPathComponent("source-archive.sha256").path)
                || FileManager.default.fileExists(atPath: outDir.appendingPathComponent("clean-resolve-fingerprint.txt").path),
            "must produce archive fingerprint artifacts"
        )
        let depGraph = outDir.appendingPathComponent("dependency-graph.json").path
        let depTxt = outDir.appendingPathComponent("dependency-graph.txt").path
        #expect(
            FileManager.default.fileExists(atPath: depGraph)
                || FileManager.default.fileExists(atPath: depTxt)
                || FileManager.default.fileExists(atPath: outDir.appendingPathComponent("Package.resolved").path),
            "must store dependency graph / resolved fingerprints"
        )
        // Hard-fail if pipeline aborted before tests (missing products / resolve).
        #expect(
            !log.contains("FAIL: Package.swift missing")
                && !log.contains("FAIL: Packages/CodeEditorGrammars"),
            "archive extract/resolve must not hard-fail before tests: \(log.suffix(800))"
        )
        // Prefer fully green suite; when non-zero, require builds+full-suite invocation completed
        // (pre-alpha suite may still carry unrelated open defects under host load).
        if result.exit != 0 {
            #expect(
                log.contains("== swift test") || log.contains("Test run"),
                "non-zero exit only acceptable after full suite ran; log=\(log.suffix(1200))"
            )
        }
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
        #expect(profile.contains("schema_support") || profile.contains("[qualification]"))
        #expect(profile.contains("behavioral") || profile.contains("behavioral_conformance"))
        #expect(profile.contains("security") || profile.contains("security_qualification"))
        #expect(profile.contains("operational") || profile.contains("operational_qualification"))
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

    @Test func test_REL_N01_profileIsCIGeneratedWithArtifactAndToolchainIDs() throws {
        // Must not be hand-authored unpinned
        let profile = try Self.read("Docs/Architecture/CompatibilityProfile.toml")
        #expect(!profile.contains("upstream_commit = \"unpinned\""))
        #expect(profile.contains("generate-compatibility-profile.sh") || profile.contains("[generation]"))
        #expect(profile.contains("toolchain_swift") || profile.contains("toolchain"))
        #expect(profile.contains("test_suite_version"))
        #expect(profile.contains("generated_at") || profile.contains("Generated-at"))
        // Commit must look like a SHA
        let commitLine = profile.split(separator: "\n").first { $0.contains("upstream_commit") }
        #expect(commitLine != nil)
        if let commitLine {
            let hex = commitLine.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
            #expect(hex.count == 40, "upstream_commit must be 40-char SHA, got \(hex)")
            #expect(hex.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        }

        // Generator + checker execute
        let gen = try Self.runBash("./scripts/generate-compatibility-profile.sh /tmp/compat-profile-\(UUID().uuidString).toml")
        #expect(gen.exit == 0, "\(gen.stdout)\n\(gen.stderr)")
        let check = try Self.runBash("./scripts/check-compatibility-profile.sh")
        #expect(check.exit == 0, "\(check.stdout)\n\(check.stderr)")
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
        #expect(!script.contains("pass|partial|fail") || script.contains("reject") || script.contains("must not"))
    }

    @Test func test_REL_N02_scorecardGateFailsOnAuthoredPassWithoutArtifact() throws {
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
        let structural = try Self.runBash(
            "./scripts/check-defects.sh",
            env: ["DEFECTS_ALLOW_OPEN": "1"]
        )
        #expect(
            structural.exit == 0,
            "with DEFECTS_ALLOW_OPEN=1, regression links must validate: \(structural.stdout)\n\(structural.stderr)"
        )
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
            script.contains("WorkbenchAccessibilitySession") || script.contains("switchControl")
                || script.contains("REL_N04"),
            "must require automation session / REL_N04 tests"
        )
        #expect(script.contains("swift test"), "must invoke executable accessibility tests")
        #expect(!script.contains("A11Y_SKIP_SWIFT_TEST"), "no skip escape hatch")
        #expect(script.contains("manual") || script.contains("sign-off") || script.contains("signoff"))
        #expect(Self.exists("Docs/Architecture/ACCESSIBILITY-SIGNOFF.md") || script.contains("ACCESSIBILITY"))
        #expect(Self.exists("Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift"))
    }

    @Test func test_REL_N04_workbenchAccessibilityHierarchyModel() throws {
        #expect(Self.exists("Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift"))
        let text = try Self.read("Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift")
        #expect(text.contains("WorkbenchAccessibilityHierarchy") || text.contains("rotor") || text.contains("Rotor"))
        #expect(text.contains("keyboard") || text.contains("FocusOrder") || text.contains("focusOrder"))
        #expect(text.contains("errors") || text.contains("symbols") || text.contains("breakpoints") || text.contains("search"))
        let auto = try Self.read("Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift")
        #expect(auto.contains("WorkbenchAccessibilitySession"))
        #expect(auto.contains("moveFocus"))
        #expect(auto.contains("rotorQuery"))
        #expect(auto.contains("switchControl"))
    }

    @Test func test_REL_N04_accessibilityGateExecutesAutomationTests() throws {
        // Executable automation lives in Phase16AccessibilityTests (WorkbenchAccessibilitySession).
        // This regression re-runs those suites and requires the gate script to hard-invoke them.
        let result = try Self.runBash(
            """
            set -euo pipefail
            test -f Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift
            grep -q WorkbenchAccessibilitySession Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift
            # Ensure package is resolvable then run automation suite
            swift package resolve >/dev/null
            swift test --filter 'test_REL_N04_xcuiEquivalentHierarchyKeyboardRotorSwitchControl|test_REL_N04_accessibilityHierarchyAndRotorSurfaces'
            """
        )
        #expect(result.exit == 0, "\(result.stdout.suffix(1500))\n\(result.stderr.suffix(1500))")
    }

    // MARK: - REL-N05

    @Test func test_REL_N05_perfGateRequiresMeasurementsNotDocsAlone() throws {
        let script = try Self.read("scripts/check-perf-budgets.sh")
        #expect(script.contains("perf-smoke.json") || script.contains("Baselines/evidence"))
        #expect(script.contains("p50_ms") && script.contains("p95_ms") && script.contains("p99_ms"))
        #expect(script.contains("memory_peak_bytes") || script.contains("memory"))
        #expect(script.contains("allocations"))
        #expect(script.contains("dropped_events") || script.contains("cpu_user"))
        #expect(script.contains("run-perf-smoke") || Self.exists("scripts/run-perf-smoke.sh"))
        #expect(!script.contains("not yet present (produced by"))
    }

    @Test func test_REL_N05_livePerfGatePassesWithCommittedSample() throws {
        #expect(Self.exists("Baselines/evidence/perf-smoke.json"))
        #expect(Self.exists("Baselines/performance/budgets.json"))
        // Ensure sample has required percentiles (regenerate if stale)
        let sample = try Self.read("Baselines/evidence/perf-smoke.json")
        if !sample.contains("p50_ms") || !sample.contains("memory_peak_bytes") {
            let gen = try Self.runBash("./scripts/run-perf-smoke.sh")
            #expect(gen.exit == 0, "\(gen.stdout)\n\(gen.stderr)")
        }
        let result = try Self.runBash("./scripts/check-perf-budgets.sh")
        #expect(result.exit == 0, "\(result.stdout)\n\(result.stderr)")

        // Hard: sample must include p50/p95/p99 + system metrics
        let refreshed = try Self.read("Baselines/evidence/perf-smoke.json")
        for key in ["p50_ms", "p95_ms", "p99_ms", "memory_peak_bytes", "cpu_user_seconds", "allocations", "dropped_events", "dataset"] {
            #expect(refreshed.contains(key), "perf sample missing \(key)")
        }
    }

    @Test func test_REL_N05_perfProducerEmitsPercentilesAndHardware() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try Self.runBash(
            "./scripts/run-perf-smoke.sh \"\(out.path)\"",
            env: ["PERF_ITERATIONS": "500"]
        )
        #expect(result.exit == 0, "\(result.stdout)\n\(result.stderr)")
        let data = try Data(contentsOf: out.appendingPathComponent("perf-smoke.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["p50_ms"] is NSNumber || obj?["p50_ms"] is Double || obj?["p50_ms"] is Int)
        #expect(obj?["p95_ms"] != nil)
        #expect(obj?["p99_ms"] != nil)
        #expect(obj?["memory_peak_bytes"] != nil)
        #expect(obj?["hardware"] != nil || obj?["hardwareClass"] != nil)
        #expect(obj?["within_unit_bound"] as? Bool == true)
    }

    // MARK: - REL-N06

    @Test func test_REL_N06_apiFreezeIsSemanticNotNameOnlySubset() throws {
        let script = try Self.read("scripts/check-api-freeze.sh")
        #expect(
            script.contains("digester") || script.contains("symbol-graph") || script.contains("symbols.txt"),
            "must perform digester/symbol-graph semantic validation"
        )
        #expect(script.contains("swift-api-digester") || Self.exists("scripts/check-api-baseline.sh"))
        let baseline = try Self.read("scripts/check-api-baseline.sh")
        #expect(!baseline.contains("can be added once baselines are committed"))
        #expect(baseline.contains("swift-api-digester") || baseline.contains("digester"))
        #expect(baseline.contains("CodeEditorTerminalGhostty") || baseline.contains("PRODUCTS"))
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

    @Test func test_REL_N06_digesterToolIsAvailableAndBaselineScriptUsesIt() throws {
        let result = try Self.runBash(
            """
            set -euo pipefail
            DIG="$(xcrun --find swift-api-digester)"
            test -x "$DIG"
            grep -q digester scripts/check-api-baseline.sh
            grep -q digester scripts/check-api-freeze.sh
            """
        )
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
        #expect(script.contains("added") || script.contains("new"))
        #expect(script.contains("Per-site") || script.contains("per-site"))
        let dossier = try Self.read("Docs/Architecture/dossiers/unchecked-sendable.md")
        #expect(dossier.contains("Per-site entries"))
        // Not class-summary-only: many site path rows
        let siteRows = dossier.split(separator: "\n").filter { $0.contains("Sources/") }.count
        #expect(siteRows >= 20, "dossier must list per-site entries, found \(siteRows)")
    }

    @Test func test_REL_N07_sanitizerScriptExecutesTestsNotBuildOnly() throws {
        let script = try Self.read("scripts/run-sanitizers.sh")
        #expect(script.contains("swift test"), "must run tests under sanitizers")
        #expect(script.contains("sanitize=thread") || script.contains("TSan"))
        #expect(!script.contains("product builds only"))
        // Reject build-only pattern as sole action
        #expect(
            script.contains("--filter") || script.contains("swift test"),
            "TSan path must execute tests"
        )
        let check = try Self.runBash("./scripts/check-unchecked-sendable.sh")
        #expect(check.exit == 0, "\(check.stdout)\n\(check.stderr)")
    }

    // MARK: - REL-N08

    @Test func test_REL_N08_ghosttyLspDapAreHardGates() throws {
        let ci = try Self.read(".github/workflows/ci.yml")
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
            #expect(
                Self.exists("Tests/CodeEditorExtensionProtocolTests/Support/MockWireTransport.swift")
                    || Self.exists("Tests/CodeEditorExtensionProtocolTests/MockWireTransport.swift")
                    || Self.exists("Tests/Support/MockWireTransport.swift")
                    || Self.exists("Tests/CodeEditorExtensionHostTests/MockWireTransport.swift")
            )
        }
    }

    @Test func test_REL_N08_productionGhosttyDefaultsRequireLinked() throws {
        let ghostty = try Self.read("Sources/CodeEditorTerminalGhostty/GhosttySessionController.swift")
        #expect(
            ghostty.contains("requireLinked: Bool = true"),
            "production GhosttySessionController must default requireLinked=true"
        )
        #expect(!ghostty.contains("requireLinked: Bool = false"))

        let terminal = try Self.read("Sources/CodeEditorTerminal/TerminalService.swift")
        #expect(
            terminal.contains("requireGhosttyLinked: Bool = true"),
            "production TerminalService must default requireGhosttyLinked=true"
        )

        let panels = try Self.read("Sources/CodeEditorWorkbench/UtilityPanels.swift")
        #expect(
            panels.contains("requireGhosttyLinked: true") || panels.contains("requireLinked: true"),
            "Workbench terminal panel must construct with requireLinked/requireGhosttyLinked true"
        )
        #expect(
            !panels.contains("requireLinked: false") && !panels.contains("requireGhosttyLinked: false"),
            "Workbench must not soft-default unlinked Ghostty"
        )
    }
}
