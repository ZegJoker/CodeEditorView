import CodeEditorExtensionAPI
import Foundation
import Testing

@Suite("Phase 13 TOML contributions")
struct Phase13TOMLTests {
    @Test func parsesDebugMCPSlashDocsTables() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p13-toml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = """
            id = "com.example.p13"
            name = "P13"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            [activation]
            events = ["startup"]
            [debug_adapters.lldb]
            name = "LLDB"
            languages = ["Swift"]
            command = "lldb-dap"
            [mcp_servers.ctx]
            name = "Context"
            command = "ctx-mcp"
            transport = "stdio"
            startup_timeout_ms = 8000
            [slash_commands.explain]
            name = "explain"
            description = "Explain"
            requires_worktree = true
            [documentation_packages.swift]
            title = "Swift docs"
            languages = ["Swift"]
            source_path = "docs/swift.md"
            """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let plan = try ExtensionPackageLoader.load(directory: dir, options: .init(computeDigest: false))
        #expect(plan.debugAdapters.count == 1)
        #expect(plan.debugAdapters[0].adapterID == "lldb")
        #expect(plan.mcpServers.count == 1)
        #expect(plan.mcpServers[0].startupTimeoutMS == 8000)
        #expect(plan.slashCommands.count == 1)
        #expect(plan.slashCommands[0].compatibility == .experimental)
        #expect(plan.documentationPackages.count == 1)
        #expect(plan.parityProfile == "codeeditor-dap-mcp-s2")
        let seed = plan.debugAdapters[0].makeSeedPlan()
        if case .systemPath(let n) = seed.binarySource {
            #expect(n == "lldb-dap")
        } else {
            Issue.record("system path seed")
        }
    }
}

@Suite("CompatibilityProfile")
struct CompatibilityProfileTests {
    @Test func phase13DefaultLabels() {
        // REL-N01: defaults are experimental/pre-alpha honesty, not stable/RC.
        let p = CompatibilityProfile.phase13Default
        #expect(p.status(for: .debugAdapters) == .experimental)
        #expect(p.status(for: .debugLocators) == .experimental)
        #expect(p.status(for: .mcpServers) == .experimental)
        #expect(p.status(for: .documentationIndexing) == .experimental)
        #expect(p.status(for: .slashCommands) == .experimental)
        #expect(p.status(for: .languageModelProviderMetadata) == .unsupported)
        #expect(p.status(for: .legacyAgentServerHosting) == .unsupported)
    }

    @Test func loadFromTOMLText() throws {
        let text = """
            profile = "test"
            [features]
            slash_commands = "experimental"
            mcp_servers = "experimental"
            """
        let p = try CompatibilityProfileLoader.load(toml: text)
        #expect(p.status(for: .slashCommands) == .experimental)
        #expect(p.status(for: .mcpServers) == .experimental)
    }

    @Test func slashSanitize() throws {
        let dirty = "See [x](javascript:alert(1)) and ok"
        let clean = SlashCommandSanitize.sanitizeMarkdown(dirty)
        #expect(!clean.lowercased().contains("javascript:"))
        try SlashCommandSanitize.validateArguments("hi", maxLength: 10)
        do {
            try SlashCommandSanitize.validateArguments(String(repeating: "a", count: 100), maxLength: 10)
            Issue.record("expected overflow")
        } catch SlashCommandError.argumentsTooLong {
            // ok
        }
    }
}
