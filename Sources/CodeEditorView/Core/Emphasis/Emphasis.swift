import Foundation

public enum EmphasisStyle: Sendable, Hashable {
    case standard
    case outline
    case underline
    case fill
}

/// A temporary or persistent highlight over a document range.
public struct Emphasis: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let range: NSRange
    public let style: EmphasisStyle
    public let flash: Bool
    public let inactive: Bool
    public let selectInDocument: Bool
    public let group: String

    public init(
        range: NSRange,
        style: EmphasisStyle = .standard,
        flash: Bool = false,
        inactive: Bool = false,
        selectInDocument: Bool = false,
        group: String = "default",
        id: UUID = UUID()
    ) {
        self.id = id
        self.range = range
        self.style = style
        self.flash = flash
        self.inactive = inactive
        self.selectInDocument = selectInDocument
        self.group = group
    }
}
