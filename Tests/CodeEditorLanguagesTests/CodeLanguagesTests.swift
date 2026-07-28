import Testing
@testable import CodeEditorLanguages

@Suite("CodeEditorLanguages")
struct CodeLanguagesTests {
    @Test func fullCatalogMatchesCELCount() {
        // plainText + full grammar set
        #expect(CodeLanguage.allLanguages.count >= 40)
        #expect(CodeLanguages.language(id: "swift")?.displayName == "Swift")
        #expect(CodeLanguages.language(id: "typescript")?.id == .typescript)
        #expect(CodeLanguages.language(id: "cSharp")?.tsName == "c-sharp"
            || CodeLanguages.language(id: "csharp") != nil
            || CodeLanguages.language(id: "cs") != nil)
    }

    @Test func registryResolvesExtensions() {
        #expect(CodeLanguages.language(forFileExtension: "swift")?.id == .swift)
        #expect(CodeLanguages.language(forFileExtension: ".json")?.id == .json)
        #expect(CodeLanguages.language(forFileExtension: "py")?.id == .python)
        #expect(CodeLanguages.language(forFileExtension: "rs")?.id == .rust)
        #expect(CodeLanguages.language(forFileExtension: "ts")?.id == .typescript)
    }

    @Test func queryURLsUseCELLayout() {
        #expect(CodeLanguage.swift.queryURL(for: "highlights") != nil)
        #expect(CodeLanguage.json.queryURL(for: "highlights") != nil)
        #expect(CodeLanguage.python.queryURL(for: "highlights") != nil)
        #expect(CodeLanguage.rust.queryURL(for: "highlights") != nil)
    }

    @Test func languageConfigurationsLoadForSeedSet() throws {
        for language in [CodeLanguage.swift, .json, .python, .rust, .go, .bash] {
            let config = try CodeLanguages.languageConfiguration(for: language)
            #expect(config != nil, "Missing config for \(language.displayName)")
            #expect(config?.queries[.highlights] != nil, "Missing highlights for \(language.displayName)")
        }
    }

    @Test func highlightableExcludesPlainText() {
        #expect(CodeLanguages.highlightable.contains { $0.id == .plainText } == false)
        #expect(CodeLanguages.highlightable.count >= 30)
    }
}
