import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages


@Suite("MainActor load stress")
@MainActor
struct MainActorLoadStressTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func concurrentLoadAndSetDocumentText() async throws {
        let provider = try #require(TreeSitterHighlightProvider.make(for: .typescript))
        // Warm TS
        await provider.loadAsync(language: .typescript)
        await provider.setDocumentText("const a = 1\n")

        let t0 = ContinuousClock.now
        // Fire load and setDocumentText the way bootstrap + languageConfig race
        async let load: Void = provider.loadAsync(language: .yaml)
        // Immediately try to set text (bootstrap does this)
        try? await Task.sleep(for: .milliseconds(1))
        await provider.setDocumentText("""
        name: CodeEditorView
        version: 1
        features:
          - gutter
          - highlight
        enabled: true
        """)
        await load
        // And again after load (languageConfig applyLanguageID bootstrap)
        await provider.setDocumentText("""
        name: CodeEditorView
        version: 1
        features:
          - gutter
          - highlight
        enabled: true
        """)
        let elapsed = ContinuousClock.now - t0
        print("concurrent elapsed=\(elapsed)")
        #expect(elapsed < .seconds(5))
    }

    @Test func rapidYAMLSwitchFromManyLanguages() async throws {
        let controller = EditorController(text: "x", language: .swift)
        let langs: [CodeLanguage] = [.typescript, .yaml, .html, .yaml, .typescript, .yaml]
        let t0 = ContinuousClock.now
        for lang in langs {
            controller.language = lang
            controller.text = DemoSamples.source(for: lang)
            await Task.yield()
        }
        // settle final yaml
        for _ in 0..<80 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
            if ContinuousClock.now - t0 > .seconds(12) { break }
        }
        print("rapid elapsed=\(ContinuousClock.now - t0) lang=\(controller.languageID ?? "?")")
        #expect(ContinuousClock.now - t0 < .seconds(12))
    }
}

// minimal samples
private enum DemoSamples {
    static func source(for language: CodeLanguage) -> String {
        switch language.id {
        case .yaml:
            return "name: x\nversion: 1\nfeatures:\n  - a\n  - b\nenabled: true\n"
        case .typescript:
            return "function f(x: string): void { return }\n"
        case .html:
            return "<html><body>hi</body></html>\n"
        default:
            return "// \(language.displayName)\n"
        }
    }
}
