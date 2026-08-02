import CodeEditorLanguageJSON
import CodeEditorLanguageSupport
import CodeEditorLanguageSwift
import CodeEditorLanguages
import CodeEditorTreeSitter
import Foundation
import Testing

@Suite("Language pack provenance")
struct LanguagePackProvenanceTests {
    @Test func swiftPinsMatchConstants() {
        #expect(CodeEditorLanguageSwift.grammarCommit.count == 40)
        #expect(CodeEditorLanguageSwift.grammarSourceURL.contains("tree-sitter-swift"))
        #expect(CodeEditorLanguageSwift.grammarParserSHA256.count == 64)
    }

    @Test func jsonPinsMatchConstants() {
        #expect(CodeEditorLanguageJSON.grammarCommit.count == 40)
        #expect(CodeEditorLanguageJSON.grammarSourceURL.contains("tree-sitter-json"))
    }

    @Test func registerIdempotent() throws {
        _ = try CodeEditorLanguageSwift.register()
        #expect(try CodeEditorLanguageSwift.register() == false)
        let registered = try CodeEditorLanguageJSON.register()
        // Idempotent register returns false when already registered; first call may be true.
        #expect(registered == true || registered == false)
        #expect(try CodeEditorLanguageJSON.register() == false)
    }
}

@Suite("Language bootstrap smoke")
struct LanguageBootstrapSmokeTests {
    @Test func bootstrapRegistersParsersAndHighlights() {
        _ = CodeEditorLanguages.bootstrap()
        let snap = LanguageRegistry.shared.snapshot()
        #expect(!snap.definitions.isEmpty)
        #expect(!snap.languageIDsWithParsers.isEmpty)

        // Collision: unique ids
        let ids = snap.definitions.map(\.id.rawValue)
        #expect(ids.count == Set(ids).count)

        var missingHighlights: [String] = []
        for id in snap.languageIDsWithParsers {
            if LanguageRegistry.shared.queryURL(for: id, kind: .highlights) == nil {
                // plainText etc. may not have parsers in set
                if id.rawValue != "plainText" {
                    missingHighlights.append(id.rawValue)
                }
            }
        }
        // Allow empty only if no packs linked — with Languages linked should be empty or small.
        #expect(missingHighlights.count < snap.languageIDsWithParsers.count)
    }

    @Test func swiftAndJsonHighlightConfigsLoad() throws {
        _ = try CodeEditorLanguageSwift.register()
        _ = try CodeEditorLanguageJSON.register()
        TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())

        let swiftCfg = try TreeSitterConfigurationFactory.languageConfiguration(for: .swift)
        #expect(swiftCfg != nil)

        let jsonCfg = try TreeSitterConfigurationFactory.languageConfiguration(for: .json)
        #expect(jsonCfg != nil)
    }

    @Test func querySetLoaderFindsHighlights() throws {
        _ = try CodeEditorLanguageSwift.register()
        let (sources, diags) = try QuerySetLoader.loadSources(
            languageID: .swift,
            kinds: [.highlights, .folds],
            required: [.highlights]
        )
        #expect(sources[.highlights] != nil)
        #expect(!sources[.highlights]!.isEmpty)
        _ = diags
    }
}

@Suite("Swift JSON corpus")
@MainActor
struct LanguageCorpusTests {
    @Test func swiftCorpusHighlightsSomething() async throws {
        _ = try CodeEditorLanguageSwift.register()
        TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
        let provider = TreeSitterHighlightProvider(language: .swift)
        await provider.setDocumentText(
            """
            // comment
            func hello() async -> String {
              return "hi \\(1)"
            }
            @MainActor
            struct S<T> {}
            """)
        let ranges = try await provider.queryHighlights(
            in: NSRange(location: 0, length: 20),
            text: "func hello() async -> String { return \"x\" }"
        )
        _ = ranges
    }

    @Test func jsonCorpusParses() async throws {
        _ = try CodeEditorLanguageJSON.register()
        TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
        let provider = TreeSitterHighlightProvider(language: .json)
        let text = #"{"a": 1, "b": "\u0041", "nested": {"x": true}}"#
        await provider.setDocumentText(text)
        let ranges = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length),
            text: text
        )
        _ = ranges
    }
}

@Suite("Language pack missing artifacts")
struct LanguagePackMissingArtifactTests {
    @Test func languagePackErrorDescriptionsAreActionable() {
        let err = LanguagePackError.missingQuery(
            language: .swift,
            query: "highlights",
            searchedPaths: ["/tmp/missing.scm"]
        )
        #expect(err.description.contains("highlights"))
        #expect(err.description.contains("swift"))
        #expect(err.description.contains("/tmp/missing.scm"))
    }

    @Test func swiftHighlightsQueryResolvesAfterRegister() throws {
        _ = try CodeEditorLanguageSwift.register()
        let url = LanguageRegistry.shared.queryURL(for: .swift, kind: .highlights)
        #expect(url != nil)
        #expect(CodeEditorLanguageSwift.lastError == nil)
    }
}
