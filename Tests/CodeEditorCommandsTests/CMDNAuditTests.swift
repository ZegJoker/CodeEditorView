import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorCommands

// MARK: - Test doubles

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
    var performError: Error?

    func perform(_ action: EditorCommandAction) throws {
        if let performError { throw performError }
        lastAction = action
    }
}

@MainActor
private func makeCommand(
    id: CommandID,
    title: String = "T",
    enablement: ContextExpression = .always,
    executionClass: CommandExecutionClass = .immediateUI,
    handler: @escaping (CommandContext) throws -> Void = { _ in }
) -> EditorCommand {
    EditorCommand(
        id: id,
        title: title,
        enablement: enablement,
        executionClass: executionClass,
        handler: handler
    )
}

// MARK: - CMD-N01

@Suite("CMD-N01 registration policy")
@MainActor
struct CMDN01RegistrationPolicyTests {
    @Test func test_CMD_N01_defaultPolicyRejectsDuplicate() throws {
        let registry = CommandRegistry()
        let first = try registry.register(makeCommand(id: "test.cmd.n01.a", title: "A") { _ in })
        #expect(first.id != UUID()) // token has stable ID type
        #expect(throws: CommandIdentityError.duplicateRegistration("test.cmd.n01.a")) {
            _ = try registry.register(makeCommand(id: "test.cmd.n01.a", title: "B") { _ in })
        }
        // Original handler remains.
        #expect(registry.command(id: "test.cmd.n01.a")?.title == "A")
        first.dispose()
    }

    @Test func test_CMD_N01_softRegisterConvenienceRemovedOrRejects() throws {
        let registry = CommandRegistry()
        _ = try registry.register(makeCommand(id: "test.cmd.n01.soft", title: "A") { _ in })
        // Public API must not silently replace: only throwing policy-based register.
        #expect(throws: CommandIdentityError.self) {
            _ = try registry.register(
                makeCommand(id: "test.cmd.n01.soft", title: "B") { _ in },
                policy: .rejectDuplicate
            )
        }
        #expect(registry.command(id: "test.cmd.n01.soft")?.title == "A")
    }

    @Test func test_CMD_N01_replaceOwnedRequiresMatchingToken() throws {
        let registry = CommandRegistry()
        let token = try registry.register(makeCommand(id: "test.cmd.n01.own", title: "A") { _ in })
        #expect(throws: CommandIdentityError.self) {
            _ = try registry.register(
                makeCommand(id: "test.cmd.n01.own", title: "B") { _ in },
                policy: .replaceOwnedRegistration(expectedToken: UUID())
            )
        }
        #expect(registry.command(id: "test.cmd.n01.own")?.title == "A")

        let replacement = try registry.register(
            makeCommand(id: "test.cmd.n01.own", title: "B") { _ in },
            policy: .replaceOwnedRegistration(expectedToken: token.id)
        )
        #expect(registry.command(id: "test.cmd.n01.own")?.title == "B")
        // Old token must not unregister the replacement.
        token.dispose()
        #expect(registry.command(id: "test.cmd.n01.own")?.title == "B")
        replacement.dispose()
        #expect(registry.command(id: "test.cmd.n01.own") == nil)
    }

    @Test func test_CMD_N01_replaceOwnedEmitsDiagnostic() throws {
        let registry = CommandRegistry()
        var diagnostics: [CommandRegistrationDiagnostic] = []
        registry.onRegistrationDiagnostic = { diagnostics.append($0) }
        let token = try registry.register(makeCommand(id: "test.cmd.n01.diag", title: "A") { _ in })
        _ = try registry.register(
            makeCommand(id: "test.cmd.n01.diag", title: "B") { _ in },
            policy: .replaceOwnedRegistration(expectedToken: token.id)
        )
        #expect(diagnostics.contains { diag in
            if case .replacedOwnedRegistration(let id, _) = diag {
                return id.rawValue == "test.cmd.n01.diag"
            }
            return false
        })
    }
}

// MARK: - CMD-N02

