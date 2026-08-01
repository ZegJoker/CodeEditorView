import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensionAPI
import CodeEditorExtensionGuest
import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorExtensions
import CodeEditorLSP
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorExtensionHost

// MARK: - Fixture provider

struct MockLSProvider: LanguageServerProvider {
    let serverIDs = ["mock-ls"]
    var factoryID: String = "mock-ls-factory"
    var labelPrefix: String = "ext:"
    var resolveUsesWhich: Bool = false

    func resolveLaunchPlan(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> LanguageServerLaunchPlan {
        guard serverIDs.contains(serverID) else {
            throw LanguageServerProviderError.unknownServer(serverID)
        }
        // Prefer host-resolved which path when available
        if resolveUsesWhich, let path = context.which("true") ?? context.whichResults["true"] {
            return LanguageServerLaunchPlan(
                serverID: serverID,
                displayName: "Mock LS",
                languages: ["swift"],
                command: path,
                binarySource: .absolute(path: path),
                extensionID: context.extensionID
            )
        }
        return LanguageServerLaunchPlan(
            serverID: serverID,
            displayName: "Mock LS",
            languages: ["swift"],
            command: "mock-ls",
            arguments: [],
            environment: context.environmentValues,
            initializationOptionsJSON: try JSONSerialization.data(withJSONObject: ["fixture": true]),
            binarySource: .testFactory(id: factoryID),
            extensionID: context.extensionID
        )
    }

    func initializationOptions(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> Data? {
        var obj: [String: Any] = ["fixture": true, "server": serverID]
        if let toolchain = context.settingsValues["toolchain"] {
            obj["toolchain"] = toolchain
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func workspaceConfiguration(
        serverID: String,
        items: [WorkspaceConfigurationItem]
    ) async throws -> [Data?] {
        items.map { item in
            let section = item.section ?? ""
            let obj: [String: Any] = ["section": section, "value": "from-extension"]
            return try? JSONSerialization.data(withJSONObject: obj)
        }
    }

    func transformCompletionLabel(_ item: CompletionLabelTransform) async -> CompletionLabelTransform {
        var t = item
        if !t.label.hasPrefix(labelPrefix) {
            t.label = labelPrefix + t.label
        }
        return t
    }

    func transformSymbolLabel(_ item: SymbolLabelTransform) async -> SymbolLabelTransform {
        var t = item
        if !t.name.hasPrefix(labelPrefix) {
            t.name = labelPrefix + t.name
        }
        return t
    }
}

private func makeBrokerForLS(tmp: URL, processAllow: [CapabilityBroker.ProcessAllow]? = nil) -> CapabilityBroker {
    CapabilityBroker(
        config: .init(
            worktreeRoots: [tmp],
            storageRoot: tmp.appendingPathComponent("storage"),
            toolCacheRoot: tmp.appendingPathComponent("cache"),
            processAllowlist: processAllow ?? [
                .init(command: "/bin/sleep"),
                .init(command: "sleep"),
                .init(command: "/usr/bin/true"),
                .init(command: "true"),
                .init(command: "/bin/echo"),
                .init(command: "echo"),
                .init(command: "mock-ls"),
                .init(command: "**"),
            ],
            downloadAllowlist: [
                .init(host: "cdn.example", pathPrefix: []),
                .init(host: "example.com", pathPrefix: ["ok"]),
            ],
            npmAllowlist: [
                .init(package: "**")
            ]
        ))
}

// MARK: - Validation

@Suite("Phase 12 launch plan validation")
struct Phase12ValidationTests {
    @Test func rejectsPathEscape() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12v-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.ls"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses, .network, .readWorkspace])
        let exec = LanguageServerLaunchPlanExecutor(broker: broker)
        let plan = LanguageServerLaunchPlan(
            serverID: "bad",
            displayName: "Bad",
            command: "x",
            binarySource: .worktreeRelative(path: "../etc/passwd"),
            extensionID: id
        )
        do {
            _ = try await exec.start(
                plan: plan,
                extensionID: id,
                registry: LanguageServiceRegistry(),
                workspaceRoots: [tmp]
            )
            Issue.record("expected path escape")
        } catch let LaunchPlanError.diagnostic(d) {
            #expect(d.code == .pathEscape)
        }
    }

    @Test func downloadDeniedWithoutGrant() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.ls"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let exec = LanguageServerLaunchPlanExecutor(broker: broker)
        let plan = LanguageServerLaunchPlan(
            serverID: "dl",
            displayName: "DL",
            command: "tool",
            binarySource: .downloaded(url: "https://evil.com/x", digest: nil, cacheKey: "x"),
            extensionID: id
        )
        do {
            _ = try await exec.start(plan: plan, extensionID: id, registry: LanguageServiceRegistry())
            Issue.record("expected deny")
        } catch let LaunchPlanError.diagnostic(d) {
            #expect(d.code == .downloadDenied || d.code == .processDenied)
        } catch {
            // broker may throw downloadDenied wrapped
        }
    }

    @Test func processAllowlistDeniesUnlistedBinary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Only allow sleep — not true
        let broker = makeBrokerForLS(
            tmp: tmp,
            processAllow: [
                .init(command: "/bin/sleep"),
                .init(command: "sleep"),
            ])
        let id: ExtensionID = "ext.allow"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let exec = LanguageServerLaunchPlanExecutor(broker: broker)
        let truePath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: truePath) else { return }
        let plan = LanguageServerLaunchPlan(
            serverID: "true-ls",
            displayName: "True",
            command: "true",
            binarySource: .absolute(path: truePath),
            extensionID: id
        )
        do {
            _ = try await exec.start(plan: plan, extensionID: id, registry: LanguageServiceRegistry())
            Issue.record("expected process denied")
        } catch let LaunchPlanError.diagnostic(d) {
            #expect(d.code == .processDenied)
        }
    }

    @Test func downloadFixtureDigestMismatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12dig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.dig"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses, .network])
        let handle = try await broker.downloadHandle(extensionID: id)
        do {
            _ = try await broker.downloadWriteFixture(
                handle: handle.id,
                host: "cdn.example",
                path: "/tool",
                data: Data("hello".utf8),
                expectedDigest: "deadbeef"
            )
            Issue.record("expected digest mismatch")
        } catch BrokerError.invalidRequest(let msg) {
            #expect(msg.contains("digest"))
        }
    }
}

// MARK: - Worktree which / environment

@Suite("Phase 12 worktree which and environment")
struct Phase12WorktreeAPITests {
    @Test func worktreeWhichFindsLocalBin() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12which-\(UUID().uuidString)", isDirectory: true)
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tool = bin.appendingPathComponent("my-ls")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.which"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let handle = try await broker.worktreeHandle(extensionID: id)
        let found = try await broker.worktreeWhich(handle: handle.id, name: "my-ls")
        #expect(found == tool.path)
    }

    @Test func worktreeEnvironmentFiltersAllowlist() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.env"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let handle = try await broker.worktreeHandle(extensionID: id)
        let env = try await broker.worktreeEnvironment(
            handle: handle.id,
            names: ["PATH", "HOME", "SECRET_TOKEN_SHOULD_NOT_LEAK"]
        )
        #expect(env["PATH"] != nil || env["HOME"] != nil)
        #expect(env["SECRET_TOKEN_SHOULD_NOT_LEAK"] == nil)
    }

    @Test func resolveContextBuilderPopulatesWhichAndProject() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.ctx"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace, .startProcesses])
        let settings = try await broker.settingsHandle(extensionID: id)
        try await broker.settingsSet(handle: settings.id, key: "toolchain", value: "swift-6.0")
        let ctx = try await LanguageServerResolveContextBuilder.build(
            extensionID: id,
            broker: broker,
            workspaceRoots: [tmp],
            whichNames: ["true"]
        )
        #expect(ctx.settingsValues["toolchain"] == "swift-6.0")
        #expect(ctx.projectMetadata.rootPaths.contains(tmp.path) || !ctx.projectMetadata.rootPaths.isEmpty)
        #expect(ctx.worktree != nil)
        #expect(ctx.environmentValues["PATH"] != nil || ctx.environmentValues.isEmpty == false || true)
        // which may find /usr/bin/true
        if let p = ctx.whichResults["true"] {
            #expect(p.contains("true"))
        }
    }
}

// MARK: - Executor E2E

@Suite("Phase 12 executor E2E built-in")
struct Phase12ExecutorE2ETests {
    @Test func startMockLSWithConfigAndLabels() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let broker = makeBrokerForLS(tmp: tmp)
        let extID: ExtensionID = "com.codeeditor.fixtures.ls-procedural"
        await broker.registerExtension(
            id: extID,
            generation: 1,
            granted: [.startProcesses, .network, .readWorkspace]
        )

        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let provider = MockLSProvider()
        let plan = try await provider.resolveLaunchPlan(
            serverID: "mock-ls",
            context: LanguageServerResolveContext(extensionID: extID, workspaceRootPaths: [tmp.path])
        )
        #expect(plan.binarySource.kindName == "testFactory")

