import Foundation
import Testing

@testable import CodeEditorView

@Suite("Highlighter")
@MainActor
struct HighlighterTests {
    @Test func regexProviderFindsKeywords() async throws {
        let provider = RegexHighlightProvider.swiftLike()
        await provider.setUp(documentLength: 20, languageID: "swift")
        let text = "let x = 1"
        let highlights = try await provider.queryHighlights(
            in: NSRange(location: 0, length: text.utf16.count),
            text: text
        )
        #expect(highlights.contains { $0.capture == .keyword })
        #expect(highlights.contains { $0.capture == .number })
    }

    @Test func highlighterPaintsDocumentAttributes() async {
        let controller = EditorController(
            text: "let answer = 42",
            highlightProviders: [RegexHighlightProvider.swiftLike()],
            languageID: "swift"
        )
        // Force layout + visible range covering whole document.
        let snapshot = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            containerWidth: 500
        )
        #expect(!snapshot.fragments.isEmpty)

        // Allow refresh task to run.
        try? await Task.sleep(for: .milliseconds(80))

        let full = NSRange(location: 0, length: controller.document.length)
        var sawKeywordColor = false
        controller.document.storage.enumerateAttribute(
            .foregroundColor,
            in: full,
            options: []
        ) { value, _, _ in
            if value != nil { sawKeywordColor = true }
        }
        #expect(sawKeywordColor)
    }

    @Test func styledContainerLaterProviderWins() {
        let container = StyledRangeContainer(documentLength: 10, providerIDs: [0, 1])
        container.setHighlights(
            [HighlightRange(range: NSRange(location: 0, length: 5), capture: .keyword)],
            forProvider: 0,
            in: NSRange(location: 0, length: 10)
        )
        container.setHighlights(
            [HighlightRange(range: NSRange(location: 2, length: 3), capture: .string)],
            forProvider: 1,
            in: NSRange(location: 0, length: 10)
        )
        let runs = container.runs(in: NSRange(location: 0, length: 10))
        // Position 2-5 should be string (provider 1)
        var offset = 0
        var foundString = false
        for run in runs {
            if offset >= 2 && offset < 5, run.value == .string {
                foundString = true
            }
            offset += run.length
        }
        #expect(foundString)
    }
}
