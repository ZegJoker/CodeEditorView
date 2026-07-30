import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorCommands

// MARK: - EditorCommandClient

extension EditorController: EditorCommandClient {
    public var isFocused: Bool {
        // Hosts may refine; default true when attached.
        true
    }

    public var selections: [CodeEditorCore.TextRange] {
        selectedRanges.map { CodeEditorCore.TextRange($0) }
    }

    public var snapshot: DocumentSnapshot {
        textDocument.snapshot()
    }

    public var documentID: DocumentID? {
        textDocument.id
    }

    public var sessionID: EditorSessionID? {
        session?.id
    }

    public var contextFlags: [String: Bool] {
        [
            "completionVisible": completionsVisible,
            "findVisible": findSession.isShowing,
            "jumpPopoverVisible": isJumpLinkPopoverVisible,
        ]
    }

    public var isEditable: Bool {
        configuration.isEditable
    }

    public func perform(_ action: EditorCommandAction) throws {
        switch action {
        case .undo:
            undo()
        case .redo:
            redo()
        case .indent:
            indentSelection()
        case .outdent:
            outdentSelection()
        case .toggleLineComment:
            toggleLineComment()
        case .toggleBlockComment:
            toggleBlockComment()
        case .moveLines(let up):
            moveSelectedLines(up: up)
        case .selectAll:
            selectAll()
        case .deleteBackward:
            deleteBackward()
        case .deleteForward:
            deleteForward()
        case .insertNewline:
            insertNewline()
        case .insertTab:
            insertTab()
        case .insertBacktab:
            insertBacktab()
        case .showFind:
            showFindPanel(mode: .find)
        case .showReplace:
            showReplacePanel()
        case .findNext:
            findNext()
        case .findPrevious:
            findPrevious()
        case .replaceCurrent:
            replaceCurrentMatch()
        case .replaceAll:
            replaceAllMatches()
        case .showCompletions:
            showCompletions()
        case .hideCompletions:
            hideCompletions()
        case .applyCompletion:
            applyCompletionSelection()
        case .moveCompletion(let delta):
            moveCompletionSelection(delta: delta)
        case .jumpToDefinition:
            jumpToDefinition()
        case .foldToggle:
            if let range = selectedRanges.first,
               let line = layout.lineIndex.line(atUTF16Offset: range.location) {
                toggleFold(atLine: line.index)
            }
        case .foldAll:
            let all = foldModel.folds(in: NSRange(location: 0, length: max(document.length, 1)))
            for fold in all {
                foldModel.setCollapsed(true, forFold: fold)
            }
            rebuildFolds()
            onNeedsDisplay?()
        case .unfoldAll:
            for fold in foldModel.collapsedFolds {
                foldModel.setCollapsed(false, forFold: fold)
            }
            selectedFoldPlaceholderID = nil
            rebuildFolds()
            onNeedsDisplay?()
        case .collapseCursors:
            collapseCursors()
        case .cancel:
            if findSession.isShowing {
                hideFindPanel()
            } else if completionsVisible {
                hideCompletions()
            } else if isJumpLinkPopoverVisible {
                hideCompletions()
            } else {
                collapseCursors()
            }
        }
    }
}

// MARK: - Built-in registration

