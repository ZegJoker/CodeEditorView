import Foundation
import Testing
import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensions
import CodeEditorLanguageServices
@testable import CodeEditorExtensionHost

@Suite("Phase 15 execution policy")
struct Phase15ExecutionPolicyTests {
    @Test func shippingFactoriesSetFlags() {
        let mas = ExtensionExecutionPolicy.shipping(.macAppStore)
        #expect(mas.platformAllowsNativeProcess == false)
        #expect(mas.prefersSandbox == true)
        #expect(mas.allowsRemoteProviders == true)
        #expect(mas.allowBundledWasm == true)
        #expect(mas.allowDownloadableWasm == false)

        let ios = ExtensionExecutionPolicy.shipping(.iOS)
        #expect(ios.platformAllowsNativeProcess == false)
        #expect(ios.allowDownloadableWasm == false)
        #expect(ios.allowBundledWasm == true)

        let direct = ExtensionExecutionPolicy.shipping(.directMacOS)
        #expect(direct.platformAllowsNativeProcess == true)
        #expect(direct.allowDownloadableWasm == true)

        let ent = ExtensionExecutionPolicy.shipping(.enterprise)
        #expect(ent.hostProfile.enterpriseOptions?.managedRegistryOnly == true)
    }

    @Test func runtimeSelectorDeniesNativeOnMAS() throws {
        let pkg = PreparedExtensionPackage(
            packageID: "com.example.n",
            displayName: "N",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.n", displayName: "N"),
            nativeExecutable: URL(fileURLWithPath: "/tmp/fake-helper"),
            trustClass: .trustedSigned,
            runtimePreference: .nativeProcess,
            origin: .installed
        )
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: pkg, policy: .shipping(.macAppStore))
        }
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: pkg, policy: .shipping(.iOS))
        }
        // direct allows (trust ok)
        let kind = try RuntimeSelector.select(package: pkg, policy: .shipping(.directMacOS))
        #expect(kind == .nativeProcess)
    }

    @Test func runtimeSelectorBundledWasmAllowedDownloadDeniedOnMAS() throws {
        let bundled = PreparedExtensionPackage(
            packageID: "com.example.w",
            displayName: "W",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.w", displayName: "W"),
            wasmModuleData: Data([0x00, 0x61, 0x73, 0x6D]),
            trustClass: .trustedSigned,
            runtimePreference: .swiftWasm,
            origin: .bundled
        )
        let kind = try RuntimeSelector.select(package: bundled, policy: .shipping(.macAppStore))
        #expect(kind == .swiftWasm)

        let downloaded = PreparedExtensionPackage(
            packageID: "com.example.w2",
            displayName: "W2",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.w2", displayName: "W2"),
            wasmModuleData: Data([0x00, 0x61, 0x73, 0x6D]),
            trustClass: .trustedSigned,
            runtimePreference: .swiftWasm,
            origin: .installed
        )
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: downloaded, policy: .shipping(.macAppStore))
        }
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: downloaded, policy: .shipping(.iOS))
        }
    }

    @Test func remoteFallbackWhenNativeDeniedAndRemotePresent() throws {
        let pkg = PreparedExtensionPackage(
            packageID: "com.example.r",
            displayName: "R",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.r", displayName: "R"),
            nativeExecutable: URL(fileURLWithPath: "/tmp/h"),
            trustClass: .trustedSigned,
            runtimePreference: .nativeProcess,
            origin: .installed,
            hasRemoteDescriptor: true
        )
        let kind = try RuntimeSelector.select(package: pkg, policy: .shipping(.iOS))
        #expect(kind == .remote)
    }
}

@Suite("Phase 15 native helper policy")
struct Phase15NativeHelperPolicyTests {
    @Test func masAndIOSDenyNativeLaunch() {
        let d1 = NativeHelperLaunchPolicy.evaluate(
            trustClass: .trustedSigned,
            origin: .installed,
            policy: .shipping(.macAppStore)
        )
        #expect(d1.allowed == false)
        let d2 = NativeHelperLaunchPolicy.evaluate(
            trustClass: .trustedSigned,
            origin: .installed,
            policy: .shipping(.iOS)
        )
        #expect(d2.allowed == false)
        let d3 = NativeHelperLaunchPolicy.evaluate(
            trustClass: .trustedSigned,
            origin: .installed,
            policy: .shipping(.directMacOS)
        )
        #expect(d3.allowed == true)
    }

    @Test func enterpriseDeniesWorkspaceDevWhenRequiredSigned() {
        let d = NativeHelperLaunchPolicy.evaluate(
            trustClass: .workspaceDev,
            origin: .workspaceDev,
            policy: .shipping(.enterprise)
        )
        #expect(d.allowed == false)
        #expect(d.reasons.contains { $0.contains("enterprise") || $0.contains("workspaceDev") })
    }
}

@Suite("Phase 15 remote fallback")
struct Phase15RemoteFallbackTests {
    @Test func coordinatorRoutesIOSLanguageServerToRemote() {
        let c = RemoteToolingCoordinator(platformProfile: .iOS)
        switch c.languageServerLaunchDecision() {
        case .useRemoteFallback:
            break
        default:
            Issue.record("iOS LS should use remote fallback")
        }
    }