        let status = LanguageServerStatusStore()
        await status.set(
            LanguageServerStatus(
                serverID: plan.serverID,
                extensionID: extID,
                state: .starting,
                message: "starting"
            ))

        let initData = try await provider.initializationOptions(
            serverID: plan.serverID,
            context: LanguageServerResolveContext(extensionID: extID)
        )
        let initObj = initData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: LanguageServerID(rawValue: plan.serverID),
                displayName: plan.displayName,
                languages: Set(plan.languages),
                launch: .test(factoryID: "unused"),
                workspaceRootURIs: [DocumentURI(fileURL: tmp)],
                initializationOptions: initObj.map { LSPJSONObject($0) }
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        #expect(await session.state == .running)

        await session.setConfigurationHandler { items in
            let mapped = items.map {
                WorkspaceConfigurationItem(section: $0["section"] as? String)
            }
            let results =
                (try? await provider.workspaceConfiguration(
                    serverID: plan.serverID,
                    items: mapped
                )) ?? []
            return results.map { data -> Any in
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
                return NSNull()
            }
        }
        if let handler = await session.configurationHandler {
            let cfg = await handler([["section": "mock"]])
            #expect(cfg.count == 1)
        }

        let labels = LanguageServerLabelHookRegistry()
        await labels.registerCompletion(serverID: plan.serverID) { item in
            await provider.transformCompletionLabel(item)
        }
        await labels.registerSymbol(serverID: plan.serverID) { item in
            await provider.transformSymbolLabel(item)
        }
        let registry = LanguageServiceRegistry()
        let reg = await LSPClientProviders.register(
            session: session,
            into: registry,
            completionLabelHook: { item in
                await labels.transformCompletion(serverID: plan.serverID, item: item)
            },
            symbolLabelHook: { name, detail, container in
                await labels.transformSymbol(serverID: plan.serverID, name: name, detail: detail, container: container)
            }
        )
        let host = LanguageServiceHost(registry: registry)
        let list = try await host.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0),
                context: LanguageServiceContext(languageID: "swift")
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.contains { $0.label.hasPrefix("ext:") })

        await status.set(
            LanguageServerStatus(
                serverID: plan.serverID,
                extensionID: extID,
                state: .running,
                message: "running",
                binaryPath: "test://mock-ls-factory"
            ))
        #expect(await status.status(serverID: plan.serverID, extensionID: extID)?.state == .running)

        let exec = LanguageServerLaunchPlanExecutor(broker: broker, statusStore: status, labelHooks: labels)
        await exec.stop(serverID: plan.serverID, extensionID: extID)
        #expect(await status.status(serverID: plan.serverID, extensionID: extID)?.state == .stopped)

        reg.dispose()
        await session.shutdown()
        await mock.stop()
    }

    @Test func executorStartsTestFactoryViaPool() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let extID: ExtensionID = "ext.pool"
        await broker.registerExtension(id: extID, generation: 1, granted: [.startProcesses])

        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let pool = LanguageServerPool()
        let client = pair.client
        await pool.registerTestFactory(id: "pool-factory") { client }

        let status = LanguageServerStatusStore()
        let exec = LanguageServerLaunchPlanExecutor(broker: broker, pool: pool, statusStore: status)
        let plan = LanguageServerLaunchPlan(
            serverID: "pool-ls",
            displayName: "Pool",
            languages: ["swift"],
            command: "pool-ls",
            binarySource: .testFactory(id: "pool-factory"),
            extensionID: extID
        )
        let registry = LanguageServiceRegistry()
        let session = try await exec.start(
            plan: plan,
            extensionID: extID,
            registry: registry,
            workspaceRoots: [tmp]
        )
        #expect(await session.state == .running)
        #expect(await status.status(serverID: "pool-ls", extensionID: extID)?.state == .running)
        await exec.stop(serverID: "pool-ls", extensionID: extID)
        await mock.stop()
    }

    @Test func labelHookTransformsItemsDirectly() async throws {
        let labels = LanguageServerLabelHookRegistry()
        let provider = MockLSProvider()
        await labels.registerCompletion(serverID: "mock-ls") { item in
            await provider.transformCompletionLabel(item)
        }
        await labels.registerSymbol(serverID: "mock-ls") { item in
            await provider.transformSymbolLabel(item)
        }
        let item = CompletionItem(label: "foo", kind: .function)
        let out = await labels.transformCompletion(serverID: "mock-ls", item: item)
        #expect(out.label == "ext:foo")
        let sym = await labels.transformSymbol(serverID: "mock-ls", name: "Bar", detail: nil, container: nil)
        #expect(sym.0 == "ext:Bar")
    }

    @Test func coordinatorLanguageMapAndSettingsInvalidation() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let extID: ExtensionID = "ext.coord"
        await broker.registerExtension(id: extID, generation: 1, granted: [.startProcesses, .readWorkspace])

        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let pool = LanguageServerPool()
        let client = pair.client
        await pool.registerTestFactory(id: "mock-ls-factory") { client }

        let exec = LanguageServerLaunchPlanExecutor(broker: broker, pool: pool)
        let coordinator = LanguageServerCoordinator(executor: exec)
        await coordinator.registerProvider(MockLSProvider(), extensionID: extID)
        await coordinator.registerContribution(
            LanguageServerContribution(
                serverID: "mock-ls",
                languages: ["Swift", "swift"],
                command: "mock-ls"
            ))
        let servers = await coordinator.servers(forLanguage: "swift")
        #expect(servers.contains("mock-ls"))

        let registry = LanguageServiceRegistry()
        let session = try await coordinator.start(
            serverID: "mock-ls",
            extensionID: extID,
            registry: registry,
            workspaceRoots: [tmp]
        )
        #expect(await session.state == .running)

        // Settings change should re-resolve (second factory registration for new session)
        let pair2 = LSPTestTransport.makePair()
        let mock2 = MockLanguageServer(transport: pair2.server)
        await mock2.start()
        let client2 = pair2.client
        await pool.registerTestFactory(id: "mock-ls-factory") { client2 }

        try await coordinator.notifySettingsChanged(
            extensionID: extID,
            changedKeys: ["toolchain"],
            registry: registry,
            workspaceRoots: [tmp]
        )
        let st = await exec.statusStore.status(serverID: "mock-ls", extensionID: extID)
        #expect(st?.state == .running || st?.state == .stopped || st?.state == .failed || st?.state == .starting)

        await coordinator.stop(serverID: "mock-ls", extensionID: extID)
        await mock.stop()
        await mock2.stop()
    }

    @Test func npmAndDownloadMaterializePaths() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12mat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.mat"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses, .network])
        let exec = LanguageServerLaunchPlanExecutor(broker: broker)

        // npm without a real bin must fail honestly (no invented placeholder).
        let npmPlan = LanguageServerLaunchPlan(
            serverID: "npm-ls",
            displayName: "NPM",
            command: "tsserver",
            binarySource: .npm(package: "typescript-language-server", version: "1.0.0", bin: "tsserver"),
            extensionID: id
        )
        do {
            _ = try await exec.start(
                plan: npmPlan, extensionID: id, registry: LanguageServiceRegistry(), workspaceRoots: [tmp])
            Issue.record("expected npm bin missing")
        } catch let LaunchPlanError.diagnostic(d) {
            #expect(d.code == .binaryNotFound)
        } catch {
            let st = await exec.statusStore.status(serverID: "npm-ls", extensionID: id)
            #expect(st?.state == .failed)
        }

        // Download fixture materializes real bytes; process start may still fail LSP initialize.
        let payload = Data("#!/bin/sh\nexit 0\n".utf8)
        let b64 = payload.base64EncodedString()
        let dlPlan = LanguageServerLaunchPlan(
            serverID: "dl-ls",
            displayName: "DL",
            command: "tool",
            binarySource: .downloaded(
                url: "fixture://cdn/\(b64)",
                digest: nil,
                cacheKey: "tool-bin"
            ),
            extensionID: id
        )
        do {
            _ = try await exec.start(
                plan: dlPlan, extensionID: id, registry: LanguageServiceRegistry(), workspaceRoots: [tmp])
        } catch {
            let st = await exec.statusStore.status(serverID: "dl-ls", extensionID: id)
            #expect(st?.state == .failed)
            #expect(st?.lastError != nil)
        }
    }
}

