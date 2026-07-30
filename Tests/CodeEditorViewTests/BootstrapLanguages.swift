import CodeEditorLanguages
import Testing

/// Ensures the umbrella language pack is registered for highlight tests.
enum TestLanguageBootstrap {
    @discardableResult
    static func ensure() -> Bool {
        CodeEditorLanguages.bootstrap()
    }
}

/// Suite that runs bootstrap before any other test in this target touches languages.
/// Individual tests also call ``TestLanguageBootstrap.ensure()`` via language APIs
/// (`languageConfiguration`) and the umbrella autoload constructor when linked.
@Suite(.serialized)
struct LanguageBootstrapSuite {
    init() {
        TestLanguageBootstrap.ensure()
    }

    @Test func umbrellaBootstrapInstallsProvider() {
        #expect(TreeSitterLanguageEnvironment.configurationProvider != nil)
        #expect(LanguageRegistry.shared.hasParser(for: .swift))
    }
}
