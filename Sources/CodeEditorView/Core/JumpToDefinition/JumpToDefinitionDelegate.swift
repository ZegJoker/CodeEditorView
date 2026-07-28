import Foundation

/// App-supplied jump-to-definition provider (CESE-aligned, no Combine).
///
/// The editor resolves the identifier range (tree-sitter / word), draws hover chrome,
/// and presents multi-target UI. The delegate supplies targets and opens remote links.
@MainActor
public protocol JumpToDefinitionDelegate: AnyObject {
    /// Resolve definition targets for the symbol covering `range`.
    ///
    /// - Returns: Zero or more links, or `nil` when no provider is available.
    func queryLinks(forRange range: NSRange, textView: EditorController) async -> [JumpToDefinitionLink]?

    /// Open a remote / cross-file link (`url != nil`). Local links are handled by the editor.
    func openLink(link: JumpToDefinitionLink)
}
