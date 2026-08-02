import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation
import Testing

// MARK: - Fixture paths

private enum Fixtures {
    /// Prefer SPM resource bundle; fall back to source tree for local runs.
    static var root: URL {
        if let url = Bundle.module.url(forResource: "Extensions", withExtension: nil) {
            return url
        }
        // Tests/CodeEditorExtensionAPITests → Tests/Fixtures/Extensions
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Extensions", isDirectory: true)
    }

    static func package(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}

// MARK: - S0 / S1

@Suite("S0 package compatibility")
struct S0PackageTests {
    @Test func loadsBasicManifest() throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("s0-basic"))
        #expect(plan.packageID.rawValue == "com.codeeditor.fixtures.s0-basic")
        #expect(plan.displayName == "S0 Basic Package")
        #expect(plan.version == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(plan.sourceFormat == .toml)
        #expect(plan.parityProfile == "codeeditor-data-s0")
        #expect(plan.themes.isEmpty)
        #expect(plan.snippets.isEmpty)
        #expect(plan.languages.isEmpty)
        #expect(plan.digest != nil)
        #expect(!plan.hasErrors)
        #expect(plan.manifest.activationEvents.contains { $0.matches(.startup) })
    }

    @Test func digestIsStable() throws {
        let a = try ExtensionPackageDigest.compute(packageRoot: Fixtures.package("s0-basic"))
        let b = try ExtensionPackageDigest.compute(packageRoot: Fixtures.package("s0-basic"))
        #expect(a == b)
        #expect(a.count == 64)  // sha256 hex
    }
}

@Suite("S1 data compatibility")
struct S1DataTests {
    @Test func loadsThemesIconsSnippetsLanguagesGrammarsQueries() throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("s1-data"))
        #expect(plan.packageID.rawValue == "com.codeeditor.fixtures.s1-data")
        #expect(plan.parityProfile == "codeeditor-data-s1")
        #expect(plan.sourceFormat == .toml)
        #expect(!plan.hasErrors)

        #expect(plan.themes.count == 2)
        let midnight = plan.themes.first { $0.id == "midnight" }
        #expect(midnight?.tokens["keyword"] == "#c792ea")
        let dawn = plan.themes.first { $0.id == "dawn" }
        #expect(dawn?.tokens["keyword"] == "#d73a49")

        #expect(plan.snippets.count == 2)
        #expect(plan.snippets.contains { $0.prefix == "hello" })

        #expect(plan.iconThemes.count == 1)
        #expect(plan.iconThemes[0].fileIcons["ex"] == "assets/file-ex.svg")

        #expect(plan.languages.count == 1)
        let lang = try #require(plan.languages.first)
        #expect(lang.id == "example")
        #expect(lang.displayName == "Example Lang")
        #expect(lang.fileExtensions.contains("ex"))
        #expect(lang.lineComment == "//")
        #expect(lang.highlightsQuery != nil)

        #expect(plan.grammars.count == 1)
        #expect(plan.grammars[0].repository != nil)
        #expect(plan.queries.count >= 3)  // highlights, brackets, indents
        #expect(plan.queries.contains { $0.kind == "highlights" })
        #expect(!plan.assets.isEmpty)
    }

    @Test func dataOnlyActivationRegistersContributions() async throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("s1-data"))
        let ext = DataExtensionLoader.makeExtension(from: plan)
        let services = await MainActor.run {
            ExtensionHostServices.makeFull(
                storageRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("s1-act-\(UUID().uuidString)")
            )
        }
        let runtime = ExtensionRuntime(
            environment: HostEnvironment(
                capabilities: Set(HostCapability.allCases),
                grantedPermissions: [.presentUI]
            ),
            services: services
        )
        await runtime.register(ext)
        try await runtime.activate(id: plan.packageID)

        let themes = await runtime.themeStore.all()
        #expect(themes.count == 2)
        let snippets = await runtime.snippetStore.all()
        #expect(snippets.count == 2)
        let icons = await runtime.iconThemeStore.all()
        #expect(icons.count == 1)

        await runtime.deactivate(id: plan.packageID)
        #expect(await runtime.themeStore.all().isEmpty)
        #expect(await runtime.iconThemeStore.all().isEmpty)
    }
}

