import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages


@Suite("TreeSitterHighlightProvider")
@MainActor
struct TreeSitterHighlightTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func jsonHighlightsKeysAndStrings() async throws {
        let provider = try TreeSitterHighlightProvider(language: .json)
        let source = #"{ "hello": 123 }"#
        await provider.setDocumentText(source)
        let highlights = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (source as NSString).length),
            text: source
        )
        #expect(!highlights.isEmpty)
        // JSON highlighters typically tag strings; numbers may be constant/number.
        let raw = Set(highlights.compactMap(\.rawCapture))
        #expect(raw.contains { $0.contains("string") || $0.contains("number") || $0.contains("constant") })
    }

    @Test func swiftHighlightsKeywords() async throws {
        let provider = try TreeSitterHighlightProvider(language: .swift)
        let source = "func hello() { return 1 }"
        await provider.setDocumentText(source)
        let highlights = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (source as NSString).length),
            text: source
        )
        #expect(!highlights.isEmpty)
        let hasKeyword = highlights.contains {
            $0.capture == .keyword
                || ($0.rawCapture?.contains("keyword") == true)
        }
        #expect(hasKeyword)
    }

    @Test func controllerWithLanguagePaints() async {
        let controller = EditorController(
            text: #"{"a": true}"#,
            language: .json
        )
        #expect(controller.highlightProviders.isEmpty == false)
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            containerWidth: 400
        )
        try? await Task.sleep(for: .milliseconds(120))
        var colored = false
        let full = NSRange(location: 0, length: controller.document.length)
        controller.document.storage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, _, _ in
            if value != nil { colored = true }
        }
        #expect(colored)
    }
}
