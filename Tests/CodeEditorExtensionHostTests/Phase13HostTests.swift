import CodeEditorCore
import CodeEditorDAP
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import CodeEditorTasks
import Foundation
import Testing

@testable import CodeEditorExtensionHost

private func makeBroker(tmp: URL) -> CapabilityBroker {
    CapabilityBroker(
        config: .init(
            worktreeRoots: [tmp],
            storageRoot: tmp.appendingPathComponent("storage"),
            toolCacheRoot: tmp.appendingPathComponent("cache"),
            processAllowlist: [.init(command: "**")],
            downloadAllowlist: [.init(host: "cdn.example", pathPrefix: [])],
            npmAllowlist: [.init(package: "**")]
        ))
}

@Suite("Phase 13 DAP host")
struct Phase13DAPHostTests {
    @Test func rejectsPathEscape() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13dap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBroker(tmp: tmp)
        let id: ExtensionID = "ext.dap"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let exec = DebugAdapterLaunchPlanExecutor(broker: broker)
        let plan = DebugAdapterLaunchPlan(
            adapterID: "bad",
            displayName: "Bad",
            command: "x",
            binarySource: .worktreeRelative(path: "../etc/passwd")
        )
        do {
            _ = try await exec.start(plan: plan, extensionID: id, workspaceRoots: [tmp])
            Issue.record("expected escape")
        } catch let DebugLaunchPlanError.diagnostic(d) {
            #expect(d.code == .pathEscape)
        }
    }

    @Test func startsMockAdapterViaPool() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBroker(tmp: tmp)
        let id: ExtensionID = "ext.dap2"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])

        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.start()
        let pool = DebugAdapterPool()
        let client = pair.client
        await pool.registerTestFactory(id: "dap-f") { client }

        let exec = DebugAdapterLaunchPlanExecutor(broker: broker, pool: pool)
        let plan = DebugAdapterLaunchPlan(
            adapterID: "mock-dap",
            displayName: "Mock",
            languages: ["swift"],
            command: "mock-dap",
            binarySource: .testFactory(id: "dap-f")
        )
        let session = try await exec.start(plan: plan, extensionID: id, workspaceRoots: [tmp])
        #expect(await session.state == .initialized)
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        await exec.stop(adapterID: "mock-dap", extensionID: id)
        await mock.stop()
    }

    @Test func locatorReturnsConfigs() async throws {
        struct Loc: DebugLocatorProvider {
            func locate(context: DebugLocatorContext) async throws -> [DebugLocatorMatch] {
                [
                    DebugLocatorMatch(
                        adapterID: "mock-dap",
                        configuration: DebugConfiguration(name: "Run", type: "mock", request: .launch),
                        confidence: 0.9
                    )
                ]
            }
        }
        let matches = try await Loc().locate(
            context: DebugLocatorContext(
                extensionID: "test.ext",
                languageID: "swift",
                workspaceRootPaths: ["/tmp"]
            ))
        #expect(matches.count == 1)
        #expect(matches[0].adapterID == "mock-dap")
    }
}

@Suite("Phase 13 MCP host")
struct Phase13MCPTests {
    @Test func mockMCPInitializeAndTools() async throws {
        let pair = MCPTestTransport.makePair()
        let mock = MockMCPServer(transport: pair.server)
        await mock.start()
        let plan = MCPServerLaunchPlan(
            serverID: "mock-mcp",
            displayName: "Mock",
            command: "mock-mcp",
            binarySource: .testFactory(id: "mcp-f")
        )
        let pool = MCPServerPool()
        let client = pair.client
        await pool.registerTestFactory(id: "mcp-f") { client }
        let session = try await pool.start(plan: plan)
        #expect(await session.state == .running)
        let tools = await session.tools
        #expect(tools.contains { ($0["name"] as? String) == "echo" })
        let call = try await session.callTool(name: "echo")
        #expect(!call.dictionary.isEmpty)
        _ = try await session.listResources()
        _ = try await session.listPrompts()
        await session.stop()
        await mock.stop()
    }
}