// MARK: - TOML corpus

@Suite("extension.toml corpus")
struct TOMLCorpusTests {
    @Test func dualManifestTOMLWins() throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("corpus/dual-manifest"))
        #expect(plan.sourceFormat == .toml)
        #expect(plan.displayName == "Dual Manifest TOML")
        #expect(plan.version == SemanticVersion(major: 2))
        #expect(plan.diagnostics.contains { $0.code == "package.dual_manifest" })
    }

    @Test func badSchemaRejected() {
        #expect(throws: ExtensionError.self) {
            try ExtensionPackageLoader.load(directory: Fixtures.package("corpus/bad-schema"))
        }
    }

    @Test func malformedMissingIDRejected() {
        #expect(throws: ExtensionError.self) {
            try ExtensionPackageLoader.load(directory: Fixtures.package("malformed"))
        }
    }

    @Test func activationEventVariants() throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("corpus/activation"))
        let events = plan.manifest.activationEvents
        #expect(events.contains { $0.matches(.startup) })
        #expect(events.contains { $0.matches(.workspaceOpened) })
        #expect(events.contains { $0.matches(.language("swift")) })
        #expect(events.contains { $0.matches(.command("foo.bar")) })
        #expect(events.contains { $0.matches(.fileMatch(pattern: "readme.md")) })
        #expect(events.contains { $0.matches(.view("panel")) })
        #expect(events.contains { $0.matches(.manual) })
    }

    @Test func parserRejectsOversizedManifest() {
        let huge = "id = \"x\"\nname = \"y\"\n" + String(repeating: "# pad\n", count: 300_000)
        #expect(throws: ExtensionError.self) {
            try ExtensionTOMLParser.parse(string: huge)
        }
    }

    @Test func parseInlineCapabilitiesAndPermissions() throws {
        let src = """
            id = "com.example.caps"
            name = "Caps"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            capabilities = ["themes", "snippets"]
            permissions = ["readWorkspace", "presentUI"]
            [activation]
            events = ["startup"]
            """
        let (m, _) = try ExtensionTOMLParser.parse(string: src)
        #expect(m.capabilities.contains("themes"))
        #expect(m.permissions.contains("presentUI"))
        let manifest = try m.toExtensionManifest()
        #expect(manifest.requiredHostCapabilities.contains(.themes))
        #expect(manifest.requestedPermissions.contains(.presentUI))
    }
}

// MARK: - Migration

@Suite("JSON → TOML migration")
struct MigrationTests {
    @Test func migratesLegacyJSON() throws {
        let src = Fixtures.package("legacy-json")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try ExtensionMigration.migrateJSONToTOML(directory: tmp, writeSwiftTemplate: true)
        #expect(result.packageID.rawValue == "com.codeeditor.fixtures.legacy")
        #expect(FileManager.default.fileExists(atPath: result.tomlPath.path))
        #expect(result.plan.sourceFormat == .toml)
        #expect(result.plan.themes.count == 1)
        #expect(result.plan.snippets.count == 1)
        #expect(result.plan.languages.count == 1)
        #expect(result.plan.iconThemes.count == 1)
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Package.swift").path))
        #expect(result.todos.contains { $0.contains("keybindings") })
    }

    @Test func legacyJSONLoader() throws {
        let plan = try ExtensionPackageLoader.load(directory: Fixtures.package("legacy-json"))
        #expect(plan.sourceFormat == .legacyJSON)
        #expect(plan.themes.count == 1)
        #expect(plan.keybindings.count == 1)
        #expect(plan.diagnostics.contains { $0.code == "package.legacy_json" })
    }

