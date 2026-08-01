import CodeEditorCore
import Foundation

/// Represents a fold boundary encountered while scanning a single line (CESE-aligned).
public enum LineFoldProviderLineInfo: Equatable, Sendable {
    /// Begin a fold at `rangeStart` (UTF-16), moving to `newDepth`.
    case startFold(rangeStart: Int, newDepth: Int)
    /// End open folds down to `newDepth` at `rangeEnd` (UTF-16).
    case endFold(rangeEnd: Int, newDepth: Int)

    public var depth: Int {
        switch self {
        case .startFold(_, let newDepth), .endFold(_, let newDepth):
            return newDepth
        }
    }

    public var rangeIndice: Int {
        switch self {
        case .startFold(let rangeStart, _):
            return rangeStart
        case .endFold(let rangeEnd, _):
            return rangeEnd
        }
    }
}

/// Document context passed to fold providers (avoids coupling to ``EditorController``).
public struct LineFoldProviderContext: Sendable {
    public var document: String
    public var indentOption: IndentOption
    public var lineCount: Int

    public init(document: String, indentOption: IndentOption, lineCount: Int) {
        self.document = document
        self.indentOption = indentOption
        self.lineCount = lineCount
    }

    public var nsDocument: NSString { document as NSString }
    public var documentLength: Int { nsDocument.length }

    /// Characters per indent unit (spaces count, or 1 for tab) — matches CESE `charCount` usage.
    public var indentCharCount: Int {
        switch indentOption {
        case .spaces(let count): return max(1, count)
        case .tab: return 1
        }
    }
}

/// Interface used by the editor to discover fold regions.
///
/// Called often while rebuilding folds; keep implementations fast.
@MainActor
public protocol LineFoldProvider: AnyObject {
    /// Return fold start/end markers for a single line.
    /// - Parameters:
    ///   - lineNumber: Zero-based line index.
    ///   - lineRange: UTF-16 range of the line (including terminator when present).
    ///   - previousDepth: Nesting depth before this line.
    ///   - context: Document + indent settings.
    func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        context: LineFoldProviderContext
    ) -> [LineFoldProviderLineInfo]
}
