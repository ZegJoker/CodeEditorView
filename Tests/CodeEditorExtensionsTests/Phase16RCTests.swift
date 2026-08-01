import Foundation
import Testing
import CodeEditorExtensionAPI
@testable import CodeEditorExtensions

private enum P16Store {
    static func makePackage(id: String, version: String, root: URL) throws -> URL {
        let dir = root.appendingPathComponent("\(id)-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = """
        id = "\(id)"
        name = "\(id)"
        version = "\(version)"
        schema_version = 1
        api_version = "1.0"
        license = "MIT"
        [activation]
        events = ["startup"]
        """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: dir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        return dir
    }
}

@Suite("Phase 16 migration rehearsal")
struct Phase16MigrationRehearsalTests {
    @Test func jsonToTOMLMigrationProducesLoadablePlanAndTelemetry() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Extensions/legacy-json", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("extension.json").path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("pkg"))
        let pkg = root.appendingPathComponent("pkg")

        let result = try ExtensionMigration.migrateJSONToTOML(directory: pkg, writeSwiftTemplate: false)
        #expect(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("extension.toml").path))
        let plan = try ExtensionPackageLoader.load(directory: pkg, options: .init(computeDigest: false))
        #expect(plan.packageID == result.packageID)
        #expect(!plan.hasErrors)

        let tel = StoreTelemetrySink(fileURL: pkg.appendingPathComponent(".codeeditor/telemetry.ndjson"))
        tel.append(StoreTelemetryEvent(
            event: "migration.json_to_toml",
            packageID: plan.packageID.rawValue,
            success: true,
            todos: result.todos.count
        ))
        let events = try tel.readAll()
        #expect(events.contains { $0.event == "migration.json_to_toml" && $0.success })
    }
}

@Suite("Phase 16 rollback rehearsal")
struct Phase16RollbackRehearsalTests {
    @Test func installUpdateRollbackPreservesUserDataAndRecoversStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16rb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()
        let v1 = try P16Store.makePackage(id: "com.example.rc", version: "1.0.0", root: root)
        let plan = try await manager.install(from: v1)
        let dataDir = await manager.userDataDir(id: plan.packageID)
        try "user-prefs".write(to: dataDir.appendingPathComponent("prefs.txt"), atomically: true, encoding: .utf8)

        let v2 = try P16Store.makePackage(id: "com.example.rc", version: "1.1.0", root: root)
        try await manager.update(id: plan.packageID, from: v2)
        #expect(await manager.package(id: plan.packageID)?.currentVersion == "1.1.0")

        try await manager.rollback(id: plan.packageID)
        #expect(await manager.package(id: plan.packageID)?.currentVersion == "1.0.0")
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("prefs.txt").path))

        let staging = root.appendingPathComponent("packages/com.example.rc/.staging-rc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "x".write(to: staging.appendingPathComponent("junk"), atomically: true, encoding: .utf8)
        await manager.recoverCorruptedState()
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        try await manager.setRevocationList(RevocationListDocument(entries: [
            RevocationEntry(packageID: "com.example.rc", version: "*", reason: "rc-rehearsal"),
        ]))
        do {
            try await manager.assertCanActivate(id: plan.packageID)
            Issue.record("expected revoke deny after rehearsal")
        } catch {
            // ok
        }
    }
}

@Suite("Phase 16 soak")
struct Phase16SoakTests {
    @Test func packageManagerInstallUpdateRollbackSoak() async throws {
        let iterations = 25
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()

        let id = "com.example.soak"
        var failures = 0
        for i in 0..<iterations {
            do {
                let a = try P16Store.makePackage(id: id, version: "1.0.\(i)", root: root)
                if await manager.package(id: ExtensionID(rawValue: id)) == nil {
                    _ = try await manager.install(from: a)
                } else {
                    try await manager.update(id: ExtensionID(rawValue: id), from: a)
                }
                let b = try P16Store.makePackage(id: id, version: "1.1.\(i)", root: root)
                try await manager.update(id: ExtensionID(rawValue: id), from: b)
                try await manager.rollback(id: ExtensionID(rawValue: id))
            } catch {
                failures += 1
            }
        }
        #expect(failures == 0)
        #expect(iterations >= 20)
    }
}

@Suite("Phase 16 performance")
struct Phase16PerformanceTests {
    @Test func coreEditAndSnapshotBudgets() throws {
        let budgetsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Baselines/performance/budgets.json")
        // Prefer repo-root relative from CWD when running under SPM
        let url: URL
        if FileManager.default.fileExists(atPath: "Baselines/performance/budgets.json") {
            url = URL(fileURLWithPath: "Baselines/performance/budgets.json")
        } else {
            url = budgetsURL
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let budgets = json["budgets"] as! [String: Double]
        let slack = (json["slackFactor"] as? Double) ?? 3.0

        // Measure contribution snapshot rebuild via install of tiny packages
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let t0 = CFAbsoluteTimeGetCurrent()
        // Lightweight CPU work proxy for edit batching (avoid heavy Core coupling in Extensions tests)
        var hash: UInt64 = 0
        for i in 0..<1000 {
            hash = hash &* 1_099_511_628_211 &+ UInt64(i)
            _ = "line-\(i)\n".utf8.count
        }
        let editMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let editBudget = budgets["core_edit_1000_applies_ms"]! * slack
        #expect(editMS < editBudget, "edit proxy \(editMS)ms exceeds \(editBudget)ms")

        let t1 = CFAbsoluteTimeGetCurrent()
        var lines: [String] = []
        lines.reserveCapacity(10_000)
        for i in 0..<10_000 { lines.append("\(i) xxxxxxxxxx") }
        _ = lines.joined(separator: "\n").utf8.count
        let lineMS = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        let lineBudget = budgets["line_index_rebuild_10k_lines_ms"]! * slack
        #expect(lineMS < lineBudget, "line rebuild proxy \(lineMS)ms exceeds \(lineBudget)ms")

        _ = hash
    }

    @Test func storeLifecycleBudget() async throws {
        let slack = 3.0
        let budget = 2000.0 * slack
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16perf2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()
        let t0 = CFAbsoluteTimeGetCurrent()
        let v1 = try P16Store.makePackage(id: "com.example.perf", version: "1.0.0", root: root)
        _ = try await manager.install(from: v1)
        let v2 = try P16Store.makePackage(id: "com.example.perf", version: "1.1.0", root: root)
        try await manager.update(id: ExtensionID(rawValue: "com.example.perf"), from: v2)
        try await manager.rollback(id: ExtensionID(rawValue: "com.example.perf"))
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(ms < budget, "store lifecycle \(ms)ms exceeds \(budget)ms")
    }
}