@Suite("Phase 13 slash commands")
struct Phase13SlashCommandTests {
    @Test func streamSanitizeAndCancel() async throws {
        struct Prov: SlashCommandProvider {
            var commandIDs: [String] { ["explain"] }
            func execute(
                commandID: String,
                arguments: String,
                context: SlashCommandExecuteContext
            ) -> AsyncThrowingStream<SlashCommandChunk, Error> {
                AsyncThrowingStream { cont in
                    cont.yield(SlashCommandChunk(markdown: "Hello [x](javascript:alert(1))", isFinal: true))
                    cont.finish()
                }
            }
        }
        let svc = SlashCommandService()
        let ext: ExtensionID = "ext.slash"
        await svc.registerContribution(
            SlashCommandContribution(
                id: "explain",
                name: "explain",
                description: "d"
            ))
        await svc.registerProvider(Prov(), extensionID: ext)
        #expect(await svc.compatibilityStatus(for: "explain") == .stable)
        var chunks: [SlashCommandChunk] = []
        for try await c in await svc.execute(commandID: "explain", arguments: "hi", extensionID: ext) {
            chunks.append(c)
        }
        #expect(chunks.count == 1)
        #expect(!chunks[0].markdown.lowercased().contains("javascript:"))
    }

    @Test func rejectsOversizedArgs() async throws {
        struct Prov: SlashCommandProvider {
            var commandIDs: [String] { ["x"] }
            func execute(
                commandID: String,
                arguments: String,
                context: SlashCommandExecuteContext
            ) -> AsyncThrowingStream<SlashCommandChunk, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let svc = SlashCommandService()
        let ext: ExtensionID = "test.ext"
        await svc.registerContribution(SlashCommandContribution(id: "x", name: "x", maxArgumentLength: 5))
        await svc.registerProvider(Prov(), extensionID: ext)
        do {
            for try await _ in await svc.execute(
                commandID: "x",
                arguments: "toolong",
                extensionID: ext
            ) {}
            Issue.record("expected overflow")
        } catch SlashCommandError.argumentsTooLong {
            // ok
        }
    }
}

@Suite("Phase 13 documentation")
struct Phase13DocumentationTests {
    @Test func indexBuildQuotaAndInvalidate() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let docsRoot = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsRoot, withIntermediateDirectories: true)
        let file = docsRoot.appendingPathComponent("swift.md")
        try "# Swift\nHello docs body".write(to: file, atomically: true, encoding: .utf8)

        let svc = DocumentationIndexService(
            config: .init(
                storageRoot: tmp.appendingPathComponent("idx"),
                maxBytes: 1024,
                maxEntries: 100
            ))
        let entries = try await svc.buildIndex(
            package: DocumentationPackageSuggestion(
                id: "swift-std",
                title: "Swift",
                languages: ["Swift"],
                sourcePath: "docs/swift.md"
            ),
            extensionID: "test.ext",
            context: LanguageServerResolveContext(extensionID: "test.ext"),
            worktreeRoot: tmp
        )
        #expect(entries.count >= 1)
        #expect(await svc.bytesInUse() > 0)
        await svc.invalidate(packageID: "swift-std")
        #expect(await svc.allEntries().isEmpty)

        // Missing path fails honestly
        do {
            _ = try await svc.buildIndex(
                package: DocumentationPackageSuggestion(id: "missing", title: "M", sourcePath: "docs/nope.md"),
                extensionID: "test.ext",
                context: LanguageServerResolveContext(extensionID: "test.ext"),
                worktreeRoot: tmp
            )
            Issue.record("expected not found")
        } catch DocumentationIndexError.notFound {
            // ok
        }

        // Quota
        let tiny = DocumentationIndexService(
            config: .init(
                storageRoot: tmp.appendingPathComponent("tiny"),
                maxBytes: 4,
                maxEntries: 100
            ))
        do {
            _ = try await tiny.buildIndex(
                package: DocumentationPackageSuggestion(id: "big", title: "Big", sourcePath: "docs/swift.md"),
                extensionID: "test.ext",
                context: LanguageServerResolveContext(extensionID: "test.ext"),
                worktreeRoot: tmp
            )
            Issue.record("expected quota")
        } catch DocumentationIndexError.quotaExceeded {
            // ok
        }
    }

    @Test func providerMustEmitEntries() async throws {
        struct EmptyProv: DocumentationIndexProvider {
            func suggestPackages(context: LanguageServerResolveContext) async throws -> [DocumentationPackageSuggestion]
            {
                []
            }
            func buildIndex(
                package: DocumentationPackageSuggestion,
                context: LanguageServerResolveContext
            ) -> AsyncThrowingStream<DocumentationBuildEvent, Error> {
                AsyncThrowingStream { cont in
                    cont.yield(.progress(.init(packageID: package.id, fraction: 1.0)))
                    cont.yield(.completed)
                    cont.finish()
                }
            }
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13docs2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = DocumentationIndexService(config: .init(storageRoot: tmp))
        await svc.registerProvider(EmptyProv(), extensionID: "test.ext")
        do {
            _ = try await svc.buildIndex(
                package: DocumentationPackageSuggestion(id: "empty", title: "Empty"),
                extensionID: "test.ext",
                context: LanguageServerResolveContext(extensionID: "test.ext"),
                worktreeRoot: nil
            )
            Issue.record("expected not found for empty provider")
        } catch DocumentationIndexError.notFound {
            // ok — no soft-filled synthetic entry
        }
    }
}

