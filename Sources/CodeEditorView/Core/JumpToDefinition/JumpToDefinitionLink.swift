import Foundation

/// A single jump-to-definition target (local document range or remote URL).
///
/// Conforms to ``CodeSuggestionEntry`` so multi-target results can reuse the
/// completion panel as a popover (same approach as CodeEditSourceEditor).
public final class JumpToDefinitionLink: CodeSuggestionEntry, Identifiable {
    public var id: String {
        url?.absoluteString ?? "\(targetRange.line):\(targetRange.column):\(targetRange.range.location)"
    }

    /// Leave as `nil` when the target is in the same document.
    public let url: URL?
    public let targetRange: CursorPosition

    public let label: String
    public let detail: String?
    public let documentation: String?
    public let sourcePreview: String?
    public let systemImage: String
    public let imageColorToken: SuggestionImageColorToken
    public let deprecated: Bool

    public var targetPosition: CursorPosition? { targetRange }
    public var pathComponents: [String]? {
        url.map { $0.path.split(separator: "/").map(String.init) }
    }

    public init(
        url: URL?,
        targetRange: CursorPosition,
        label: String,
        detail: String? = nil,
        documentation: String? = nil,
        sourcePreview: String? = nil,
        systemImage: String = "dot.square.fill",
        imageColorToken: SuggestionImageColorToken = .gray,
        deprecated: Bool = false
    ) {
        self.url = url
        self.targetRange = targetRange
        self.label = label
        self.detail = detail ?? url?.lastPathComponent
        self.documentation = documentation
        self.sourcePreview = sourcePreview
        self.systemImage = systemImage
        self.imageColorToken = imageColorToken
        self.deprecated = deprecated
    }
}
