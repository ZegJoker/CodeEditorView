import Foundation

/// Typed failures for document buffer mutation and offset conversion.
public enum DocumentStoreError: Error, Sendable, Equatable {
    /// Transaction listed no changes.
    case emptyTransaction
    /// A change range was outside the document or otherwise unusable.
    case invalidRange(NSRange)
    /// Two or more changes in a transaction overlap (including partial overlap).
    case overlappingRanges([NSRange])
    /// Caller expected a different content generation.
    case staleVersion(expected: DocumentVersion, actual: DocumentVersion)
    /// Offset conversion was out of bounds for the string.
    case invalidOffset(Int)
    /// Offset is not on a Unicode scalar (UTF-8/UTF-16) boundary.
    case notScalarBoundary(Int)
    /// Offset is not on an extended grapheme cluster boundary.
    case notGraphemeBoundary(Int)
}
