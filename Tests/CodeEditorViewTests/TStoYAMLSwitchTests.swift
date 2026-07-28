import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages

@Suite("TS to YAML switch")
@MainActor
struct TStoYAMLSwitchTests {
    @Test func yamlConfigLoadTime() throws {
        let t0 = ContinuousClock.now
        let config = try CodeLanguages.languageConfiguration(for: .yaml)
        print("YAML config \(ContinuousClock.now - t0) patterns=\(config?.queries[.highlights]?.patternCount ?? -1)")
        #expect(config != nil)
        #expect(ContinuousClock.now - t0 < .seconds(3))
    }

    @Test func typescriptToYamlDoesNotHang() async throws {
        let ts = """
        function greet(name: string): void {
          console.log(`Hello, ${name}!`);
        }
        """
        let yaml = """
        # YAML
        name: CodeEditorView
        version: 1
        features:
          - gutter
          - highlight
        enabled: true
        """
        let controller = EditorController(text: ts, language: .typescript)
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
        print("ts settled lang=\(controller.languageID ?? "?")")

        let t0 = ContinuousClock.now
        controller.language = .yaml
        controller.text = yaml
        var n = 0
        while ContinuousClock.now - t0 < .seconds(10) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            n += 1
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            if n >= 60 { break }
        }
        let elapsed = ContinuousClock.now - t0
        print("yaml switch elapsed=\(elapsed) n=\(n) lang=\(controller.languageID ?? "?") providers=\(controller.highlightProviders.count)")
        #expect(elapsed < .seconds(8))
        #expect(controller.languageID == "yaml" || controller.languageID == TreeSitterLanguageID.yaml.rawValue)
    }

    @Test func loadAsyncDoesNotDeadlockOnMainActor() async throws {
        let provider = try #require(TreeSitterHighlightProvider.make(for: .typescript))
        await provider.loadAsync(language: .typescript)
        await provider.setDocumentText("const x = 1\n")
        let t0 = ContinuousClock.now
        // Simulate the UI path: load yaml while still on MainActor, then setDocumentText
        await provider.loadAsync(language: .yaml)
        await provider.setDocumentText("name: test\n")
        let full = NSRange(location: 0, length: 11)
        let hs = try await provider.queryHighlights(in: full, text: "name: test\n")
        print("loadAsync path elapsed=\(ContinuousClock.now - t0) highlights=\(hs.count)")
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }
}