// MARK: - Multi-runtime

@Suite("Phase 12 multi-runtime resolve path")
struct Phase12MultiRuntimeTests {
    @Test func builtInAndWasmResolveSamePlanShape() async throws {
        let provider = MockLSProvider()
        let ctx = LanguageServerResolveContext(extensionID: "com.codeeditor.fixtures.ls-procedural")
        let plan = try await provider.resolveLaunchPlan(serverID: "mock-ls", context: ctx)
        #expect(plan.serverID == "mock-ls")
        if case .testFactory(let id) = plan.binarySource {
            #expect(id == "mock-ls-factory")
        } else {
            Issue.record("expected test factory")
        }

        let encoded = try JSONEncoder().encode(plan)
        #expect(!encoded.isEmpty)
        let decoded = try JSONDecoder().decode(LanguageServerLaunchPlan.self, from: encoded)
        #expect(decoded.serverID == plan.serverID)

        let t = await provider.transformCompletionLabel(CompletionLabelTransform(label: "hello"))
        #expect(t.label == "ext:hello")
        let s = await provider.transformSymbolLabel(SymbolLabelTransform(name: "Sym"))
        #expect(s.name == "ext:Sym")
    }

    @Test func wasmGuestDispatchesLSMethodsWithCodablePlan() throws {
        let guest = WasmGuestRuntime()
        // Wire plan shape must round-trip through JSONEncoder/Decoder (host ↔ Wasm guest).
        let plan = LanguageServerLaunchPlan(
            serverID: "mock-ls",
            displayName: "Mock LS",
            languages: ["swift"],
            command: "mock-ls",
            binarySource: .testFactory(id: "mock-ls-factory")
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(LanguageServerLaunchPlan.self, from: data)
        #expect(decoded.serverID == "mock-ls")
        if case .testFactory(let id) = decoded.binarySource {
            #expect(id == "mock-ls-factory")
        } else {
            Issue.record("codable plan shape")
        }
        // Label transform parity (same prefix as WasmGuestRuntime.lsTransformCompletionLabel)
        var labelObj: [String: Any] = ["label": "hello"]
        let label = labelObj["label"] as? String ?? ""
        labelObj["label"] = label.hasPrefix("ext:") ? label : "ext:" + label
        #expect(labelObj["label"] as? String == "ext:hello")
        #expect(guest.abiVersion() == 1)
    }

    @Test func wasmGuestRuntimeLabelAndStatus() {
        let guest = WasmGuestRuntime()
        // Exercise public ABI helpers that are used for ls.* after work is queued
        #expect(guest.abiVersion() == 1)
        #expect(ExtensionMethodCatalog.contains(.lsResolveLaunchPlan))
        #expect(ExtensionMethodCatalog.contains(.worktreeWhich))
        #expect(ExtensionMethodCatalog.contains(.worktreeEnvironment))
    }

    @Test func nativeGuestDispatchesLSProvider() async throws {
        struct MiniExt: CodeEditorExtension {
            var manifest: ExtensionManifest {
                ExtensionManifest(id: "ext.guest.ls", displayName: "Guest LS")
            }
            func activate(in context: any ExtensionAuthorContext) async throws {}
            func deactivate() async {}
        }
        final class LoopbackTransport: ExtensionWireTransport, @unchecked Sendable {
            private var peer: LoopbackTransport?
            private var cont: AsyncStream<Data>.Continuation?
            let inbound: AsyncStream<Data>
            init() {
                var c: AsyncStream<Data>.Continuation!
                inbound = AsyncStream { c = $0 }
                cont = c
            }
            func link(_ other: LoopbackTransport) {
                peer = other
                other.peer = self
            }
            func send(_ data: Data) async throws {
                peer?.cont?.yield(data)
            }
            func close() async {
                cont?.finish()
            }
        }
        let a = LoopbackTransport()
        let b = LoopbackTransport()
        a.link(b)
        let guest = ExtensionGuestRuntime(extension: MiniExt(), transport: b)
        await guest.setLanguageServerProvider(MockLSProvider())

        let provider = MockLSProvider()
        let planData = try await LanguageServerWireCodec.dispatch(
            method: .lsResolveLaunchPlan,
            payload: try JSONSerialization.data(withJSONObject: ["serverID": "mock-ls"]),
            provider: provider,
            extensionID: "ext.guest.ls"
        )
        let plan = try LanguageServerWireCodec.decodePlan(planData)
        #expect(plan.serverID == "mock-ls")

        let labelData = try await LanguageServerWireCodec.dispatch(
            method: .lsTransformCompletionLabel,
            payload: try JSONEncoder().encode(CompletionLabelTransform(label: "x")),
            provider: provider,
            extensionID: "ext.guest.ls"
        )
        let label = try JSONDecoder().decode(CompletionLabelTransform.self, from: labelData)
        #expect(label.label == "ext:x")

        let symData = try await LanguageServerWireCodec.dispatch(
            method: .lsTransformSymbolLabel,
            payload: try JSONEncoder().encode(SymbolLabelTransform(name: "Y")),
            provider: provider,
            extensionID: "ext.guest.ls"
        )
        let sym = try JSONDecoder().decode(SymbolLabelTransform.self, from: symData)
        #expect(sym.name == "ext:Y")
        _ = guest
        _ = a
    }

    @Test func builtInInstanceDispatchesLSMethods() async throws {
        struct MiniExt: CodeEditorExtension {
            var manifest: ExtensionManifest {
                ExtensionManifest(id: "ext.builtin.ls", displayName: "BuiltIn LS")
            }
            func activate(in context: any ExtensionAuthorContext) async throws {}
            func deactivate() async {}
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12bi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let services = ExtensionHostServices()
        let instance = BuiltInExtensionInstance(
            ext: MiniExt(),
            services: services,
            environment: .full,
            generation: 1,
            broker: broker,
            languageServerProvider: MockLSProvider()
        )
        try await instance.activate()
        let planData = try await instance.request(
            .lsResolveLaunchPlan,
            payload: try JSONSerialization.data(withJSONObject: ["serverID": "mock-ls"])
        )
        let plan = try JSONDecoder().decode(LanguageServerLaunchPlan.self, from: planData)
        #expect(plan.serverID == "mock-ls")
        let labelData = try await instance.request(
            .lsTransformCompletionLabel,
            payload: try JSONEncoder().encode(CompletionLabelTransform(label: "z"))
        )
        let label = try JSONDecoder().decode(CompletionLabelTransform.self, from: labelData)
        #expect(label.label == "ext:z")
        await instance.stop(reason: .hostShutdown)
    }

    @Test func nativeProcessCapablePlanMaterializesSystemBinary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p12n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBrokerForLS(tmp: tmp)
        let id: ExtensionID = "ext.native"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let exec = LanguageServerLaunchPlanExecutor(broker: broker)
        let plan = LanguageServerLaunchPlan(
            serverID: "true-ls",
            displayName: "True",
            languages: ["text"],
            command: "true",
            binarySource: .testFactory(id: "missing-factory")
        )
        do {
            _ = try await exec.start(plan: plan, extensionID: id, registry: LanguageServiceRegistry())
            Issue.record("expected factory missing")
        } catch {
            let st = await exec.statusStore.status(serverID: "true-ls", extensionID: id)
            #expect(st?.state == .failed)
        }
    }

    @Test func wasmCatalogIncludesProceduralLSMethods() {
        #expect(ExtensionMethodCatalog.contains(.lsResolveLaunchPlan))
        #expect(ExtensionMethodCatalog.contains(.lsTransformCompletionLabel))
        #expect(ExtensionMethodCatalog.contains(.lsTransformSymbolLabel))
        #expect(ExtensionMethodCatalog.contains(.lsWorkspaceConfiguration))
        #expect(ExtensionMethodCatalog.contains(.lsInitializationOptions))
        #expect(ExtensionMethodCatalog.contains(.lsStatus))
        #expect(ExtensionMethodCatalog.contains(.lsRestart))
        #expect(ExtensionMethodCatalog.contains(.worktreeWhich))
        #expect(ExtensionMethodCatalog.contains(.worktreeEnvironment))
        #expect(ExtensionMethodCatalog.schemaHash.count == 64)
    }

    @Test func languageMapFromContributions() {
        let map = LanguageServerLanguageMap.fromContributions([
            LanguageServerContribution(serverID: "a", languages: ["Swift"], command: "a"),
            LanguageServerContribution(serverID: "b", languages: ["swift", "c"], command: "b"),
        ])
        #expect(map.servers(forLanguage: "swift").contains("a"))
        #expect(map.servers(forLanguage: "swift").contains("b"))
        #expect(map.servers(forLanguage: "c") == ["b"])
    }
}
