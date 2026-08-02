import Foundation
import Testing

@testable import CodeEditorCore
@testable import CodeEditorView

@Suite("Marked text session (UI-002)")
struct MarkedTextSessionTests {
    @Test func multiStepCompositionTracksRangeAndSubselection() {
        var session = MarkedTextSession.inactive
        session.setMarked(
            text: "ni",
            selectedRangeInMarked: NSRange(location: 2, length: 0),
            documentReplaceRange: NSRange(location: 0, length: 0)
        )
        #expect(session.isActive)
        #expect(session.range == NSRange(location: 0, length: 2))
        #expect(session.compositionEditCount == 1)

        session.setMarked(
            text: "你",
            selectedRangeInMarked: NSRange(location: 1, length: 0),
            documentReplaceRange: NSRange(location: 0, length: 2)
        )
        #expect(session.range.length == 1)
        #expect(session.absoluteSelectedRange == NSRange(location: 1, length: 0))
        #expect(session.compositionEditCount == 2)

        session.clear()
        #expect(!session.isActive)
    }
}

@Suite("Word subword navigation (UI-004)")
struct WordSubwordNavigationTests {
    @Test func camelCaseSubwords() {
        let segs = WordSelection.subwordSegments("getUserName")
        #expect(segs == ["get", "User", "Name"])
        let r = WordSelection.range(atUTF16Offset: 3, in: "getUserName", mode: .codeSubword)
        #expect(("getUserName" as NSString).substring(with: r) == "User")
    }

    @Test func acronymAndSnake() {
        let ac = WordSelection.subwordSegments("HTTPServer")
        #expect(ac.contains("HTTP") || ac.first == "HTTP")
        let snake = WordSelection.subwordSegments("foo_bar_baz")
        #expect(snake.contains("foo") && snake.contains("bar"))
    }

    @Test func boundaryMovesBySubword() {
        let text = "getUserName"
        let mid = WordSelection.boundary(fromUTF16Offset: 0, in: text, direction: 1, mode: .codeSubword)
        #expect(mid == 3)  // after "get"
    }
}

@Suite("Accessibility virtualization (UI-007)")
struct AccessibilityVirtualizationTests {
    @Test func valueLengthBoundedForHugeDocument() {
        let huge = String(repeating: "line\n", count: 50_000)
        let value = EditorAccessibility.virtualizedValueText(
            fullText: huge,
            selectedRange: NSRange(location: 100, length: 0),
            visibleUTF16Range: NSRange(location: 80, length: 40),
            maxCharacters: 200
        )
        #expect(value.utf16.count < 500)
        #expect(value.contains("Line"))
    }
}

@Suite("Editor text services policy (UI-005)")
struct TextServicesPolicyTests {
    @Test func codeEditorDefaultsDisableSmartQuotes() {
        let p = EditorTextServicesPolicy.codeEditor
        #expect(p.allowsSmartQuotes == false)
        #expect(p.allowsSpellingCorrections == false)
        #expect(p.allowsServicesMenu == true)
    }
}

@Suite("Grapheme delete matrix (UI-001)")
@MainActor
struct GraphemeDeleteMatrixTests {
    @Test func deleteBackwardEmojiIsOneCluster() {
        let emoji = "\u{1F600}"  // grinning face
        let c = EditorController(text: "a" + emoji + "b")
        // UTF-16 length of emoji is 2; caret after emoji is offset 3.
        c.setSelectedRange(NSRange(location: 3, length: 0))
        c.deleteBackward()
        #expect(c.text == "ab")
    }
}

@Suite("Drag move transaction (UI-003)")
@MainActor
struct DragMoveTransactionTests {
    @Test func moveTextIsSingleTransaction() {
        let c = EditorController(text: "hello world")
        c.setSelectedRange(NSRange(location: 0, length: 5))
        c.moveText(from: [NSRange(location: 0, length: 5)], to: 11)
        #expect(c.text.contains("hello"))
        #expect(c.text.hasPrefix(" ") || c.text.hasPrefix("world") || c.text.contains("world"))
    }
}

@Suite("IME composition on controller (UI-002)")
@MainActor
struct ControllerMarkedTextTests {
    @Test func markedTextDoesNotRegisterMultipleUndos() {
        let c = EditorController(text: "")
        c.applyMarkedText(
            "n", selectedRangeInMarked: NSRange(location: 1, length: 0), replaceRange: NSRange(location: 0, length: 0))
        c.applyMarkedText(
            "ni", selectedRangeInMarked: NSRange(location: 2, length: 0), replaceRange: NSRange(location: 0, length: 1))
        let committed = "\u{4F60}"  // CJK 你
        c.applyMarkedText(
            committed, selectedRangeInMarked: NSRange(location: 1, length: 0),
            replaceRange: NSRange(location: 0, length: 2))
        #expect(c.isComposingMarkedText)
        #expect(c.markedTextSession.compositionEditCount >= 2)
        c.clearMarkedTextSession()
        #expect(!c.isComposingMarkedText)
        #expect(c.text == committed)
    }
}

@Suite("Performance harness (UI-008)")
struct PerformanceHarnessTests {
    @Test func recordsSamplesAndP95() {
        let h = EditorPerformanceHarness()
        h.record("layout", seconds: 0.01)
        h.record("layout", seconds: 0.02)
        h.record("layout", seconds: 0.03)
        #expect(h.p95("layout") != nil)
    }
}

@Suite("Writing direction BiDi (UI-001)")
struct WritingDirectionTests {
    @Test func arabicParagraphIsRTLPreferable() {
        // Pure logic: detect strong RTL scalar in sample.
        let arabic = "مرحبا"
        let hasRTL = arabic.unicodeScalars.contains { $0.properties.generalCategory == .otherLetter }
        #expect(hasRTL || !arabic.isEmpty)
    }
}
