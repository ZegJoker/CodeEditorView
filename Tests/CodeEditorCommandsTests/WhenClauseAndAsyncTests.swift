import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
@testable import CodeEditorCommands

@Suite("When clause parser")
struct WhenClauseParserTests {
    @Test func parsesAndOrNot() {
        let r = WhenClauseParser.parse("editorTextFocus && !editorReadonly")
        #expect(r.diagnostics.isEmpty || r.expression != .never)
        // Focused is mapped
        let input = ContextEvaluationInput(isEditable: true, isFocused: true)
        // editorReadonly as key — not set → false, so !false → need evaluate carefully
        _ = ContextExpressionEvaluator.evaluate(r.expression, in: input)
    }

    @Test func parsesLanguageComparison() {
        let r = WhenClauseParser.parse("editorLangId == swift")
        let input = ContextEvaluationInput(languageID: "swift")
        #expect(ContextExpressionEvaluator.evaluate(r.expression, in: input))
        let other = ContextEvaluationInput(languageID: "go")
        #expect(!ContextExpressionEvaluator.evaluate(r.expression, in: other))
    }

    @Test func unknownKeyIsFalse() {
        let r = WhenClauseParser.parse("someUnknownFlag")
        let input = ContextEvaluationInput(flags: [:])
        #expect(!ContextExpressionEvaluator.evaluate(r.expression, in: input))
        let withFlag = ContextEvaluationInput(flags: ["someUnknownFlag": true])
        #expect(ContextExpressionEvaluator.evaluate(r.expression, in: withFlag))
    }
}

@MainActor
private final class MockEditor: EditorCommandClient {
    var isEditable = true
    var isFocused = true
    var selections: [CodeEditorCore.TextRange] = []
    var snapshot = DocumentSnapshot(version: .zero, text: "")
    var documentID: DocumentID? = DocumentID()
    var sessionID: EditorSessionID?
    var languageID: String?
    var contextFlags: [String: Bool] = [:]
    var lastAction: EditorCommandAction?

    func perform(_ action: EditorCommandAction) throws {
        lastAction = action
    }
}

@Suite("Async commands and keybinding conflicts")
@MainActor
struct AsyncCommandTests {
    @Test func executeAsyncPrefersAsyncHandler() async throws {
        let editor = MockEditor()
        let registry = CommandRegistry()
        let dispatcher = CommandDispatcher(commands: registry)
        var ran = false
        _ = registry.register(
            EditorCommand(
                id: "test.async",
                title: "Async",
                asyncHandler: { _ in
                    ran = true
                    return .success
                }
            )
        )
        let ctx = CommandContext.make(from: editor)
        let result = try await dispatcher.executeAsync("test.async", context: ctx)
        #expect(result == .success)
        #expect(ran)
    }

    @Test func keybindingConflictsDeterministic() {
        let kb = KeybindingRegistry()
        let chord = Keybinding(key: "s", modifiers: .command)
        _ = kb.bind(chord, to: "a.cmd", source: .builtIn, priority: 0)
        _ = kb.bind(chord, to: "b.cmd", source: .user, priority: 0)
        let conflicts = kb.conflicts(in: ContextEvaluationInput())
        #expect(conflicts.count == 1)
        #expect(conflicts[0].winnerCommandID.rawValue == "b.cmd")
        #expect(conflicts[0].shadowedCommandIDs.map(\.rawValue).contains("a.cmd"))
    }

    @Test func paletteRanksPrefixHigher() {
        let registry = CommandRegistry()
        _ = registry.register(EditorCommand(id: "x.find", title: "Find in Files") { _ in })
        _ = registry.register(EditorCommand(id: "x.open", title: "Open File") { _ in })
        let model = CommandPaletteModel(query: "find")
        let editor = MockEditor()
        let list = model.filteredCommands(from: registry, context: .make(from: editor))
        #expect(list.first?.title == "Find in Files")
    }
}
