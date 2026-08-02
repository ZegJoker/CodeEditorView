import Foundation

/// Built-in command identifiers (`codeeditor.*` host namespace, lowercase grammar CMD-N02).
public enum BuiltInCommandID {
    public static let undo = CommandID(stringLiteral: "codeeditor.edit.undo")
    public static let redo = CommandID(stringLiteral: "codeeditor.edit.redo")
    public static let indent = CommandID(stringLiteral: "codeeditor.edit.indent")
    public static let outdent = CommandID(stringLiteral: "codeeditor.edit.outdent")
    public static let toggleLineComment = CommandID(stringLiteral: "codeeditor.edit.toggle-line-comment")
    public static let toggleBlockComment = CommandID(stringLiteral: "codeeditor.edit.toggle-block-comment")
    public static let moveLinesUp = CommandID(stringLiteral: "codeeditor.edit.move-lines-up")
    public static let moveLinesDown = CommandID(stringLiteral: "codeeditor.edit.move-lines-down")
    public static let selectAll = CommandID(stringLiteral: "codeeditor.edit.select-all")
    public static let deleteBackward = CommandID(stringLiteral: "codeeditor.edit.delete-backward")
    public static let deleteForward = CommandID(stringLiteral: "codeeditor.edit.delete-forward")
    public static let insertNewline = CommandID(stringLiteral: "codeeditor.edit.insert-newline")
    public static let insertTab = CommandID(stringLiteral: "codeeditor.edit.insert-tab")
    public static let insertBacktab = CommandID(stringLiteral: "codeeditor.edit.insert-backtab")

    public static let findShow = CommandID(stringLiteral: "codeeditor.find.show")
    public static let findShowReplace = CommandID(stringLiteral: "codeeditor.find.show-replace")
    public static let findNext = CommandID(stringLiteral: "codeeditor.find.next")
    public static let findPrevious = CommandID(stringLiteral: "codeeditor.find.previous")
    public static let findReplace = CommandID(stringLiteral: "codeeditor.find.replace")
    public static let findReplaceAll = CommandID(stringLiteral: "codeeditor.find.replace-all")

    public static let completionShow = CommandID(stringLiteral: "codeeditor.completion.show")
    public static let completionHide = CommandID(stringLiteral: "codeeditor.completion.hide")
    public static let completionApply = CommandID(stringLiteral: "codeeditor.completion.apply")
    public static let completionUp = CommandID(stringLiteral: "codeeditor.completion.up")
    public static let completionDown = CommandID(stringLiteral: "codeeditor.completion.down")

    public static let jumpToDefinition = CommandID(stringLiteral: "codeeditor.navigate.jump-to-definition")
    public static let foldToggle = CommandID(stringLiteral: "codeeditor.fold.toggle")
    public static let foldAll = CommandID(stringLiteral: "codeeditor.fold.fold-all")
    public static let unfoldAll = CommandID(stringLiteral: "codeeditor.fold.unfold-all")
    public static let cancel = CommandID(stringLiteral: "codeeditor.general.cancel")
}
