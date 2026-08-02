import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorCommands

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
    var actionLog: [EditorCommandAction] = []

    func perform(_ action: EditorCommandAction) throws {
        lastAction = action
        actionLog.append(action)
    }
}

@Suite("Phase4 chord state machine")
@MainActor
struct Phase4ChordTests {
    @Test func prefixWaitsForLongerChord() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)

        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.short", title: "Short", action: .indent)
        )
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.long", title: "Long", action: .outdent)
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.short", source: .builtIn)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k, c]), to: "test.chord.long", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        #expect(editor.lastAction == nil)
        #expect(dispatcher.isChordPending)
        #expect(try dispatcher.handleKeyPress(c, context: context) == true)
        #expect(editor.lastAction == .outdent)
    }

    @Test func escapeCancelsPendingChord() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.short2", title: "Short", action: .indent)
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.short2", source: .builtIn)
        _ = dispatcher.keybindings.bind(
            Keybinding(chord: [k, c]), to: "test.chord.short2", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        #expect(try dispatcher.handleKeyPress(KeyPress(key: "escape"), context: context) == true)
        #expect(editor.lastAction == nil)
        #expect(!dispatcher.isChordPending)
    }

    @Test func timeoutExecutesShortBinding() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.timeout", title: "Short", action: .indent)
        )
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.timeout.long", title: "Long", action: .outdent)
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.timeout", source: .builtIn)
        _ = dispatcher.keybindings.bind(
            Keybinding(chord: [k, c]), to: "test.chord.timeout.long", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        #expect(editor.lastAction == nil)
        #expect(dispatcher.isChordPending)
        // Deterministic timeout path (same code as idle timer completion).
        try dispatcher.resolvePendingChordTimeout()
        #expect(editor.lastAction == .indent)
        #expect(!dispatcher.isChordPending)
    }

    @Test func userLayerBeatsBuiltInOnSameChord() {
        let keys = KeybindingRegistry()
        let kb = Keybinding.command("i")
        _ = keys.bind(kb, to: "test.built", source: .builtIn)
        _ = keys.bind(kb, to: "test.user", source: .user)
        let id = keys.resolve(presses: kb.chord, input: ContextEvaluationInput())
        #expect(id?.rawValue == "test.user")
    }
}

@Suite("Phase4 command results and context")
@MainActor
struct Phase4CommandResultTests {
    @Test func notFoundIsTyped() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        let result = try await dispatcher.executeAsync("test.missing.command", context: context)
        #expect(result == .failed("notFound:test.missing.command"))
    }

    @Test func disabledIsTyped() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        editor.isEditable = false
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand(
                id: "test.needs.edit",
                title: "Needs Edit",
                enablement: .editable,
                handler: { _ in }
            )
        )
        let result = try await dispatcher.executeAsync("test.needs.edit", context: context)
        #expect(result == .failed("disabled:test.needs.edit"))
    }

    @Test func contextSnapshotFailClosedDefaults() {
        let snap = CommandContextSnapshot.empty
        #expect(!snap.isEditable)
        #expect(!snap.isFocused)
        #expect(snap.workspaceTrust == "restricted")
        let input = snap.evaluationInput
        #expect(!input.isEditable)
        #expect(input.flags["workspaceRestricted"] == true)
    }

    @Test func contextSnapshotFromEditor() {
        let editor = MockEditor()
        editor.isEditable = true
        editor.isFocused = false
        let snap = CommandContextSnapshot(
            activePart: "editor",
            documentID: editor.documentID,
            languageID: "swift",
            isEditable: editor.isEditable && editor.isFocused,
            isFocused: editor.isFocused,
            hasDocument: true,
            workspaceTrust: "restricted",
            selections: editor.selections
        )
        #expect(!snap.isEditable)  // not focused
        let ctx = CommandContext.make(from: editor, snapshot: snap)
        #expect(!ctx.isEditable)
        #expect(ctx.languageID == "swift")
    }

    @Test func registrationBagRetainsUntilDispose() throws {
        let bag = RegistrationBag()
        let registry = CommandRegistry()
        let token = try registry.register(
            EditorCommand.action(id: "test.bag.cmd", title: "Bag", action: .indent)
        )
        bag.retain(token)
        #expect(registry.command(id: "test.bag.cmd") != nil)
        // Dropping local token reference must not unregister while bag holds it.
        #expect(bag.count == 1)
        bag.disposeAll()
        // Dispose is synchronous (CMD-N03).
        #expect(registry.command(id: "test.bag.cmd") == nil)
        #expect(bag.isDisposed)
    }

    @Test func duplicateRegistrationThrows() throws {
        let registry = CommandRegistry()
        _ = try registry.register(
            EditorCommand.action(id: "test.dup.cmd", title: "A", action: .indent),
            policy: .rejectDuplicate
        )
        #expect(throws: CommandIdentityError.self) {
            _ = try registry.register(
                EditorCommand.action(id: "test.dup.cmd", title: "B", action: .outdent),
                policy: .rejectDuplicate
            )
        }
    }

    /// E12: palette-filtered execute path surfaces typed failures (CMD-004).
    @Test func palettePathExecuteUnknownIsNotFound() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        let palette = CommandPaletteModel(query: "missing")
        let filtered = palette.filteredCommands(from: dispatcher.commands, context: context)
        #expect(filtered.isEmpty)
        let result = try await dispatcher.executeAsync("test.palette.missing.cmd", context: context)
        #expect(result == .failed("notFound:test.palette.missing.cmd"))
    }

    @Test func unsupportedResultIsTyped() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand(
                id: "test.unsupported.cmd",
                title: "U",
                handler: { _ in throw CommandError.unsupported("nope") }
            )
        )
        let result = try await dispatcher.executeAsync("test.unsupported.cmd", context: context)
        #expect(result == .failed("unsupported:nope"))
    }
}