@Suite("Phase 13 no soft-stub wire")
struct Phase13NoSoftStubTests {
    @Test func builtInRequiresProviders() async throws {
        struct MiniExt: CodeEditorExtension {
            var manifest: ExtensionManifest {
                ExtensionManifest(id: "ext.p13", displayName: "P13")
            }
            func activate(in context: any ExtensionAuthorContext) async throws {}
            func deactivate() async {}
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13ns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = makeBroker(tmp: tmp)
        let instance = BuiltInExtensionInstance(
            ext: MiniExt(),
            services: ExtensionHostServices(),
            environment: .full,
            generation: 1,
            broker: broker
        )
        try await instance.activate()
        // Without providers, Phase 13 methods must fail — not return canned ok/[]
        do {
            _ = try await instance.request(.dapResolveLaunchPlan, payload: Data(#"{"adapterID":"x"}"#.utf8))
            Issue.record("expected method not found")
        } catch {
            // ok
        }
        do {
            _ = try await instance.request(.slashExecute, payload: Data(#"{"commandID":"x"}"#.utf8))
            Issue.record("expected method not found")
        } catch {
            // ok
        }

        struct DAPProv: DebugAdapterProvider {
            var adapterIDs: [String] { ["real-dap"] }
            func resolveLaunchPlan(
                adapterID: String,
                context: LanguageServerResolveContext
            ) async throws -> DebugAdapterLaunchPlan {
                DebugAdapterLaunchPlan(
                    adapterID: adapterID,
                    displayName: "Real",
                    languages: ["swift"],
                    command: "real-dap",
                    binarySource: .testFactory(id: "real-f"),
                    extensionID: context.extensionID
                )
            }
        }
        await instance.setDebugAdapterProvider(DAPProv())
        let planData = try await instance.request(
            .dapResolveLaunchPlan,
            payload: Data(#"{"adapterID":"real-dap"}"#.utf8)
        )
        let plan = try JSONDecoder().decode(DebugAdapterLaunchPlan.self, from: planData)
        #expect(plan.adapterID == "real-dap")
        #expect(plan.command == "real-dap")
        await instance.stop(reason: .hostShutdown)
    }

    @Test func reverseRunInTerminalUsesTerminalManager() async throws {
        let pair = DAPTestTransport.makePair()
        let mock = MockDebugAdapter(transport: pair.server)
        await mock.setIssueRunInTerminalOnLaunch(true)
        await mock.start()
        let handler = await MockTerminalDAPRunInTerminalHandler.make()
        let session = DebugAdapterSession(
            definition: DebugAdapterDefinition(
                id: "t",
                displayName: "T",
                launch: .test(factoryID: "x")
            ),
            transportFactory: { pair.client }
        )
        await session.setRunInTerminalHandler(handler)
        try await session.start()
        try await session.launch(configuration: DAPJSONObject(["program": "x"]))
        // Wait for reverse runInTerminal to invoke the terminal manager handler.
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if handler.counter.count > 0 { break }
        }
        #expect(handler.counter.count >= 1, "terminal manager must handle runInTerminal")
        #expect(handler.counter.lastArgs == ["echo", "debug"])
        await session.disconnect()
        await mock.stop()
    }
}

@Suite("Phase 13 catalog")
struct Phase13CatalogTests {
    @Test func wireMethodsPresent() {
        #expect(ExtensionMethodCatalog.contains(.dapResolveLaunchPlan))
        #expect(ExtensionMethodCatalog.contains(.mcpResolveLaunchPlan))
        #expect(ExtensionMethodCatalog.contains(.slashExecute))
        #expect(ExtensionMethodCatalog.contains(.docsBuildIndex))
        #expect(ExtensionMethodCatalog.schemaHash.count == 64)
    }
}