extension EditorController {
    /// Installs built-in commands and default keybindings into `dispatcher`.
    ///
    /// Safe to call once after creating the controller. Returns a disposable that
    /// removes all built-in registrations.
    @discardableResult
    public func installBuiltInCommands(into dispatcher: CommandDispatcher) -> any CommandDisposable {
        var tokens: [any CommandDisposable] = []

        func reg(
            _ id: CommandID,
            _ title: String,
            category: CommandCategory,
            keys: [Keybinding] = [],
            enablement: ContextExpression = .editable,
            placement: CommandPlacement = .default,
            action: EditorCommandAction
        ) {
            let command = EditorCommand.action(
                id: id,
                title: title,
                category: category,
                defaultKeybindings: keys,
                enablement: enablement,
                placement: placement,
                action: action
            )
            tokens.append(dispatcher.commands.register(command))
            for kb in keys {
                tokens.append(
                    dispatcher.keybindings.bind(kb, to: id, source: .builtIn)
                )
            }
        }

        // Edit
        reg(BuiltInCommandID.undo, "Undo", category: .edit,
            keys: [.command("z")], action: .undo)
        reg(BuiltInCommandID.redo, "Redo", category: .edit,
            keys: [Keybinding(key: "z", modifiers: [.command, .shift])], action: .redo)
        reg(BuiltInCommandID.indent, "Indent", category: .edit,
            keys: [.command("]")], action: .indent)
        reg(BuiltInCommandID.outdent, "Outdent", category: .edit,
            keys: [.command("[")], action: .outdent)
        reg(BuiltInCommandID.toggleLineComment, "Toggle Line Comment", category: .edit,
            keys: [.command("/")], action: .toggleLineComment)
        reg(BuiltInCommandID.toggleBlockComment, "Toggle Block Comment", category: .edit,
            keys: [Keybinding(key: "/", modifiers: [.command, .shift])], action: .toggleBlockComment)
        reg(BuiltInCommandID.moveLinesUp, "Move Line Up", category: .edit,
            keys: [Keybinding(key: "up", modifiers: .option)], action: .moveLines(up: true))
        reg(BuiltInCommandID.moveLinesDown, "Move Line Down", category: .edit,
            keys: [Keybinding(key: "down", modifiers: .option)], action: .moveLines(up: false))
        reg(BuiltInCommandID.selectAll, "Select All", category: .edit,
            keys: [.command("a")], enablement: .always, action: .selectAll)
        reg(BuiltInCommandID.deleteBackward, "Delete Backward", category: .edit,
            keys: [Keybinding(key: "backspace")], placement: .hiddenInPalette, action: .deleteBackward)
        reg(BuiltInCommandID.deleteForward, "Delete Forward", category: .edit,
            keys: [Keybinding(key: "delete")], placement: .hiddenInPalette, action: .deleteForward)
        reg(BuiltInCommandID.insertNewline, "New Line", category: .edit,
            keys: [Keybinding(key: "return", when: .not(.key("completionVisible")))],
            placement: .hiddenInPalette, action: .insertNewline)
        reg(BuiltInCommandID.insertTab, "Insert Tab", category: .edit,
            keys: [Keybinding(key: "tab")], placement: .hiddenInPalette, action: .insertTab)
        reg(BuiltInCommandID.insertBacktab, "Insert Backtab", category: .edit,
            keys: [Keybinding(key: "tab", modifiers: .shift)], placement: .hiddenInPalette, action: .insertBacktab)

        // Find
        reg(BuiltInCommandID.findShow, "Find", category: .find,
            keys: [.command("f")], enablement: .always, action: .showFind)
        reg(BuiltInCommandID.findShowReplace, "Find and Replace", category: .find,
            keys: [
                Keybinding(key: "f", modifiers: [.command, .option]),
                Keybinding(key: "r", modifiers: .command),
            ],
            enablement: .always, action: .showReplace)
        reg(BuiltInCommandID.findNext, "Find Next", category: .find,
            keys: [.command("g")], enablement: .always, action: .findNext)
        reg(BuiltInCommandID.findPrevious, "Find Previous", category: .find,
            keys: [Keybinding(key: "g", modifiers: [.command, .shift])],
            enablement: .always, action: .findPrevious)
        reg(BuiltInCommandID.findReplace, "Replace", category: .find,
            enablement: .and([.editable, .key("findVisible")]), action: .replaceCurrent)
        reg(BuiltInCommandID.findReplaceAll, "Replace All", category: .find,
            enablement: .and([.editable, .key("findVisible")]), action: .replaceAll)

        // Completion
        reg(BuiltInCommandID.completionShow, "Show Completions", category: .edit,
            keys: [Keybinding(key: "space", modifiers: .control)],
            enablement: .always, action: .showCompletions)
        reg(BuiltInCommandID.completionHide, "Hide Completions", category: .edit,
            enablement: .key("completionVisible"), placement: .hiddenInPalette, action: .hideCompletions)
        reg(BuiltInCommandID.completionApply, "Apply Completion", category: .edit,
            keys: [Keybinding(key: "return", when: .key("completionVisible"))],
            enablement: .key("completionVisible"), placement: .hiddenInPalette, action: .applyCompletion)
        reg(BuiltInCommandID.completionUp, "Completion Up", category: .edit,
            keys: [Keybinding(key: "up", when: .key("completionVisible"))],
            enablement: .key("completionVisible"), placement: .hiddenInPalette,
            action: .moveCompletion(delta: -1))
        reg(BuiltInCommandID.completionDown, "Completion Down", category: .edit,
            keys: [Keybinding(key: "down", when: .key("completionVisible"))],
            enablement: .key("completionVisible"), placement: .hiddenInPalette,
            action: .moveCompletion(delta: 1))

        // Navigate / fold
        reg(BuiltInCommandID.jumpToDefinition, "Jump to Definition", category: .navigate,
            keys: [Keybinding(key: "j", modifiers: [.command, .control])],
            enablement: .always, action: .jumpToDefinition)
        reg(BuiltInCommandID.foldToggle, "Toggle Fold", category: .view, action: .foldToggle)
        reg(BuiltInCommandID.foldAll, "Fold All", category: .view, action: .foldAll)
        reg(BuiltInCommandID.unfoldAll, "Unfold All", category: .view, action: .unfoldAll)

        // Cancel / Escape
        reg(BuiltInCommandID.cancel, "Cancel", category: .general,
            keys: [Keybinding(key: "escape")],
            enablement: .always, placement: .hiddenInPalette, action: .cancel)

        commandDispatcher = dispatcher
        return RegistrationToken {
            for token in tokens { token.dispose() }
        }
    }

    /// Builds a ``CommandContext`` for the current controller state.
    public func makeCommandContext(services: CommandServiceLocator = CommandServiceLocator()) -> CommandContext {
        CommandContext.make(from: self, services: services)
    }

    /// Executes a command by ID using this controller as the client.
    public func executeCommand(_ id: CommandID) throws {
        let dispatcher = commandDispatcher ?? {
            let d = CommandDispatcher()
            _ = installBuiltInCommands(into: d)
            return d
        }()
        try dispatcher.execute(id, context: makeCommandContext())
    }
}