    @Test func legacyJSONDisabled() {
        #expect(throws: ExtensionError.self) {
            try ExtensionPackageLoader.load(
                directory: Fixtures.package("legacy-json"),
                options: .init(allowLegacyJSON: false, computeDigest: false)
            )
        }
    }
}

// MARK: - Digests & path safety

@Suite("Package digests and safety")
struct DigestSafetyTests {
    @Test func digestMismatchThrows() throws {
        let digest = try ExtensionPackageDigest.compute(packageRoot: Fixtures.package("s0-basic"))
        #expect(throws: ExtensionError.self) {
            try ExtensionPackageLoader.load(
                directory: Fixtures.package("s0-basic"),
                options: .init(expectedDigest: "deadbeef")
            )
        }
        let ok = try ExtensionPackageLoader.load(
            directory: Fixtures.package("s0-basic"),
            options: .init(expectedDigest: digest)
        )
        #expect(ok.digest == digest)
    }

    @Test func pathContainmentHelper() {
        let root = URL(fileURLWithPath: "/tmp/pkg-root", isDirectory: true)
        let inside = root.appendingPathComponent("themes/a.json")
        let outside = URL(fileURLWithPath: "/etc/passwd")
        #expect(ExtensionPackageLoader.isPathContained(url: inside, within: root))
        #expect(!ExtensionPackageLoader.isPathContained(url: outside, within: root))
    }
}

// MARK: - Immutable registries

@Suite("Immutable contribution registry")
struct RegistryTests {
    @Test func collisionIsDeterministic() throws {
        let a = ValidatedContributionPlan(
            packageID: "pkg.a",
            displayName: "A",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "pkg.a", displayName: "A"),
            sourceFormat: .toml,
            themes: [ThemeContribution(id: "shared", displayName: "From A", tokens: ["k": "a"])]
        )
        let b = ValidatedContributionPlan(
            packageID: "pkg.b",
            displayName: "B",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "pkg.b", displayName: "B"),
            sourceFormat: .toml,
            themes: [ThemeContribution(id: "shared", displayName: "From B", tokens: ["k": "b"])]
        )
        let snap = ImmutableContributionRegistry.build(packages: [b, a], generation: 1)
        #expect(snap.themes.count == 1)
        #expect(snap.themes[0].displayName == "From B")  // pkg.b > pkg.a lexicographically
        #expect(snap.collisions.count == 1)
        #expect(snap.collisions[0].winnerPackageID.rawValue == "pkg.b")
        #expect(snap.collisions[0].loserPackageID.rawValue == "pkg.a")
    }
}

// MARK: - Package manager lifecycle

@Suite("ExtensionPackageManager")
struct PackageManagerTests {
    @Test func installEnableDisableUpdateRollbackUninstall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkgmgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let s0 = try await manager.install(from: Fixtures.package("s0-basic"))
        #expect(s0.packageID.rawValue == "com.codeeditor.fixtures.s0-basic")
        #expect(await manager.snapshot.packages.count == 1)

        let s1 = try await manager.install(from: Fixtures.package("s1-data"))
        #expect(s1.themes.count == 2)
        var snap = await manager.snapshot
        #expect(snap.packages.count == 2)
        #expect(snap.themes.count == 2)

        try await manager.disable(id: s1.packageID)
        snap = await manager.snapshot
        #expect(snap.themes.isEmpty)

        try await manager.enable(id: s1.packageID)
        snap = await manager.snapshot
        #expect(snap.themes.count == 2)

