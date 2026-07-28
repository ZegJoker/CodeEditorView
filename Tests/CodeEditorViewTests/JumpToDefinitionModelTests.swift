import Testing
import Foundation
@testable import CodeEditorView

@MainActor
final class MockJumpDelegate: JumpToDefinitionDelegate {
    var linksToReturn: [JumpToDefinitionLink]? = []
    var opened: [JumpToDefinitionLink] = []
    var queryCount = 0

    func queryLinks(forRange range: NSRange, textView: EditorController) async -> [JumpToDefinitionLink]? {
        queryCount += 1
        return linksToReturn
    }

    func openLink(link: JumpToDefinitionLink) {
        opened.append(link)
    }
}

@Suite("Jump to definition")
@MainActor
struct JumpToDefinitionModelTests {
    @Test func wordFallbackFindsIdentifierRange() {
        let text = "func greet(_ name: String) {\n    print(name)\n}\n"
        let controller = EditorController(text: text)
        let nameOffset = (text as NSString).range(of: "name").location
        let range = JumpToDefinitionModel.findDefinitionRange(at: nameOffset, controller: controller)
        #expect(range != nil)
        if let range {
            let snip = (text as NSString).substring(with: range)
            #expect(snip == "name" || snip.contains("name"))
        }
    }

    @Test func cancelHoverClearsEmphasis() {
        let controller = EditorController(
            text: "let value = 1\n",
            configuration: EditorConfiguration()
        )
        let mock = MockJumpDelegate()
        controller.jumpToDefinitionDelegate = mock
        controller.jumpHover(atUTF16Offset: 4)
        // Allow async hover task.
        // Synchronous path: set hover range via perform + cancel.
        controller.cancelJumpHover()
        #expect(controller.jumpHoveredRange == nil)
        let jumpEmphases = controller.emphasis.items.filter { $0.group == EmphasisGroup.jumpToDefinition }
        #expect(jumpEmphases.isEmpty)
    }

    @Test func singleLocalLinkSelectsTarget() async {
        let text = "hello\nworld\n"
        let controller = EditorController(text: text)
        let mock = MockJumpDelegate()
        let target = CursorPosition(range: NSRange(location: 6, length: 5), line: 1, column: 0)
        mock.linksToReturn = [
            JumpToDefinitionLink(
                url: nil,
                targetRange: target,
                label: "world"
            ),
        ]
        controller.jumpToDefinitionDelegate = mock

        let range = NSRange(location: 0, length: 5)
        controller.performJumpToDefinition(at: range)
        // Wait for async query.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.queryCount == 1)
        #expect(controller.selectedRange.location == 6)
        #expect(controller.selectedRange.length == 5)
        #expect(mock.opened.isEmpty)
    }

