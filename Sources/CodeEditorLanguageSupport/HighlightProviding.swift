import Foundation

public enum HighlightProvidingError: Error, Sendable, Equatable {
    case cancelled
    case unavailable
}

/// Pluggable syntax / semantic highlight source.
///
/// Implementations may do heavy work off the main actor internally, but the
/// protocol surface is `@MainActor` so the highlighter can orchestrate safely.
@MainActor
public protocol HighlightProviding: AnyObject {
    /// Called when the provider is attached or the language changes.
    func setUp(documentLength: Int, languageID: String?) async

    /// Full document text snapshot (required by parsers such as tree-sitter).
    func setDocumentText(_ text: String) async

    /// Called immediately before a document mutation is applied.
    func willApplyEdit(range: NSRange)

    /// Notifies the provider of an applied edit; returns ranges that need re-highlighting.
    func applyEdit(range: NSRange, delta: Int) async throws -> IndexSet

    /// Returns highlight ranges overlapping `range`.
    ///
    /// - Parameters:
    ///   - range: UTF-16 document range being queried.
    ///   - text: Exact document substring for `range` (UTF-16 aligned).
    func queryHighlights(in range: NSRange, text: String) async throws -> [HighlightRange]
}

@MainActor
extension HighlightProviding {
    public func willApplyEdit(range: NSRange) {}

    public func setUp(documentLength: Int, languageID: String?) async {}

    public func setDocumentText(_ text: String) async {}
}
