import CoreGraphics
import Foundation

public enum InvisibleCharacterStyle: Sendable, Hashable {
    /// Draw `replacement` at the character origin.
    case replace(replacement: String, color: CGColor)
    /// Tint a rect behind the character.
    case emphasize(color: CGColor)
}

public protocol InvisibleCharactersDelegate: AnyObject {
    /// UTF-16 code units that may produce invisible styles (e.g. 0x20, 0x09, 0x0A).
    var triggerCharacters: Set<UInt16> { get }
    func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle?
}

/// Default space / tab / newline markers.
public final class DefaultInvisibleCharactersDelegate: InvisibleCharactersDelegate {
    public let triggerCharacters: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D]
    public var spaceColor: CGColor
    public var tabColor: CGColor
    public var newlineColor: CGColor

    public init(
        spaceColor: CGColor = CGColor(gray: 0.6, alpha: 0.6),
        tabColor: CGColor = CGColor(gray: 0.5, alpha: 0.6),
        newlineColor: CGColor = CGColor(gray: 0.55, alpha: 0.7)
    ) {
        self.spaceColor = spaceColor
        self.tabColor = tabColor
        self.newlineColor = newlineColor
    }

    public func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle?
    {
        switch character {
        case 0x20:
            return .replace(replacement: "·", color: spaceColor)
        case 0x09:
            return .replace(replacement: "→", color: tabColor)
        case 0x0A, 0x0D:
            return .replace(replacement: "↵", color: newlineColor)
        default:
            return nil
        }
    }
}
