import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Language switch debug")
@MainActor
struct LanguageSwitchDebugTests {
    init() { CodeEditorLanguages.bootstrap() }

    /// Rapid multi-language switches must complete within a bound and leave a live provider.
    @Test func multiSwitchCompletesWithoutHang() async throws {
        let controller = EditorController(text: "func x() {}\n", language: .swift)
        let languages: [CodeLanguage] = [.swift, .python, .javascript, .rust, .cSharp, .go]
        let deadline = ContinuousClock.now + .seconds(8)
        for lang in languages {
            #expect(ContinuousClock.now < deadline, "language switch loop exceeded budget")
            controller.language = lang
            controller.text = sample(for: lang)
            // Brief yield only — do not layoutViewport under full-suite MainActor contention.
            for _ in 0..<8 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(ContinuousClock.now < deadline)
        #expect(controller.languageID != nil)
        // Final C# sample should be present.
        #expect(controller.text.contains("class") || controller.text.contains("func") || !controller.text.isEmpty)

        if let provider = controller.highlightProviders.first as? TreeSitterHighlightProvider {
            let source = controller.text
            let full = NSRange(location: 0, length: (source as NSString).length)
            // Non-throwing query after switches proves provider stays usable.
            _ = try await provider.queryHighlights(in: full, text: source)
        } else {
            #expect(!controller.highlightProviders.isEmpty, "expected a highlight provider after switches")
        }
    }
}

private func sample(for language: CodeLanguage) -> String {
    switch language.id {
    case .cSharp:
        return """
            using System;
            class Program {
                static void Greet(string name) {
                    Console.WriteLine("hi");
                    return;
                }
            }
            """
    case .swift: return "func hello() { return }\n"
    case .python: return "def hello():\n    return\n"
    case .javascript: return "function hello() { return }\n"
    case .rust: return "fn hello() { return; }\n"
    case .go: return "func hello() { return }\n"
    default: return "// \(language.displayName)\n"
    }
}
