import CoreGraphics
import CoreText
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Explicit base writing-direction overrides + platform BiDi resolution (UI-N04).
///
/// `setBaseWritingDirection` is **not** a no-op: overrides are stored and consulted
/// before falling back to Unicode paragraph direction from the **platform layout stack**
/// (Core Text `CTLine` / glyph-run status), not a first-character-only heuristic.
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

    /// Paragraph base writing direction via the platform text stack (UI-N04).
    ///
    /// Resolves the enclosing paragraph, then asks Core Text (`CTLine` glyph runs) for
    /// right-to-left run status. This is **not** a first-strong-character scan.
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
        return platformBaseWritingDirection(for: paragraph) ?? .leftToRight
    }

    /// Platform layout resolution: CoreText typesets the paragraph and reports run direction.
    public static func platformBaseWritingDirection(for paragraph: String) -> Direction? {
        guard !paragraph.isEmpty else { return nil }
        let attr = NSAttributedString(string: paragraph)
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        let runs = CTLineGetGlyphRuns(line) as NSArray
        guard runs.count > 0 else { return nil }

        // Prefer the first non-empty run's direction (paragraph base from platform layout).
        for case let runObj as CTRun in runs {
            let glyphCount = CTRunGetGlyphCount(runObj)
            guard glyphCount > 0 else { continue }
            let status = CTRunGetStatus(runObj)
            if status.contains(.rightToLeft) {
                return .rightToLeft
            }
            // Explicit LTR / neutral run from the typesetter.
            return .leftToRight
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
