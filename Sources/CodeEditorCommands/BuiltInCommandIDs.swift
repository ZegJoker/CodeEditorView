import Foundation

/// Built-in command identifiers (`codeeditor.*` namespace).
public enum BuiltInCommandID {
    public static let undo = CommandID(stringLiteral: "codeeditor.edit.undo")
    public static let redo = CommandID(stringLiteral: "codeeditor.edit.redo")
    public static let indent = CommandID(stringLiteral: "codeeditor.edit.indent")
    public static let outdent = CommandID(stringLiteral: "codeeditor.edit.outdent")
    public static let toggleLineComment = CommandID(stringLiteral: "codeeditor.edit.toggleLineComment")
    public static let toggleBlockComment = CommandID(stringLiteral: "codeeditor.edit.toggleBlockComment")
    public static let moveLinesUp = CommandID(stringLiteral: "codeeditor.edit.moveLinesUp")
    public static let moveLinesDown = CommandID(stringLiteral: "codeeditor.edit.moveLinesDown")
    public static let selectAll = CommandID(stringLiteral: "codeeditor.edit.selectAll")
    public static let deleteBackward = CommandID(stringLiteral: "codeeditor.edit.deleteBackward")
    public static let deleteForward = CommandID(stringLiteral: "codeeditor.edit.deleteForward")
    public static let insertNewline = CommandID(stringLiteral: "codeeditor.edit.insertNewline")
    public static let insertTab = CommandID(stringLiteral: "codeeditor.edit.insertTab")
    public static let insertBacktab = CommandID(stringLiteral: "codeeditor.edit.insertBacktab")

    public static let findShow = CommandID(stringLiteral: "codeeditor.find.show")
    public static let findShowReplace = CommandID(stringLiteral: "codeeditor.find.showReplace")
    public static let findNext = CommandID(stringLiteral: "codeeditor.find.next")
    public static let findPrevious = CommandID(stringLiteral: "codeeditor.find.previous")
    public static let findReplace = CommandID(stringLiteral: "codeeditor.find.replace")
    public static let findReplaceAll = CommandID(stringLiteral: "codeeditor.find.replaceAll")

    public static let completionShow = CommandID(stringLiteral: "codeeditor.completion.show")
    public static let completionHide = CommandID(stringLiteral: "codeeditor.completion.hide")
    public static let completionApply = CommandID(stringLiteral: "codeeditor.completion.apply")
    public static let completionUp = CommandID(stringLiteral: "codeeditor.completion.up")
    public static let completionDown = CommandID(stringLiteral: "codeeditor.completion.down")

    public static let jumpToDefinition = CommandID(stringLiteral: "codeeditor.navigate.jumpToDefinition")
    public static let foldToggle = CommandID(stringLiteral: "codeeditor.fold.toggle")
    public static let foldAll = CommandID(stringLiteral: "codeeditor.fold.foldAll")
    public static let unfoldAll = CommandID(stringLiteral: "codeeditor.fold.unfoldAll")
    public static let cancel = CommandID(stringLiteral: "codeeditor.general.cancel")
}