@Suite("CMD-N02 CommandID grammar")
struct CMDN02CommandIDGrammarTests {
    @Test func test_CMD_N02_rejectsUppercase() {
        #expect(CommandID(rawValue: "Test.cmd") == nil)
        #expect(CommandID(rawValue: "test.Cmd") == nil)
        #expect(CommandID(rawValue: "codeeditor.edit.toggleLineComment") == nil)
        #expect(throws: CommandIdentityError.invalidID("Foo.bar")) {
            _ = try CommandID(validating: "Foo.bar")
        }
    }

    @Test func test_CMD_N02_acceptsRecommendedGrammar() {
        #expect(CommandID(rawValue: "a") != nil)
        #expect(CommandID(rawValue: "codeeditor.edit.indent") != nil)
        #expect(CommandID(rawValue: "ext.my-command") != nil)
        #expect(CommandID(rawValue: "a1.b2.c3") != nil)
        #expect(CommandID(rawValue: "host.cmd-name.v2") != nil)
    }

    @Test func test_CMD_N02_rejectsInvalidCharsetAndLength() {
        #expect(CommandID(rawValue: "") == nil)
        #expect(CommandID(rawValue: "1abc") == nil)
        #expect(CommandID(rawValue: "test_cmd.x") == nil) // underscore not in recommended grammar
        #expect(CommandID(rawValue: "test..x") == nil)
        #expect(CommandID(rawValue: ".test") == nil)
        #expect(CommandID(rawValue: "test.") == nil)
        #expect(CommandID(rawValue: String(repeating: "a", count: 201)) == nil)
        #expect(CommandID(rawValue: String(repeating: "a", count: 200)) != nil)
    }

    @Test func test_CMD_N02_reservedHostNamespaces() {
        #expect(CommandID.isReservedHostNamespace("codeeditor.edit.indent"))
        #expect(CommandID.isReservedHostNamespace("codeeditor"))
        #expect(!CommandID.isReservedHostNamespace("myext.cmd"))
        #expect(CommandID.reservedHostNamespacePrefixes.contains("codeeditor"))
    }
}

// MARK: - CMD-N03

@Suite("CMD-N03 explicit dispose")
@MainActor
struct CMDN03ExplicitDisposeTests {
    @Test func test_CMD_N03_disposeUnregistersSynchronously() throws {
        let registry = CommandRegistry()
        let token = try registry.register(makeCommand(id: "test.cmd.n03.sync") { _ in })
        #expect(registry.command(id: "test.cmd.n03.sync") != nil)
        token.dispose()
        // Must be gone immediately — no unstructured Task race.
        #expect(registry.command(id: "test.cmd.n03.sync") == nil)
    }

    @Test func test_CMD_N03_tokenDeinitDoesNotScheduleUnregister() async throws {
        let registry = CommandRegistry()
        var token: CommandRegistrationToken? = try registry.register(
            makeCommand(id: "test.cmd.n03.leak") { _ in }
        )
        #expect(registry.command(id: "test.cmd.n03.leak") != nil)
        // Drop without dispose — deinit must not unregister via Task.
        token = nil
        // Yield enough that a former unstructured Task would have run.
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(registry.command(id: "test.cmd.n03.leak") != nil)
        // Explicit cleanup for the suite.
        registry.unregister(id: "test.cmd.n03.leak")
        #expect(token == nil)
    }

    @Test func test_CMD_N03_keybindingDisposeIsSynchronous() {
        let keys = KeybindingRegistry()
        let token = keys.bind(Keybinding.command("x"), to: "test.cmd.n03.kb", source: .user)
        #expect(keys.resolve(presses: [KeyPress(key: "x", modifiers: .command)], input: ContextEvaluationInput()) != nil)
        token.dispose()
        #expect(keys.resolve(presses: [KeyPress(key: "x", modifiers: .command)], input: ContextEvaluationInput()) == nil)
    }
}

// MARK: - CMD-N04

@Suite("CMD-N04 chord timeout context")
@MainActor
struct CMDN04ChordTimeoutTests {
    @Test func test_CMD_N04_timeoutReResolvesContextAndRespectsEnablement() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        editor.isEditable = true
        let context = CommandContext.make(from: editor)