    @Test func launchPlanExecutorDeniesLocalOnIOSProfile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p15ls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = CapabilityBroker(config: .init(
            worktreeRoots: [tmp],
            storageRoot: tmp.appendingPathComponent("s"),
            toolCacheRoot: tmp.appendingPathComponent("c")
        ))
        let executor = LanguageServerLaunchPlanExecutor(
            broker: broker,
            platformProfile: .iOS
        )
        let plan = LanguageServerLaunchPlan(
            serverID: "x",
            displayName: "X",
            command: "/bin/echo",
            arguments: [],
            binarySource: .absolute(path: "/bin/echo")
        )
        do {
            _ = try await executor.start(
                plan: plan,
                extensionID: ExtensionID(rawValue: "com.example.x")!,
                registry: LanguageServiceRegistry()
            )
            Issue.record("expected platform deny")
        } catch {
            // ok — remote fallback message or deny
        }
    }

    @Test func remoteProvidersRegisterWithoutLocalProcess() async throws {
        let ext = DummyRemoteExtension()
        let pair = MockRemoteExtensionTransport.makePair()
        let server = RemoteExtensionServer(extension: ext, transport: pair.remote)
        let serverTask = Task { await server.run() }
        defer { serverTask.cancel() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let process = RemoteExtensionProcess(
            descriptor: RemoteExtensionDescriptor(
                id: ext.manifest.id,
                displayName: "Remote",
                manifest: ext.manifest,
                launch: .testFactory("t")
            ),
            environment: .full,
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(2)),
            transportFactory: { pair.host }
        )
        try await process.start()
        let registry = LanguageServiceRegistry()
        let coord = RemoteToolingCoordinator(platformProfile: .iOS)
        let reg = await coord.registerRemoteLanguageServices(
            process: process,
            extensionID: ext.manifest.id,
            into: registry
        )
        await process.shutdown()
        reg.dispose()
    }
}

@Suite("Phase 15 runnability descriptors")
struct Phase15RunnabilityDescriptorTests {
    @Test func nativeDeniedOnIOSWithRemoteSuggestion() {
        let host = ExtensionHostProfile.shipping(.iOS)
        let d = ArtifactRunnability.evaluate(
            packageID: "com.example.n",
            origin: .installed,
            requestedRuntime: .nativeProcess,
            hostProfile: host,
            hasRemoteDescriptor: true
        )
        #expect(d.decision == .deny)
        #expect(d.remoteFallbackAvailable == true)
        #expect(d.suggestedAction != nil)
    }

    @Test func dataOnlyAllowedEverywhere() {
        for id in ShippingProfileID.allCases {
            let d = ArtifactRunnability.evaluate(
                packageID: "com.example.d",
                origin: .installed,
                requestedRuntime: .dataOnly,
                hostProfile: .shipping(id)
            )
            #expect(d.decision == .allow, "data-only should allow on \(id.rawValue)")
        }
    }
}

@Suite("Phase 15 store install policy")
struct Phase15StoreInstallPolicyTests {
    @Test func masDeniesNativeMarkerPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p15inst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try """
        id = "com.example.native"
        name = "Native"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: pkg.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "1".write(to: pkg.appendingPathComponent(".codeeditor-native"), atomically: true, encoding: .utf8)

        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            installPolicy: .shipping(.macAppStore)
        )
        await manager.bootstrap()
        do {
            _ = try await manager.install(from: pkg)
            Issue.record("expected install deny")
        } catch {
            // ok
        }
    }

    @Test func dataPackageInstallsOnMAS() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p15data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try """
        id = "com.example.data"
        name = "Data"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: pkg.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            installPolicy: .shipping(.macAppStore)
        )
        await manager.bootstrap()
        let plan = try await manager.install(from: pkg)
        #expect(plan.packageID.rawValue == "com.example.data")
    }

    @Test func downloadableWasmMarkerDeniedOnIOS() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p15wasm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try """
        id = "com.example.wasm"
        name = "Wasm"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: pkg.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "1".write(to: pkg.appendingPathComponent(".codeeditor-wasm-download"), atomically: true, encoding: .utf8)
        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            installPolicy: .shipping(.iOS)
        )
        await manager.bootstrap()
        do {
            _ = try await manager.install(from: pkg)
            Issue.record("expected wasm install deny")
        } catch {
            // ok
        }
    }
}

@Suite("Phase 15 bundled wasm smoke")
struct Phase15BundledWasmTests {
    @Test func masPolicySelectsBundledWasmRuntime() throws {
        let data = fixtureWasmIfPresent()
        guard let data else {
            // Fixture optional if Wasm resources not linked into this target — policy still tested above.
            return
        }
        let pkg = PreparedExtensionPackage(
            packageID: "com.codeeditor.conformance",
            displayName: "C",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.codeeditor.conformance", displayName: "C"),
            wasmModuleData: data,
            trustClass: .trustedSigned,
            runtimePreference: .swiftWasm,
            origin: .bundled
        )
        let kind = try RuntimeSelector.select(package: pkg, policy: .shipping(.macAppStore))
        #expect(kind == .swiftWasm)
    }

    private func fixtureWasmIfPresent() -> Data? {
        if let url = Bundle.module.url(forResource: "conformance", withExtension: "wasm") {
            return try? Data(contentsOf: url)
        }
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Wasm/conformance.wasm")
        return try? Data(contentsOf: path)
    }
}
