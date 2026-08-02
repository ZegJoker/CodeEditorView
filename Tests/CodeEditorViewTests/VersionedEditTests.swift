import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Versioned editor events")
@MainActor
struct VersionedEditTests {
    @Test func replaceEmitsWillAndDidApplyWithMatchingVersions() async {
        let controller = EditorController(text: "hello")
        var events: [EditorEvent] = []
        let stream = controller.editorEvents
        let collector = Task {
            for await event in stream {
                events.append(event)
                // Funnel yields didApply then textDidChange; wait for the legacy did-change.
                if case .textDidChange = event { break }
            }
        }

        // Let the stream subscribe.
        await Task.yield()
        controller.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        _ = await collector.result

        var sawWill = false
        var sawDid = false
        for event in events {
            switch event {
            case .willApplyEdit(let tx, let snap):
                sawWill = true
                #expect(snap.version < controller.document.version)
                #expect(tx.changes.count == 1)
                #expect(snap.text == "hello")
            case .didApplyEdit(let applied):
                sawDid = true
                #expect(applied.oldVersion.rawValue + 1 == applied.newVersion.rawValue)
                #expect(applied.newVersion == controller.document.version)
                #expect(controller.text == "hello!")
            default:
                break
            }
        }
        #expect(sawWill)
        #expect(sawDid)
        #expect(events.contains(.willChangeText))
        #expect(events.contains(.textDidChange))
    }

    @Test func multiCursorInsertIsOneVersionBump() {
        let controller = EditorController(text: "ab")
        controller.setSelectedRanges([
            NSRange(location: 0, length: 0),
            NSRange(location: 2, length: 0),
        ])
        let before = controller.document.version
        controller.insertText("x")
        #expect(controller.document.version == before.advanced())
        // Carets at 0 and 2 high→low: insert at 2 then 0 → "xabx"
        #expect(controller.text == "xabx")
    }

    @Test func undoAdvancesVersionMonotonically() {
        let controller = EditorController(text: "a")
        controller.setSelectedRange(NSRange(location: 1, length: 0))
        controller.insertText("b")
        #expect(controller.text == "ab")
        let afterInsert = controller.document.version
        controller.undo()
        #expect(controller.text == "a")
        #expect(controller.document.version > afterInsert)
    }

    final class RecordingObserver: EditorLifecycleObserver {
        var willCount = 0
        var didCount = 0
        var lastOld: DocumentVersion?
        var lastNew: DocumentVersion?

        func editorWillApply(_ transaction: EditTransaction, snapshot: DocumentSnapshot) {
            willCount += 1
        }

        func editorDidApply(_ result: AppliedEditTransaction) {
            didCount += 1
            lastOld = result.oldVersion
            lastNew = result.newVersion
        }
    }

    @Test func lifecycleObserverReceivesApplyCallbacks() {
        let controller = EditorController(text: "z")
        let observer = RecordingObserver()
        controller.setLifecycleObservers([observer])
        controller.insertText("!")
        #expect(observer.willCount == 1)
        #expect(observer.didCount == 1)
        #expect(observer.lastOld != nil)
        #expect(observer.lastNew == controller.document.version)
    }
}
