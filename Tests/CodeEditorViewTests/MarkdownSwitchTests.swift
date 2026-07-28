import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages

@Suite("Markdown switch")
@MainActor
struct MarkdownSwitchTests {
    @Test func switchToMarkdownDoesNotHang() async throws {
        let controller = EditorController(text: "func x() {}\n", language: .swift)
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }

        let sample = """
        # Title
        Hello **world**

        - item
        - item2

        ```swift
        print("hi")
        ```
        """
        let t0 = ContinuousClock.now
        controller.language = .markdown
        controller.text = sample
        var iterations = 0
        while ContinuousClock.now - t0 < .seconds(5) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            iterations += 1
            if iterations > 15 { break }
        }
        let elapsed = ContinuousClock.now - t0
        print("markdown switch elapsed=\(elapsed) lang=\(controller.languageID ?? "nil") providers=\(controller.highlightProviders.count)")
        #expect(elapsed < .seconds(5))
        _ = controller.layoutViewport(visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600), containerWidth: 800)
    }

    @Test func switchToMarkdownInlineDoesNotHang() async throws {
        let controller = EditorController(text: "hello", language: .swift)
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
        let t0 = ContinuousClock.now
        controller.language = .markdownInline
        controller.text = "hello **bold** and `code`"
        var iterations = 0
        while ContinuousClock.now - t0 < .seconds(5) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            iterations += 1
            if iterations > 15 { break }
        }
        let elapsed = ContinuousClock.now - t0
        print("markdownInline switch elapsed=\(elapsed) lang=\(controller.languageID ?? "nil")")
        #expect(elapsed < .seconds(5))
    }

    @Test func typescriptHighlightsKeywordsWithParent() async throws {
        let source = """
        function greet(name: string): void {
          console.log(`Hello, ${name}!`);
          if (!name) {
            return;
          }
        }
        """
        let controller = EditorController(text: source, language: .typescript)
        for _ in 0..<80 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
        _ = controller.layoutViewport(visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600), containerWidth: 800)
        try? await Task.sleep(for: .milliseconds(300))

        let storage = controller.document.storage
        let ns = source as NSString
        func isHighlighted(_ token: String) -> Bool {
            let r = ns.range(of: token)
            guard r.location != NSNotFound else { return false }
            let c = storage.attributes(at: r.location, effectiveRange: nil)[.foregroundColor] as? PlatformColor
            let s = c.map { String(describing: $0) } ?? "nil"
            print("token=\(token) color=\(s)")
            return !s.contains("labelColor")
        }
        #expect(isHighlighted("function"))
        #expect(isHighlighted("return"))
        #expect(isHighlighted("if"))
    }
}
