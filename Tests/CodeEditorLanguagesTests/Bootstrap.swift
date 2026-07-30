import CodeEditorLanguages
import Testing

enum LanguagesTestBootstrap {
    @discardableResult
    static func ensure() -> Bool {
        CodeEditorLanguages.bootstrap()
    }
}

@Suite(.serialized)
struct LanguagesBootstrapSuite {
    init() {
        LanguagesTestBootstrap.ensure()
    }

    @Test func umbrellaBootstrapRegistersParsers() {
        #expect(LanguageRegistry.shared.hasParser(for: .swift))
        #expect(LanguageRegistry.shared.hasParser(for: .json))
        #expect(CodeLanguage.swift.queryURL(for: "highlights") != nil)
    }
}
