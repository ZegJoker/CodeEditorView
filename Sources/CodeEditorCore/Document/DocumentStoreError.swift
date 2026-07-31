import Foundation

/// Typed failures for document buffer mutation and offset conversion.
public enum DocumentStoreError: Error, Sendable, Equatable {
    /// Transaction listed no changes.
    case emptyTransaction
    /// A change range was outside the document or otherwise unusable.
    case invalidRange(NSRange)
    /// Caller expected a different content generation.
    case staleVersion(expected: DocumentVersion, actual: DocumentVersion)
    /// Offset conversion was out of bounds for the string.
    case invalidOffset(Int)
}
