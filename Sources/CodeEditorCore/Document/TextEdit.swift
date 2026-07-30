import Foundation
import TextStory

/// A document mutation with its inverse, used for undo/redo bookkeeping.
public struct TextEdit: Sendable, Hashable {
    public let mutation: TextMutation
    public let inverse: TextMutation

    public init(mutation: TextMutation, inverse: TextMutation) {
        self.mutation = mutation
        self.inverse = inverse
    }

    public var range: NSRange { mutation.range }
    public var replacement: String { mutation.string }
}
