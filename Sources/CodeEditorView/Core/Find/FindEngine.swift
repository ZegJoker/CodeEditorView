import Foundation

/// Pure find helpers (no document ownership). Pattern construction matches
/// CodeEditSourceEditor `FindPanelViewModel+Find`.
public enum FindEngine: Sendable {
    /// All non-empty match ranges for `query` in `document` (UTF-16 `NSRange`s).
    public static func matches(
        in document: String,
        query: String,
        method: FindMethod,
        matchCase: Bool
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }

        var options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        if method == .regularExpression {
            options.insert(.dotMatchesLineSeparators)
            options.insert(.anchorsMatchLines)
        }

        let pattern: String
        switch method {
        case .contains:
            pattern = NSRegularExpression.escapedPattern(for: query)
        case .matchesWord:
            pattern = "\\b" + NSRegularExpression.escapedPattern(for: query) + "\\b"
        case .startsWith:
            pattern = "(?:^|\\b)" + NSRegularExpression.escapedPattern(for: query)
        case .endsWith:
            pattern = NSRegularExpression.escapedPattern(for: query) + "(?:$|\\b)"
        case .regularExpression:
            pattern = query
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let ns = document as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: document, options: [], range: full)
            .map(\.range)
            .filter { $0.length > 0 }
    }

    /// Index of the match whose start is nearest to `caret` (binary search, CESE-style).
    public static func nearestMatchIndex(matches: [NSRange], toCaret caret: Int) -> Int? {
        guard !matches.isEmpty else { return nil }

        var left = 0
        var right = matches.count - 1
        var bestIndex = -1
        var bestDiff = Int.max

        while left <= right {
            let mid = left + (right - left) / 2
            let midStart = matches[mid].location
            let diff = abs(midStart - caret)
            if diff == 0 {
                return mid
            }
            if diff < bestDiff {
                bestDiff = diff
                bestIndex = mid
            }
            if midStart < caret {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        return bestIndex >= 0 ? bestIndex : nil
    }
}