    @Test func remoteLinkCallsOpenLink() async {
        let controller = EditorController(text: "foo\n")
        let mock = MockJumpDelegate()
        let url = URL(string: "https://example.com")!
        mock.linksToReturn = [
            JumpToDefinitionLink(
                url: url,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "Example"
            ),
        ]
        controller.jumpToDefinitionDelegate = mock
        controller.performJumpToDefinition(at: NSRange(location: 0, length: 3))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.opened.count == 1)
        #expect(mock.opened.first?.url == url)
    }

    @Test func emptyLinksFailsSoftly() async {
        let controller = EditorController(text: "foo\n")
        let mock = MockJumpDelegate()
        mock.linksToReturn = []
        var failed = false
        controller.onJumpFailed = { failed = true }
        controller.jumpToDefinitionDelegate = mock
        controller.performJumpToDefinition(at: NSRange(location: 0, length: 3))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(failed)
        #expect(controller.jumpHoveredRange == nil)
    }

    @Test func multiLinkShowsPopover() async {
        let controller = EditorController(text: "foo\n")
        let mock = MockJumpDelegate()
        mock.linksToReturn = [
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "A"
            ),
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "B"
            ),
        ]
        controller.jumpToDefinitionDelegate = mock
        controller.performJumpToDefinition(at: NSRange(location: 0, length: 3))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.isJumpLinkPopoverVisible)
        #expect(controller.completionsVisible)
        #expect(controller.completionSession.items.count == 2)
    }

    @Test func multiLinkAnchorsAtQueryRangeNotCaret() async {
        // Caret at line 0; jump query on later text — panel anchor must follow the query.
        let text = "line0\nline1\nline2 target\n"
        let controller = EditorController(text: text)
        let mock = MockJumpDelegate()
        mock.linksToReturn = [
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "A"
            ),
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "B"
            ),
        ]
        controller.jumpToDefinitionDelegate = mock
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        let target = (text as NSString).range(of: "target")
        controller.performJumpToDefinition(at: target)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.isJumpLinkPopoverVisible)
        let anchor = controller.completionSession.anchorPosition?.range.location ?? -1
        #expect(anchor >= target.location)
        #expect(anchor < target.location + target.length + 1)
        #expect(anchor != 0 || target.location == 0)
    }

    @Test func localJumpStartOfDocumentWorksRepeatedly() async {
        let text = "hello\nworld\n"
        let controller = EditorController(text: text)
        let mock = MockJumpDelegate()
        mock.linksToReturn = [
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "Start"
            ),
        ]
        controller.jumpToDefinitionDelegate = mock

        controller.setSelectedRange(NSRange(location: 6, length: 0))
        controller.performJumpToDefinition(at: NSRange(location: 6, length: 5))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.selectedRange.location == 0)

        // Jump again from elsewhere — must still land at start.
        controller.setSelectedRange(NSRange(location: 8, length: 0))
        controller.performJumpToDefinition(at: NSRange(location: 6, length: 5))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.selectedRange.location == 0)
    }

    @Test func selectionChangeDoesNotReplaceJumpPopoverWithCompletions() async {
        final class CompletionSpy: CodeSuggestionDelegate {
            var onMoveCount = 0
            func completionSuggestionsRequested(
                textView: EditorController,
                cursorPosition: CursorPosition
            ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
                (cursorPosition, [SimpleCodeSuggestion(label: "typed")])
            }
            func completionOnCursorMove(
                textView: EditorController,
                cursorPosition: CursorPosition
            ) -> [any CodeSuggestionEntry]? {
                onMoveCount += 1
                return [SimpleCodeSuggestion(label: "typed")]
            }
            func completionWindowApplyCompletion(
                item: any CodeSuggestionEntry,
                textView: EditorController,
                cursorPosition: CursorPosition?
            ) {}
        }

        let controller = EditorController(text: "hello world\n")
        let jump = MockJumpDelegate()
        jump.linksToReturn = [
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "A"
            ),
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "B"
            ),
        ]
        let completion = CompletionSpy()
        controller.jumpToDefinitionDelegate = jump
        controller.completionDelegate = completion

        controller.performJumpToDefinition(at: NSRange(location: 6, length: 5))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.isJumpLinkPopoverVisible)

        // Selection change while jump popover is up must not call completion filter.
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(completion.onMoveCount == 0)
        #expect(controller.isJumpLinkPopoverVisible)
        #expect(controller.completionSession.items.first is JumpToDefinitionLink)
    }

    @Test func rangeForCursorPositionUsesLineColumn() {
        let text = "ab\ncd\n"
        let controller = EditorController(text: text)
        let pos = CursorPosition(range: NSRange(location: 0, length: 0), line: 1, column: 1)
        let range = controller.rangeForCursorPosition(pos)
        #expect(range?.location == 4) // "ab\n" + 'c' then column 1 → 'd' at 4
    }

    @Test func rangeForCursorPositionStartOfDocument() {
        let controller = EditorController(text: "hello\n")
        let pos = CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0)
        let range = controller.rangeForCursorPosition(pos)
        #expect(range?.location == 0)
        #expect(range?.length == 0)
    }

    @Test func openLocalLinkNotifiesSelectionBinding() async {
        let text = "hello\nworld\n"
        let controller = EditorController(text: text)
        var hostSelection = NSRange(location: 6, length: 0)
        controller.onSelectionDidChange = { hostSelection = $0 }
        controller.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(hostSelection.location == 6)

        let link = JumpToDefinitionLink(
            url: nil,
            targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
            label: "Start"
        )
        controller.jumpToDefinitionModel.open(link: link)
        #expect(controller.selectedRange.location == 0)
        #expect(hostSelection.location == 0)
    }
}
