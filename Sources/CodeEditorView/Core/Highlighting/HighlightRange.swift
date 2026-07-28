import Foundation

/// A document range styled with an optional semantic capture.
public struct HighlightRange: Equatable, Sendable, Hashable {
    public var range: NSRange
    public var capture: CaptureName?
    /// Original tree-sitter / provider capture string when unmapped or for debugging.
    public var rawCapture: String?

    public init(range: NSRange, capture: CaptureName? = nil, rawCapture: String? = nil) {
        self.range = range
        self.capture = capture
        self.rawCapture = rawCapture
    }
}

extension CaptureName: RangeStoreElement {}
