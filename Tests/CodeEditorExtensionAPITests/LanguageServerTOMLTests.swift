import CodeEditorExtensionAPI
import Foundation
import Testing

@Suite("Phase 12 language_servers TOML")
struct LanguageServerTOMLTests {
    @Test func parsesLanguageServersTable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ls-toml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = """
            id = "com.example.ls"
            name = "LS"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            [activation]
            events = ["startup"]
            [language_servers.sourcekit-lsp]
            name = "SourceKit"
            languages = ["Swift"]
            command = "sourcekit-lsp"
            args = ["--log=info"]
            download_url = "https://cdn.example/sk.zip"
            download_digest = "abc"
            weird_field = 1
            """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let plan = try ExtensionPackageLoader.load(directory: dir, options: .init(computeDigest: false))
        #expect(plan.languageServers.count == 1)
        let ls = try #require(plan.languageServers.first)
        #expect(ls.serverID == "sourcekit-lsp")
        #expect(ls.displayName == "SourceKit")
        #expect(ls.languages.contains("Swift"))
        #expect(ls.command == "sourcekit-lsp")
        #expect(ls.arguments == ["--log=info"])
        #expect(ls.downloadURL != nil)
        #expect(plan.parityProfile == "codeeditor-ls-s2")
        #expect(plan.diagnostics.contains { $0.code == "language_server.unsupported" })
        let seed = ls.makeSeedPlan()
        if case .downloaded = seed.binarySource {
            // ok
        } else {
            Issue.record("expected downloaded source")
        }
    }

    @Test func seedPlanNpmAndSystemPath() {
        let npm = LanguageServerContribution(
            serverID: "tsserver",
            languages: ["typescript"],
            npmPackage: "typescript-language-server",
            npmVersion: "4.0.0",
            npmBin: "typescript-language-server"
        ).makeSeedPlan()
        if case .npm(let p, let v, let b) = npm.binarySource {
            #expect(p == "typescript-language-server")
            #expect(v == "4.0.0")
            #expect(b == "typescript-language-server")
        } else {
            Issue.record("npm")
        }
        let sys = LanguageServerContribution(serverID: "clangd", command: "clangd").makeSeedPlan()
        if case .systemPath(let n) = sys.binarySource {
            #expect(n == "clangd")
        } else {
            Issue.record("system")
        }
    }
}