        _ = try dispatcher.commands.register(
            EditorCommand.action(
                id: "test.chord.n04.short",
                title: "Short",
                enablement: .editable,
                action: .indent
            )
        )
        _ = try dispatcher.commands.register(
            EditorCommand.action(
                id: "test.chord.n04.long",
                title: "Long",
                action: .outdent
            )
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.n04.short", source: .builtIn)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k, c]), to: "test.chord.n04.long", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        #expect(dispatcher.isChordPending)
        // Focus/editability changes before timeout.
        editor.isEditable = false
        #expect(throws: CommandError.disabled("test.chord.n04.short")) {
            try dispatcher.resolvePendingChordTimeout()
        }
        #expect(editor.lastAction == nil)
        #expect(!dispatcher.isChordPending)
    }

    @Test func test_CMD_N04_timeoutSurfacesExecutionErrors() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        var failures: [(CommandID, String)] = []
        dispatcher.onCommandFailure = { id, error in
            failures.append((id, String(describing: error)))
        }

        _ = try dispatcher.commands.register(
            makeCommand(id: "test.chord.n04.fail") { _ in
                throw CommandError.unsupported("boom")
            }
        )
        _ = try dispatcher.commands.register(makeCommand(id: "test.chord.n04.fail.long") { _ in })
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.n04.fail", source: .builtIn)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k, c]), to: "test.chord.n04.fail.long", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        #expect(throws: CommandError.unsupported("boom")) {
            try dispatcher.resolvePendingChordTimeout()
        }
        #expect(failures.count == 1)
        #expect(failures[0].0.rawValue == "test.chord.n04.fail")
    }

    @Test func test_CMD_N04_timeoutCancelsWhenFocusScopeChanges() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let sessionA = EditorSessionID()
        let sessionB = EditorSessionID()
        editor.sessionID = sessionA
        let context = CommandContext.make(from: editor)

        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.n04.scope", title: "S", action: .indent)
        )
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.n04.scope.long", title: "L", action: .outdent)
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.n04.scope", source: .builtIn)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k, c]), to: "test.chord.n04.scope.long", source: .user)

        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        editor.sessionID = sessionB
        try dispatcher.resolvePendingChordTimeout()
        #expect(editor.lastAction == nil)
        #expect(!dispatcher.isChordPending)
    }

    @Test func test_CMD_N04_contextChangeClearsPendingChord() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand.action(id: "test.chord.n04.clear", title: "S", action: .indent)
        )
        let k = KeyPress(key: "k", modifiers: .command)
        let c = KeyPress(key: "c", modifiers: .command)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k]), to: "test.chord.n04.clear", source: .builtIn)
        _ = dispatcher.keybindings.bind(Keybinding(chord: [k, c]), to: "test.chord.n04.clear", source: .user)
        #expect(try dispatcher.handleKeyPress(k, context: context) == true)
        dispatcher.clearChordOnContextChange()
        #expect(!dispatcher.isChordPending)
        #expect(editor.lastAction == nil)
    }
}

// MARK: - CMD-N05

@Suite("CMD-N05 execution class")
@MainActor
struct CMDN05ExecutionClassTests {
    @Test func test_CMD_N05_syncExecuteRejectsLongRunning() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        var ran = false
        _ = try dispatcher.commands.register(
            makeCommand(
                id: "test.cmd.n05.long",
                executionClass: .longRunningCancellable
            ) { _ in ran = true }
        )
        #expect(throws: CommandError.self) {
            try dispatcher.execute("test.cmd.n05.long", context: context)
        }
        #expect(!ran)
    }

    @Test func test_CMD_N05_syncExecuteRejectsAsynchronousClass() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand(
                id: "test.cmd.n05.async",
                title: "A",
                executionClass: .asynchronous,
                asyncHandler: { _ in .success }
            )
        )
        #expect(throws: CommandError.requiresAsyncExecution("test.cmd.n05.async")) {
            try dispatcher.execute("test.cmd.n05.async", context: context)
        }
    }

    @Test func test_CMD_N05_executeAsyncRunsLongRunningOffSyncPath() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        var ran = false
        _ = try dispatcher.commands.register(
            EditorCommand(
                id: "test.cmd.n05.asyncok",
                title: "L",
                executionClass: .longRunningCancellable,
                asyncHandler: { _ in
                    ran = true
                    return .success
                }
            )
        )
        let result = try await dispatcher.executeAsync("test.cmd.n05.asyncok", context: context)
        #expect(result == .success)
        #expect(ran)
    }

    @Test func test_CMD_N05_longRunningWithoutAsyncHandlerFailsClosed() async throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        var ran = false
        _ = try dispatcher.commands.register(
            makeCommand(
                id: "test.cmd.n05.noasync",
                executionClass: .longRunningCancellable
            ) { _ in ran = true }
        )
        let result = try await dispatcher.executeAsync("test.cmd.n05.noasync", context: context)
        #expect(result == .failed("requiresAsyncHandler:test.cmd.n05.noasync"))
        #expect(!ran)
    }

    @Test func test_CMD_N05_immediateUIStillRunsSynchronously() throws {
        let dispatcher = CommandDispatcher()
        let editor = MockEditor()
        let context = CommandContext.make(from: editor)
        _ = try dispatcher.commands.register(
            EditorCommand.action(
                id: "test.cmd.n05.ui",
                title: "UI",
                executionClass: .immediateUI,
                action: .indent
            )
        )
        try dispatcher.execute("test.cmd.n05.ui", context: context)
        #expect(editor.lastAction == .indent)
    }
}
