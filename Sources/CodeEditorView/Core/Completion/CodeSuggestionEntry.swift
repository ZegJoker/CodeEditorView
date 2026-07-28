import Foundation

/// An item that can be shown in the code completion list.
///
/// Mirrors CodeEditSourceEditor’s entry shape with a platform-neutral image
/// (SF Symbol name) so AppKit and UIKit hosts share one model.
public protocol CodeSuggestionEntry: AnyObject {
    /// Primary label shown in the list (usually inserted text or symbol name).
    var label: String { get }
    /// Secondary text (type signature, module, …).
    var detail: String? { get }
    /// Longer documentation shown in a preview pane when available.
    var documentation: String? { get }
    /// Path segments for jump-style previews (optional).
    var pathComponents: [String]? { get }
    /// Target caret for navigation-style entries (optional).
    var targetPosition: CursorPosition? { get }
    /// Source snippet preview (optional; plain text in Phase 8).
    var sourcePreview: String? { get }
    /// SF Symbol name for the row icon (e.g. `"function"`).
    var systemImage: String { get }
    /// Semantic tint token for the icon (hosts map to platform colors).
    var imageColorToken: SuggestionImageColorToken { get }
    /// When true, render with strikethrough / muted styling.
    var deprecated: Bool { get }
}

/// Platform-neutral icon tint for suggestion rows.
public enum SuggestionImageColorToken: String, Sendable, Hashable, Codable {
    case gray
    case blue
    case purple
    case green
    case orange
    case pink
    case yellow
    case red
}

/// Default convenience values for simple completion entries.
public extension CodeSuggestionEntry {
    var detail: String? { nil }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var systemImage: String { "character.cursor.ibeam" }
    var imageColorToken: SuggestionImageColorToken { .gray }
    var deprecated: Bool { false }
}

/// Simple concrete entry for demos and tests.
public final class SimpleCodeSuggestion: CodeSuggestionEntry {
    public var label: String
    public var detail: String?
    public var documentation: String?
    public var pathComponents: [String]?
    public var targetPosition: CursorPosition?
    public var sourcePreview: String?
    public var systemImage: String
    public var imageColorToken: SuggestionImageColorToken
    public var deprecated: Bool

    public init(
        label: String,
        detail: String? = nil,
        documentation: String? = nil,
        pathComponents: [String]? = nil,
        targetPosition: CursorPosition? = nil,
        sourcePreview: String? = nil,
        systemImage: String = "character.cursor.ibeam",
        imageColorToken: SuggestionImageColorToken = .gray,
        deprecated: Bool = false
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.pathComponents = pathComponents
        self.targetPosition = targetPosition
        self.sourcePreview = sourcePreview
        self.systemImage = systemImage
        self.imageColorToken = imageColorToken
        self.deprecated = deprecated
    }
}