        // Update to a new immutable version, then roll back to previous version tree.
        // Fixture s1-data ships as 1.2.0 — bump to a distinct version for real previous pointer.
        let baselineVersion = s1.version.description
        let updateDir = root.appendingPathComponent("s1-update", isDirectory: true)
        try FileManager.default.copyItem(at: Fixtures.package("s1-data"), to: updateDir)
        var toml = try String(contentsOf: updateDir.appendingPathComponent("extension.toml"), encoding: .utf8)
        let nextVersion = "1.2.1"
        toml = toml.replacingOccurrences(of: "version = \"\(baselineVersion)\"", with: "version = \"\(nextVersion)\"")
        if !toml.contains("version = \"\(nextVersion)\"") {
            toml = """
                id = "com.codeeditor.fixtures.s1-data"
                name = "S1 Data Updated"
                version = "\(nextVersion)"
                schema_version = 1
                api_version = "1.0"
                [activation]
                events = ["startup"]
                """
        }
        try toml.write(to: updateDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try await manager.update(id: s1.packageID, from: updateDir)
        #expect(await manager.package(id: s1.packageID)?.currentVersion == nextVersion)
        #expect(await manager.package(id: s1.packageID)?.previousVersion == baselineVersion)
        try await manager.rollback(id: s1.packageID)
        #expect(await manager.package(id: s1.packageID)?.currentVersion == baselineVersion)

        try await manager.uninstall(id: s0.packageID)
        #expect(await manager.package(id: s0.packageID) == nil)
        #expect(await manager.package(id: s1.packageID) != nil)
    }

    @Test func devReloadShadowsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devreload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        _ = try await manager.install(from: Fixtures.package("s0-basic"))

        // Create a "dev" copy of s0 with different version string by rewriting toml
        let devDir = root.appendingPathComponent("dev-s0", isDirectory: true)
        try FileManager.default.copyItem(at: Fixtures.package("s0-basic"), to: devDir)
        let toml = """
            id = "com.codeeditor.fixtures.s0-basic"
            name = "S0 Dev Shadow"
            version = "9.9.9"
            schema_version = 1
            api_version = "1.0"
            [activation]
            events = ["startup"]
            """
        try toml.write(to: devDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)

        let reloaded = try await manager.reloadDev(path: devDir)
        #expect(reloaded.displayName == "S0 Dev Shadow")
        #expect(reloaded.version == SemanticVersion(major: 9, minor: 9, patch: 9))
        let pkg = await manager.package(id: reloaded.packageID)
        #expect(pkg?.isDev == true)
    }

    @Test func recoverCorruptedState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let plan = try await manager.install(from: Fixtures.package("s0-basic"))
        // Wipe install path
        if let path = await manager.package(id: plan.packageID)?.installPath {
            try FileManager.default.removeItem(at: path)
        }
        await manager.recoverCorruptedState()
        #expect(await manager.package(id: plan.packageID) == nil)
    }

    @Test func snapshotEventsEmit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager.insecureForTests(installRoot: root, maxEventBuffer: 8)
        await manager.bootstrap()
        let stream = await manager.snapshots
        async let first: ExtensionContributionSnapshot? = {
            for await snap in stream {
                if !snap.packages.isEmpty { return snap }
            }
            return nil
        }()
        _ = try await manager.install(from: Fixtures.package("s0-basic"))
        let snap = await first
        #expect(snap?.packages.isEmpty == false)
    }
}

// MARK: - Author API isolation smoke

@Suite("Author API surface")
struct AuthorAPISmokeTests {
    @Test func semanticVersionParseAndRange() {
        let v = SemanticVersion.parse("1.2.3")
        #expect(v == SemanticVersion(major: 1, minor: 2, patch: 3))
        let range = VersionRange.from(.phase9API)
        #expect(range.contains(SemanticVersion(major: 1)))
        #expect(!range.contains(SemanticVersion(major: 0, minor: 9)))
    }

    @Test func extensionIDExpressible() {
        let id: ExtensionID = "com.example.x"
        #expect(id.rawValue == "com.example.x")
    }

    @Test func editorExtensionAlias() async throws {
        struct Mini: EditorExtension {
            let manifest = ExtensionManifest(id: "test.mini", displayName: "Mini")
            func activate(in context: any ExtensionAuthorContext) async throws {
                context.info("hi")
            }
        }
        let log = ExtensionLog()
        let ctx = ExtensionContext(extensionID: "test.mini", grantedPermissions: [], log: log)
        try await Mini().activate(in: ctx)
        #expect(log.events.contains { $0.message == "hi" })
    }
}
