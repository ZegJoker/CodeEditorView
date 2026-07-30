import Foundation

/// Built-in command identifiers (`codeeditor.*` namespace).
public enum BuiltInCommandID {
    public static let undo = CommandID(rawValue: "codeeditor.edit.undo")
    public static let redo = CommandID(rawValue: "codeeditor.edit.redo")
    public static let indent = CommandID(rawValue: "codeeditor.edit.indent")
    public static let outdent = CommandID(rawValue: "codeeditor.edit.outdent")
    public static let toggleLineComment = CommandID(rawValue: "codeeditor.edit.toggleLineComment")
    public static let toggleBlockComment = CommandID(rawValue: "codeeditor.edit.toggleBlockComment")
    public static let moveLinesUp = CommandID(rawValue: "codeeditor.edit.moveLinesUp")
    public static let moveLinesDown = CommandID(rawValue: "codeeditor.edit.moveLinesDown")
    public static let selectAll = CommandID(rawValue: "codeeditor.edit.selectAll")
    public static let deleteBackward = CommandID(rawValue: "codeeditor.edit.deleteBackward")
    public static let deleteForward = CommandID(rawValue: "codeeditor.edit.deleteForward")
    public static let insertNewline = CommandID(rawValue: "codeeditor.edit.insertNewline")
    public static let insertTab = CommandID(rawValue: "codeeditor.edit.insertTab")
    public static let insertBacktab = CommandID(rawValue: "codeeditor.edit.insertBacktab")

    public static let findShow = CommandID(rawValue: "codeeditor.find.show")
    public static let findShowReplace = CommandID(rawValue: "codeeditor.find.showReplace")
    public static let findNext = CommandID(rawValue: "codeeditor.find.next")
    public static let findPrevious = CommandID(rawValue: "codeeditor.find.previous")
    public static let findReplace = CommandID(rawValue: "codeeditor.find.replace")
    public static let findReplaceAll = CommandID(rawValue: "codeeditor.find.replaceAll")

    public static let completionShow = CommandID(rawValue: "codeeditor.completion.show")
    public static let completionHide = CommandID(rawValue: "codeeditor.completion.hide")
    public static let completionApply = CommandID(rawValue: "codeeditor.completion.apply")
    public static let completionUp = CommandID(rawValue: "codeeditor.completion.up")
    public static let completionDown = CommandID(rawValue: "codeeditor.completion.down")

    public static let jumpToDefinition = CommandID(rawValue: "codeeditor.navigate.jumpToDefinition")
    public static let foldToggle = CommandID(rawValue: "codeeditor.fold.toggle")
    public static let foldAll = CommandID(rawValue: "codeeditor.fold.foldAll")
    public static let unfoldAll = CommandID(rawValue: "codeeditor.fold.unfoldAll")
    public static let cancel = CommandID(rawValue: "codeeditor.general.cancel")
}
