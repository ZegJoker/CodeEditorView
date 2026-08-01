import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Language switch debug")
@MainActor
struct LanguageSwitchDebugTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func dumpAfterMultiSwitch() async throws {
        let controller = EditorController(text: "func x() {}\n", language: .swift)
        let languages: [CodeLanguage] = [.swift, .python, .javascript, .rust, .cSharp, .go, .cSharp]
        for lang in languages {
            controller.language = lang
            controller.text = sample(for: lang)
            for _ in 0..<50 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            try? await Task.sleep(for: .milliseconds(250))
        }

        let source = controller.text
        print("FINAL TEXT:\n\(source)")
        print("lang=\(controller.languageID ?? "nil") providers=\(controller.highlightProviders.count)")

        // Query provider directly
        if let provider = controller.highlightProviders.first as? TreeSitterHighlightProvider {
            let full = NSRange(location: 0, length: (source as NSString).length)
            let highlights = try await provider.queryHighlights(in: full, text: source)
            print("provider highlight count=\(highlights.count)")
            let ns = source as NSString
            for h in highlights.prefix(40) {
                let piece = ns.substring(with: h.range)
                print(
                    "  \(h.range.location)+\(h.range.length) raw=\(h.rawCapture ?? "") text=\(piece.debugDescription)")
            }
        } else {
            print("NO TreeSitter provider")
        }

        // Dump attribute runs
        let storage = controller.document.storage
        var loc = 0
        while loc < storage.length {
            var effective = NSRange()
            let attrs = storage.attributes(at: loc, effectiveRange: &effective)
            let color = attrs[.foregroundColor] as? PlatformColor
            let piece = (storage.string as NSString).substring(with: effective)
            print(
                "ATTR \(effective.location)+\(effective.length) color=\(color.map { String(describing: $0) } ?? "nil") text=\(piece.debugDescription)"
            )
            loc = effective.location + effective.length
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
