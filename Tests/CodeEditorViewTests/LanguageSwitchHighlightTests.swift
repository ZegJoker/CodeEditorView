import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages


@Suite("Language switch highlighting")
@MainActor
struct LanguageSwitchHighlightTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func multiSwitchKeepsContiguousTokenColors() async throws {
        let controller = EditorController(text: DemoCSharp, language: .swift)
        let languages: [CodeLanguage] = [.swift, .python, .javascript, .rust, .cSharp, .go, .cSharp]
        for lang in languages {
            controller.language = lang
            controller.text = sample(for: lang)
            for _ in 0..<40 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(25))
            }
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            try? await Task.sleep(for: .milliseconds(150))
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            try? await Task.sleep(for: .milliseconds(200))
        }

        let source = controller.text
        let storage = controller.document.storage
        let ns = source as NSString

        func assertUniform(_ token: String) {
            let r = ns.range(of: token)
            guard r.location != NSNotFound, r.length > 0 else {
                Issue.record("token \(token) not found in \(source)")
                return
            }
            var colors: [String] = []
            for i in 0..<r.length {
                let attrs = storage.attributes(at: r.location + i, effectiveRange: nil)
                let color = attrs[.foregroundColor] as? PlatformColor
                colors.append(color.map { String(describing: $0) } ?? "nil")
            }
            let unique = Set(colors)
            print("token=\(token) unique=\(unique.count) colors=\(colors)")
            #expect(unique.count == 1, "\(token) should be one color, got \(unique.count): \(colors)")
        }

        assertUniform("WriteLine")
        assertUniform("return")
        assertUniform("class")
        assertUniform("static")
        assertUniform("\"hi\"")
    }

    @Test func wrapProducesMultipleFragments() async throws {
        let long = String(repeating: "abcdefghij ", count: 40)
        var config = EditorConfiguration()
        config.wrapLines = true
        let controller = EditorController(text: long, configuration: config, language: .plainText)
        let snap = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 400),
            containerWidth: 200
        )
        #expect(snap.fragments.count > 1, "expected wrap into multiple fragments, got \(snap.fragments.count)")
        #expect(controller.layout.wrapLines == true)
        #expect(snap.contentSize.width <= 210)
    }

    @Test func wrapToggleRebuildsFragments() async throws {
        let long = String(repeating: "abcdefghij ", count: 40)
        var config = EditorConfiguration()
        config.wrapLines = false
        let controller = EditorController(text: long, configuration: config, language: .plainText)
        let unwrapped = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 400),
            containerWidth: 200
        )
        #expect(unwrapped.fragments.count == 1 || unwrapped.contentSize.width > 300)

        config.wrapLines = true
        controller.configuration = config
        let wrapped = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 400),
            containerWidth: 200
        )
        #expect(wrapped.fragments.count > 1, "toggle wrap on should fragment, got \(wrapped.fragments.count)")
        #expect(wrapped.contentSize.width <= 210)
    }
}

private let DemoCSharp = """
using System;
class Program {
    static void Greet(string name) {
        Console.WriteLine("hi");
        return;
    }
}
"""

private func sample(for language: CodeLanguage) -> String {
    switch language.id {
    case .cSharp: return DemoCSharp
    case .swift: return "func hello() { return }\n"
    case .python: return "def hello():\n    return\n"
    case .javascript: return "function hello() { return }\n"
    case .rust: return "fn hello() { return; }\n"
    case .go: return "func hello() { return }\n"
    default: return "// \(language.displayName)\n"
    }
}
