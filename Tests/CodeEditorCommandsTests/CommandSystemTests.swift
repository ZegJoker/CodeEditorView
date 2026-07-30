import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
@testable import CodeEditorCommands

@Suite("Context expressions")
struct ContextExpressionTests {
    @Test func andOrNotEditable() {
        let input = ContextEvaluationInput(isEditable: true, hasSelection: false)
        #expect(ContextExpressionEvaluator.evaluate(.editable, in: input))
        #expect(!ContextExpressionEvaluator.evaluate(.hasSelection, in: input))
        #expect(ContextExpressionEvaluator.evaluate(.and([.editable, .hasDocument]), in: input))
        #expect(ContextExpressionEvaluator.evaluate(.or([.hasSelection, .editable]), in: input))
        #expect(ContextExpressionEvaluator.evaluate(.not(.hasSelection), in: input))
        #expect(ContextExpressionEvaluator.evaluate(.language("swift"), in: ContextEvaluationInput(languageID: "swift")))
        #expect(ContextExpressionEvaluator.evaluate(.key("completionVisible"), in: ContextEvaluationInput(flags: ["completionVisible": true])))
    }
}

@MainActor
private final class MockEditor: EditorCommandClient {
    var isEditable: Bool = true
    var isFocused: Bool = true
    var selections: [CodeEditorCore.TextRange] = [CodeEditorCore.TextRange(location: 0, length: 0)]
    var snapshot: DocumentSnapshot = DocumentSnapshot(version: .zero, text: "hello")
    var documentID: DocumentID? = DocumentID()
    var sessionID: EditorSessionID? = nil
    var languageID: String? = "swift"
    var contextFlags: [String: Bool] = [:]
    var lastAction: EditorCommandAction?

    func perform(_ action: EditorCommandAction) throws {
        lastAction = action
        if case .indent = action {
            snapshot = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "  hello")
        }
    }
}

@Suite("Command registry and keybindings")
@MainActor
struct CommandRegistryTests {
    @Test func registerAndDispose() {
        let registry = CommandRegistry()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        let token = registry.register(
            EditorCommand.action(id: "test.cmd", title: "Test", action: .indent)
        )
        #expect(registry.command(id: "test.cmd") != nil)
        #expect(registry.enabledCommands(in: context).contains { $0.id.rawValue == "test.cmd" })
        token.dispose()
        // Token dispose is async via Task — call unregister directly for deterministic test.
        registry.unregister(id: "test.cmd")
        #expect(registry.command(id: "test.cmd") == nil)
    }

    @Test func keybindingUserBeatsBuiltIn() {
        let keys = KeybindingRegistry()
        let kb = Keybinding.command("i")
        _ = keys.bind(kb, to: "built.in", source: .builtIn)
        _ = keys.bind(kb, to: "user.cmd", source: .user)
        let id = keys.resolve(presses: kb.chord, input: ContextEvaluationInput())
        #expect(id?.rawValue == "user.cmd")
    }

    @Test func keybindingStableIDTieBreak() {
        let keys = KeybindingRegistry()
        let kb = Keybinding.command("k")
        _ = keys.bind(kb, to: "b.cmd", source: .host, priority: 0)
        _ = keys.bind(kb, to: "a.cmd", source: .host, priority: 0)
        let id = keys.resolve(presses: kb.chord, input: ContextEvaluationInput())
        // Lower string wins on equal source/priority.
        #expect(id?.rawValue == "a.cmd")
    }

    @Test func chordResolves() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = dispatcher.commands.register(
            EditorCommand.action(id: "chord.cmd", title: "Chord", action: .indent)
        )
        let chord = Keybinding(chord: [
            KeyPress(key: "k", modifiers: .command),
            KeyPress(key: "x"),
        ])
        _ = dispatcher.keybindings.bind(chord, to: "chord.cmd", source: .builtIn)

        #expect(try dispatcher.handleKeyPress(chord.chord[0], context: context) == true)
        #expect(editor.lastAction == nil)
        #expect(try dispatcher.handleKeyPress(chord.chord[1], context: context) == true)
        #expect(editor.lastAction == .indent)
    }

    @Test func executeByID() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        _ = dispatcher.commands.register(
            EditorCommand.action(id: BuiltInCommandID.indent, title: "Indent", action: .indent)
        )
        try dispatcher.execute(BuiltInCommandID.indent, context: CommandContext.make(from: editor))
        #expect(editor.lastAction == .indent)
    }

    @Test func paletteFilters() {
        let registry = CommandRegistry()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = registry.register(EditorCommand.action(id: "codeeditor.edit.indent", title: "Indent", action: .indent))
        _ = registry.register(
            EditorCommand.action(
                id: "hidden",
                title: "Secret",
                placement: .hiddenInPalette,
                action: .undo
            )
        )
        let model = CommandPaletteModel(query: "ind")
        let results = model.filteredCommands(from: registry, context: context)
        #expect(results.count == 1)
        #expect(results[0].title == "Indent")
        model.query = "secret"
        #expect(model.filteredCommands(from: registry, context: context).isEmpty)
    }
}
