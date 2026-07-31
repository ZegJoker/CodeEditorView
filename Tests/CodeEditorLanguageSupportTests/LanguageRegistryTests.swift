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

        let registry = LanguageRegistry()
        _ = registry.register(definition)
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

    @Test func detectionPrefersFilenameAndShebang() {
        let registry = LanguageRegistry()
        _ = registry.register(LanguageDefinition(
            id: "swift",
            displayName: "Swift",
            tsName: "swift",
            fileExtensions: ["swift"],
            filenames: ["package.swift"],
            detectionPriority: 10
        ))
        _ = registry.register(LanguageDefinition(
            id: "bash",
            displayName: "Bash",
            tsName: "bash",
            fileExtensions: ["sh"],
            firstLinePatterns: [#"^#!.*\bsh\b"#],
            detectionPriority: 5
        ))
        _ = registry.register(LanguageDefinition(
            id: "python",
            displayName: "Python",
            tsName: "python",
            fileExtensions: ["py"],
            firstLinePatterns: [#"^#!.*\bpython"#]
        ))

        #expect(LanguageDetector.detect(filename: "Package.swift", in: registry)?.rawValue == "swift")
        #expect(LanguageDetector.detect(filename: "run.sh", contentPrefix: "#!/bin/sh\necho", in: registry)?.rawValue == "bash")
        #expect(LanguageDetector.detect(filename: "x.py", in: registry)?.rawValue == "python")
    }

    @Test func snapshotAndDuplicateDiagnostic() {
        let registry = LanguageRegistry()
        let def = LanguageDefinition(id: "a", displayName: "A", tsName: "a", fileExtensions: ["a"])
        _ = registry.register(def)
        let again = registry.register(def)
        #expect(again.diagnostics.contains(.duplicateID("a")))
        let snap = registry.snapshot()
        #expect(snap.definitions.count == 1)
        #expect(snap.generation >= 1)
    }

    @Test func queryKindBasenames() {
        #expect(QueryKind.highlights.fileName == "highlights.scm")
        #expect(QueryKind.allCases.count >= 8)
    }
}
