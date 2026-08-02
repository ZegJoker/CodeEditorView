import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensions
import CodeEditorLanguageServices
import CodeEditorWasmEngine
import Foundation
import Testing

@testable import CodeEditorExtensionHost

@Suite("Phase 16 residual closure — Wasm stable host contract")
struct Phase16WasmResidualClosureTests {
    @Test func engineValidatesConformanceFixture() throws {
        let data = loadFixture("conformance")
        #expect(data != nil)
        guard let data else { return }
        let engine = InProcessCoreWasmEngine()
        try engine.validate(module: data, limits: .default)
    }

    @Test func engineRejectsMalformedFixture() throws {
        let data = loadFixture("malformed")
        #expect(data != nil)
        guard let data else { return }
        let engine = InProcessCoreWasmEngine()
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: data, limits: WasmResourceLimits.default)
        }
    }

    @Test func shippingProfilesAllowBundledWasmRuntime() throws {
        let data = loadFixture("conformance") ?? Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
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
        #expect(ExtensionExecutionPolicy.shipping(.directMacOS).allowBundledWasm)
    }

    private func loadFixture(_ name: String) -> Data? {
        if let url = Bundle.module.url(forResource: name, withExtension: "wasm") {
            return try? Data(contentsOf: url)
        }
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Wasm/\(name).wasm")
        return try? Data(contentsOf: path)
    }
}

@Suite("Phase 16 residual closure — remote provider stable")
struct Phase16RemoteResidualClosureTests {
    @Test func remoteHostStartStopAndStatus() async throws {
        let ext = DummyRemoteExtension()
        let pair = MockRemoteExtensionTransport.makePair()
        let server = RemoteExtensionServer(extension: ext, transport: pair.remote)
        let serverTask = Task { await server.run() }
        defer { serverTask.cancel() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let descriptor = RemoteExtensionDescriptor(
            id: ext.manifest.id,
            displayName: "Remote Stable",
            manifest: ext.manifest,
            launch: .testFactory("stable-remote")
        )
        let host = RemoteExtensionHost(
            environment: .full,
            services: ExtensionHostServices(),
            discovery: StaticRemoteExtensionDiscovery(descriptors: [descriptor]),
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(3))
        )
        await host.registerTestFactory(id: "stable-remote") { pair.host }
        try await host.refreshDiscovery()
        try await host.start(id: ext.manifest.id)
        let statuses = await host.statuses()
        #expect(statuses.contains { $0.id == ext.manifest.id })
        await host.stop(id: ext.manifest.id)
        await server.stop()
    }

    @Test func profileMarksRemoteRuntimeAllowed() {
        let host = ExtensionHostProfile.shipping(.iOS)
        #expect(host.allowedRuntimes.contains(.remote))
        #expect(host.remoteFallbackAvailable)
        let direct = ExtensionHostProfile.shipping(.directMacOS)
        #expect(direct.allowedRuntimes.contains(.remote))
    }
}

@Suite("Phase 16 residual closure — slash stable")
struct Phase16SlashResidualClosureTests {
    @Test func slashDefaultsStableAndSanitizes() async throws {
        struct Prov: SlashCommandProvider {
            var commandIDs: [String] { ["explain"] }
            func execute(
                commandID: String,
                arguments: String,
                context: SlashCommandExecuteContext
            ) -> AsyncThrowingStream<SlashCommandChunk, Error> {
                AsyncThrowingStream { cont in
                    cont.yield(SlashCommandChunk(markdown: "[x](javascript:1)", isFinal: true))
                    cont.finish()
                }
            }
        }
        let contrib = SlashCommandContribution(id: "explain", name: "explain")
        #expect(contrib.compatibility == .stable)
        #expect(CompatibilityProfile.phase16Default.status(for: .slashCommands) == .stable)

        let svc = SlashCommandService()
        let ext: ExtensionID = "ext.slash.stable"
        await svc.registerContribution(contrib)
        await svc.registerProvider(Prov(), extensionID: ext)
        #expect(await svc.compatibilityStatus(for: "explain") == .stable)
        var last = ""
        for try await c in await svc.execute(commandID: "explain", arguments: "a", extensionID: ext) {
            last = c.markdown
        }
        #expect(!last.lowercased().contains("javascript:"))
    }
}
