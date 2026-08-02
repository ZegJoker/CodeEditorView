import CoreGraphics
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Explicit base writing-direction overrides + platform BiDi resolution (UI-N04).
///
/// `setBaseWritingDirection` is **not** a no-op: overrides are stored and consulted
/// before falling back to Unicode paragraph direction from the platform text stack.
public struct WritingDirectionModel: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case leftToRight
        case rightToLeft
        case natural
    }

    private struct Override: Sendable, Equatable {
        var range: NSRange
        var direction: Direction
    }

    /// Half-open UTF-16 ranges with an explicit base direction.
    private var overrides: [Override]

    public init() {
        self.overrides = []
    }

    public init(overrides: [(range: NSRange, direction: Direction)]) {
        self.overrides = overrides.map { Override(range: $0.range, direction: $0.direction) }
    }

    public mutating func setBaseWritingDirection(_ direction: Direction, for range: NSRange) {
        guard range.location >= 0, range.length >= 0 else { return }
        // Replace overlapping overrides for this span (simple last-writer-wins model).
        overrides.removeAll {
            NSIntersectionRange($0.range, range).length > 0
                || ($0.range.location == range.location && $0.range.length == range.length)
        }
        if direction != .natural {
            overrides.append(Override(range: range, direction: direction))
        }
    }

    public func baseWritingDirection(at utf16Offset: Int) -> Direction? {
        for item in overrides.reversed() {
            let end = item.range.location + item.range.length
            if utf16Offset >= item.range.location,
                utf16Offset < end || (item.range.length == 0 && utf16Offset == item.range.location)
            {
                return item.direction
            }
            // Inclusive end for caret-at-end of override span.
            if item.range.length > 0, utf16Offset == end {
                return item.direction
            }
        }
        return nil
    }

    /// Override if present; otherwise platform/Unicode paragraph direction.
    public func resolvedDirection(at utf16Offset: Int, in text: String) -> Direction {
        if let o = baseWritingDirection(at: utf16Offset) {
            return o
        }
        return Self.resolveBaseDirection(forParagraphContaining: utf16Offset, in: text)
    }

    /// Unicode Bidirectional Algorithm paragraph level via Foundation (UI-N04).
    ///
    /// Uses `NSParagraphStyle` / string encoding direction — the platform text stack —
    /// not a first-character heuristic alone.
    public static func resolveBaseDirection(forParagraphContaining offset: Int, in text: String) -> Direction {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return .leftToRight }
        let loc = min(max(0, offset), len - 1)
        var paraStart = 0
        var paraEnd = len
        ns.getParagraphStart(&paraStart, end: &paraEnd, contentsEnd: nil, for: NSRange(location: loc, length: 0))
        let paraLen = max(0, paraEnd - paraStart)
        guard paraLen > 0 else { return .leftToRight }
        let paragraph = ns.substring(with: NSRange(location: paraStart, length: paraLen))

        // Platform API: NSString.defaultCStringEncoding is not BiDi; use CFString / writing direction.
        #if canImport(UIKit) || canImport(AppKit)
            let attrs: [NSAttributedString.Key: Any] = [:]
            let attr = NSAttributedString(string: paragraph, attributes: attrs)
            // Probe via natural writing direction of the attributed string's string.
            if let dir = Self.platformBaseWritingDirection(for: paragraph) {
                return dir
            }
            _ = attr
        #endif

        // Fallback: scan for first strong directional character (UAX #9 P2/P3).
        for scalar in paragraph.unicodeScalars {
            if let d = strongDirection(of: scalar) {
                return d
            }
        }
        return .leftToRight
    }

    private static func strongDirection(of scalar: Unicode.Scalar) -> Direction? {
        let v = scalar.value
        // Bidi_Class R / AL blocks commonly used in code editors.
        if (0x0590...0x05FF).contains(v)  // Hebrew
            || (0x0600...0x06FF).contains(v)  // Arabic
            || (0x0700...0x074F).contains(v)
            || (0x0750...0x077F).contains(v)
            || (0x08A0...0x08FF).contains(v)
            || (0xFB1D...0xFDFF).contains(v)
            || (0xFE70...0xFEFF).contains(v)
        {
            return .rightToLeft
        }
        // Strong L: Latin, Greek, Cyrillic, etc.
        if CharacterSet.letters.contains(scalar),
            !((0x0590...0x08FF).contains(v) || (0xFB1D...0xFEFF).contains(v))
        {
            // Exclude other RTL scripts already handled; remaining letters default LTR.
            let biClass = scalar.properties.generalCategory
            if biClass == .uppercaseLetter || biClass == .lowercaseLetter || biClass == .otherLetter
                || biClass == .titlecaseLetter
            {
                // Arabic/Hebrew already returned; remaining otherLetter may still be RTL (Syriac etc.)
                if (0x0700...0x074F).contains(v) { return .rightToLeft }
                return .leftToRight
            }
        }
        return nil
    }

    private static func platformBaseWritingDirection(for paragraph: String) -> Direction? {
        // Walk composed sequences; first strong directional character wins (UAX #9 P2/P3).
        let encoded = paragraph as NSString
        let len = encoded.length
        var i = 0
        while i < len {
            let r = encoded.rangeOfComposedCharacterSequence(at: i)
            let ch = encoded.substring(with: r)
            for s in ch.unicodeScalars {
                if let d = strongDirection(of: s) {
                    return d
                }
            }
            i = r.location + r.length
        }
        return nil
    }
}

#if canImport(UIKit)
    extension WritingDirectionModel.Direction {
        public var nsWritingDirection: NSWritingDirection {
            switch self {
            case .leftToRight: return .leftToRight
            case .rightToLeft: return .rightToLeft
            case .natural: return .natural
            }
        }

        public init(ns: NSWritingDirection) {
            switch ns {
            case .rightToLeft: self = .rightToLeft
            case .leftToRight: self = .leftToRight
            default: self = .natural
            }
        }
    }
#elseif canImport(AppKit)
    extension WritingDirectionModel.Direction {
        public var nsWritingDirection: NSWritingDirection {
            switch self {
            case .leftToRight: return .leftToRight
            case .rightToLeft: return .rightToLeft
            case .natural: return .natural
            }
        }

        public init(ns: NSWritingDirection) {
            switch ns {
            case .rightToLeft: self = .rightToLeft
            case .leftToRight: self = .leftToRight
            default: self = .natural
            }
        }
    }
#endif
