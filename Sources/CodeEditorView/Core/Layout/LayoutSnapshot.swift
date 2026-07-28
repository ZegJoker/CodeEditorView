import CoreGraphics
import Foundation

/// A laid-out fragment ready for drawing in document coordinates.
public struct LaidOutFragment: Identifiable {
    public var id: UUID { fragment.id }
    public let fragment: LineFragment
    public let frame: CGRect
    public let lineIndex: Int

    public init(fragment: LineFragment, frame: CGRect, lineIndex: Int) {
        self.fragment = fragment
        self.frame = frame
        self.lineIndex = lineIndex
    }
}

/// Immutable snapshot of content size and visible fragments for a viewport.
public struct LayoutSnapshot: Sendable {
    public let contentSize: CGSize
    public let fragments: [LaidOutFragment]

    public init(contentSize: CGSize, fragments: [LaidOutFragment]) {
        self.contentSize = contentSize
        self.fragments = fragments
    }

    public static let empty = LayoutSnapshot(contentSize: .zero, fragments: [])
}

// LayoutSnapshot's fragments contain CTLine which is not Sendable in the strict sense.
// We mark the type Sendable for main-actor use; fragments are only consumed on MainActor.
extension LaidOutFragment: @unchecked Sendable {}
