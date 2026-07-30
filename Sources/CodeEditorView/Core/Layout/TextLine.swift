import CoreGraphics
import Foundation
import CodeEditorCore

/// A logical document line with cached typeset fragments.
public final class TextLine: LinePayload, Identifiable {
    public let id: UUID
    public private(set) var fragments: [LineFragment]
    public private(set) var typesetHeight: CGFloat
    public private(set) var needsTypeset: Bool

    public init(fragments: [LineFragment] = [], typesetHeight: CGFloat = 0) {
        self.id = UUID()
        self.fragments = fragments
        self.typesetHeight = typesetHeight
        self.needsTypeset = true
    }

    public func markNeedsTypeset() {
        needsTypeset = true
        fragments = []
        typesetHeight = 0
    }

    public func applyTypeset(fragments: [LineFragment], height: CGFloat) {
        self.fragments = fragments
        self.typesetHeight = height
        self.needsTypeset = false
    }
}
