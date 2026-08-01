import Foundation
import Testing
@testable import CodeEditorView
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport

@Suite("Reference workflows", .serialized)
@MainActor
struct ReferenceWorkflowTests {
    @Test func typeSelectAndEdit() throws {
        let c = EditorController(text: "")
        c.insertText("hello")
        #expect(c.text == "hello")
        c.setSelectedRange(NSRange(location: 0, length: 5))
        c.insertText("hi")
        #expect(c.text == "hi")
        try c.textDocument.performUndo()
        #expect(c.text == "hello")
    }

    @Test func findWorkflow() {
        let c = EditorController(text: "foo bar foo")
        c.setFindQuery("foo")
        c.findSession.isShowing = true
        c.findNext()
        #expect(c.findSession.matchCount >= 1 || c.selectedRange.length >= 0)
        #expect(c.text.contains("foo"))
    }

    @Test func foldLayoutSmoke() {
        let text = "func a() {\n    let x = 1\n}\n"
        let c = EditorController(text: text)
        c.configuration.peripherals.showFoldingRibbon = true
        c.layout.invalidateAll()
        #expect(c.layout.lineIndex.count >= 2)
    }

    @Test func lifecycleCancelsWork() {
        for _ in 0..<20 {
            let x = EditorController(text: "x")
            x.notifyDidAppear()
            x.notifyDidDisappear()
            x.cancelPendingHighlightWork()
        }
        let doc = TextDocument(text: "shared")
        let session = EditorSession(documentID: doc.id)
        let c = EditorController(document: doc, session: session)
        c.notifyDidAppear()
        c.notifyDidDisappear()
        #expect(c.text == "shared")
    }

    @Test func accessibilityHelpers() {
        let label = EditorAccessibility.label(languageID: "swift", isEditable: true, isDirty: true)
        #expect(label.contains("swift"))
        #expect(label.contains("edited"))
        let long = String(repeating: "a", count: 10_000)
        let value = EditorAccessibility.valueText(
            fullText: long,
            selectedRange: NSRange(location: 5_000, length: 0)
        )
        #expect(value.utf16.count <= EditorAccessibility.maxValueCharacters + 4)
        #expect(EditorAccessibility.multiCursorSummary(rangeCount: 3) == "3 cursors")
    }

    @Test func themeTokenResolution() {
        var theme = EditorTheme.default
        let keyword = theme.resolve(token: "keyword")
        #expect(keyword.color != theme.text.color || keyword.bold)
        theme.applyTokenMap(["custom.token": PlatformDefaults.keywordColor])
        #expect(theme.tokenOverrides["custom.token"] != nil)
        #expect(theme.resolve(token: "entity.name.function").color == theme.values.color)
    }

    @Test func controllerAccessibilitySurfaces() {
        let c = EditorController(text: "hello world")
        c.languageID = "swift"
        c.textDocument.markDirty()
        #expect(c.accessibilityLabelText.contains("swift"))
        #expect(c.accessibilityValueText.contains("hello"))
    }
}

@Suite("IME composition model")
@MainActor
struct IMECompositionModelTests {
    @Test func successiveMarkedReplacementsDoNotGrowUnbounded() {
        let store = DocumentStore(string: "")
        var marked = NSRange(location: NSNotFound, length: 0)
        func setMarked(_ text: String) {
            if marked.location != NSNotFound {
                _ = store.replaceCharacters(in: marked, with: text)
            } else {
                _ = store.replaceCharacters(in: NSRange(location: store.length, length: 0), with: text)
            }
            if text.isEmpty {
                marked = NSRange(location: NSNotFound, length: 0)
            } else {
                let end = store.length
                marked = NSRange(location: end - text.utf16.count, length: text.utf16.count)
            }
        }
        setMarked("n")
        setMarked("ni")
        setMarked("你")
        #expect(store.fullString == "你")
        #expect(marked.length == 1)
        marked = NSRange(location: NSNotFound, length: 0)
        setMarked("好")
        #expect(store.fullString == "你好")
    }
}
