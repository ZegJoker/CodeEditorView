import CoreGraphics
import Foundation

public enum TextAttachmentAction: Sendable {
    case none
    case replace(text: String)
    case discard
}

/// Drawable inline attachment with reserved width.
public protocol TextAttachment: AnyObject {
    var width: CGFloat { get }
    var isSelected: Bool { get set }
    func draw(in context: CGContext, rect: CGRect)
    func attachmentAction() -> TextAttachmentAction
}

public extension TextAttachment {
    func attachmentAction() -> TextAttachmentAction { .discard }
}

public struct AnyTextAttachment: Equatable {
    public var range: NSRange
    public let attachment: any TextAttachment

    public init(range: NSRange, attachment: any TextAttachment) {
        self.range = range
        self.attachment = attachment
    }

    public var width: CGFloat { attachment.width }

    public static func == (lhs: AnyTextAttachment, rhs: AnyTextAttachment) -> Bool {
        lhs.range == rhs.range && lhs.attachment === rhs.attachment
    }
}

/// Stores document-relative attachments and keeps ranges updated across edits.
@MainActor
public final class AttachmentStore {
    public private(set) var items: [AnyTextAttachment] = []

    public init() {}

    public func add(_ attachment: any TextAttachment, range: NSRange) {
        items.append(AnyTextAttachment(range: range, attachment: attachment))
        items.sort { $0.range.location < $1.range.location }
    }

    public func removeAll() {
        items.removeAll()
    }

    public func remove(where predicate: (AnyTextAttachment) -> Bool) {
        items.removeAll(where: predicate)
    }

    public func attachments(overlapping range: NSRange) -> [AnyTextAttachment] {
        items.filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.location == range.location }
    }

    public func attachment(atUTF16Offset offset: Int) -> AnyTextAttachment? {
        items.first { NSLocationInRange(offset, $0.range) || $0.range.location == offset && $0.range.length == 0 }
    }

    /// Shifts attachment ranges after a document mutation.
    public func shift(forEditAt location: Int, delta: Int, replacedLength: Int) {
        let editRange = NSRange(location: location, length: replacedLength)
        items = items.compactMap { item in
            if NSIntersectionRange(item.range, editRange).length > 0 {
                // Attachment overlapped deleted text — drop it.
                if replacedLength > 0 { return nil }
            }
            var next = item
            next.range = MultiRangeEdit.remap(range: item.range, editLocation: location, delta: delta)
            return next
        }
    }
}
