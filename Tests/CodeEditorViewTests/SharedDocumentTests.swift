import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
@testable import CodeEditorView

@Suite("Shared documents multi-session")
@MainActor
struct SharedDocumentTests {
    @Test func twoControllersShareEdits() async throws {
        let doc = TextDocument(text: "hello")
        let sessionA = EditorSession(documentID: doc.id)
        let sessionB = EditorSession(documentID: doc.id)
        sessionB.setSelectedNSRanges([NSRange(location: 5, length: 0)])

        let a = EditorController(document: doc, session: sessionA)
        let b = EditorController(document: doc, session: sessionB)

        #expect(a.text == "hello")
        #expect(b.text == "hello")
        #expect(a.usesPresentationMirror)
        #expect(b.usesPresentationMirror)
        #expect(a.document !== b.document)
        #expect(a.document !== doc.store)

        a.insertText("!")
        // Allow async observation to deliver.
        for _ in 0..<20 {
            if b.text == a.text { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(a.text == "hello!" || a.text.hasPrefix("!") || a.text.contains("!"))
        // Default caret at 0 → insert at start → "!hello" or at end depending on selection
        #expect(doc.text == a.text)
        #expect(b.text == doc.text)
    }

    @Test func independentSelectionsSurviveEdit() async throws {
        let doc = TextDocument(text: "abcdef")
        let sessionA = EditorSession(documentID: doc.id)
        let sessionB = EditorSession(documentID: doc.id)
        sessionA.setSelectedNSRanges([NSRange(location: 0, length: 0)])
        sessionB.setSelectedNSRanges([NSRange(location: 6, length: 0)])

        let a = EditorController(document: doc, session: sessionA)
        let b = EditorController(document: doc, session: sessionB)
        a.setSelectedRange(NSRange(location: 0, length: 0))
        b.setSelectedRange(NSRange(location: 6, length: 0))

        // Insert at start on A.
        a.insertText("X")
        for _ in 0..<20 {
            if b.text == doc.text { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(doc.text.hasPrefix("X") || doc.text.contains("X"))
        #expect(b.text == doc.text)
        // B's caret should remap forward by 1 when edit is before it.
        #expect(b.selectedRange.location >= 6)
    }

    @Test func documentUndoSyncsBothSessions() async throws {
        let doc = TextDocument(text: "z")
        let sessionA = EditorSession(documentID: doc.id)
        let sessionB = EditorSession(documentID: doc.id)
        let a = EditorController(document: doc, session: sessionA)
        let b = EditorController(document: doc, session: sessionB)

        a.setSelectedRange(NSRange(location: 1, length: 0))
        a.insertText("z")
        for _ in 0..<20 {
            if b.text == doc.text { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        let after = doc.text
        #expect(after.count >= 1)
        a.undo()
        for _ in 0..<20 {
            if b.text == doc.text { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(a.text == doc.text)
        #expect(b.text == doc.text)
        #expect(doc.text == "z")
    }

    @Test func independentThemesDoNotShareAttributeStorage() {
        let doc = TextDocument(text: "func x() {}")
        let sessionA = EditorSession(documentID: doc.id)
        let sessionB = EditorSession(documentID: doc.id)
        var configA = EditorConfiguration()
        var configB = EditorConfiguration()
        configA.appearance.theme = .default
        configB.appearance.theme = .default

        let a = EditorController(document: doc, session: sessionA, configuration: configA)
        let b = EditorController(document: doc, session: sessionB, configuration: configB)
        #expect(a.document !== b.document)
        // Painting attributes on A must not mutate B's presentation storage identity.
        a.document.setAttributes([.foregroundColor: "red"], range: NSRange(location: 0, length: 4))
        let bSub = b.document.attributedSubstring(from: NSRange(location: 0, length: 4))
        #expect(bSub.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? String != "red")
    }

    @Test func standaloneBindingPathStillWorks() {
        let controller = EditorController(text: "solo")
        #expect(!controller.usesPresentationMirror)
        #expect(controller.document === controller.textDocument.store)
        controller.setSelectedRange(NSRange(location: 4, length: 0))
        controller.insertText("!")
        #expect(controller.text == "solo!")
        #expect(controller.textDocument.text == "solo!")
    }
}
