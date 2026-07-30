import Testing
import CodeEditorLanguageSupport

@Suite("CodeEditorLanguageSupport")
struct LanguageRegistryTests {
    @Test func customLanguageIDCanRegister() {
        let id = LanguageID("company.dsl")
        #expect(id.rawValue == "company.dsl")

        let definition = LanguageDefinition(
            id: id,
            displayName: "Company DSL",
            tsName: "company-dsl",
            fileExtensions: ["cdsl"],
            aliases: ["dsl"],
            lineComment: "#"
        )

        let registry = LanguageRegistry.shared
        registry.register(definition)
        registry.registerParser(for: id) { nil }
        registry.registerQueryProvider(for: id) { _ in nil }

        #expect(registry.definition(for: id)?.displayName == "Company DSL")
        #expect(registry.hasParser(for: id))
        #expect(registry.hasQueryProvider(for: id))
        #expect(registry.parser(for: id) == nil)

        // Built-in catalog still available without grammar packs.
        #expect(CodeLanguages.language(id: "swift")?.displayName == "Swift")
        #expect(LanguageID.swift.rawValue == TreeSitterLanguageID.swift.rawValue)
    }

    @Test func languageIDExpressibleByStringLiteral() {
        let id: LanguageID = "host.custom"
        #expect(id == LanguageID(rawValue: "host.custom"))
    }
}
