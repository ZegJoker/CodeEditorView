import Foundation

// MARK: - Workspace glob grammar (SRCH-N03)

/// Explicit workspace include/exclude glob grammar — **not** gitignore.
///
/// Supported:
/// - `*` — any chars except `/`
/// - `?` — single char except `/`
/// - `**` — any chars including `/` (cross-directory)
/// - `[abc]`, `[a-z]`, `[!abc]` character classes
/// - leading `/` anchors to path start (relative path root)
/// - case-sensitivity is an explicit policy parameter
///
/// Not supported (must not be silently half-implemented):
/// - brace expansion `{a,b}`
/// - gitignore-style bare basename multi-level matching without `**/`
public struct WorkspaceGlobPattern: Sendable, Hashable {
    public var pattern: String
    public var caseSensitive: Bool
    public var anchored: Bool

    public init(_ pattern: String, caseSensitive: Bool = false) {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        var anchored = false
        if p.hasPrefix("/") {
            anchored = true
            p = String(p.dropFirst())
        }
        self.pattern = p
        self.caseSensitive = caseSensitive
        self.anchored = anchored
    }

    public func matches(_ path: String) -> Bool {
        let text = normalize(path)
        let pat = caseSensitive ? pattern : pattern.lowercased()
        let hay = caseSensitive ? text : text.lowercased()
        if anchored {
            return WorkspaceGlobEngine.matches(pattern: pat, text: hay)
        }
        // Unanchored: match against full path only (no implicit multi-level basename).
        return WorkspaceGlobEngine.matches(pattern: pat, text: hay)
    }

    private func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
    }
}

public enum WorkspaceGlobMatcher {
    public static func isExcluded(
        path: String,
        excludes: [String],
        caseSensitive: Bool = false
    ) -> Bool {
        excludes.contains { WorkspaceGlobPattern($0, caseSensitive: caseSensitive).matches(path) }
    }

    public static func isIncluded(
        path: String,
        includes: [String],
        caseSensitive: Bool = false
    ) -> Bool {
        if includes.isEmpty { return true }
        return includes.contains { WorkspaceGlobPattern($0, caseSensitive: caseSensitive).matches(path) }
    }
}

/// Backwards-compatible façade used by older call sites.
enum SearchPathMatching {
    static func matchesGlob(_ pattern: String, path: String) -> Bool {
        WorkspaceGlobPattern(pattern, caseSensitive: false).matches(path)
    }

    static func isExcluded(path: String, excludes: [String]) -> Bool {
        WorkspaceGlobMatcher.isExcluded(path: path, excludes: excludes, caseSensitive: false)
    }

    static func isIncluded(path: String, includes: [String]) -> Bool {
        WorkspaceGlobMatcher.isIncluded(path: path, includes: includes, caseSensitive: false)
    }

    static func isBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        let sample = data.prefix(8000)
        if sample.contains(0) { return true }
        var nonText = 0
        for b in sample {
            if b < 9 || (b > 13 && b < 32) { nonText += 1 }
        }
        return Double(nonText) / Double(sample.count) > 0.3
    }
}

// MARK: - Glob engine

enum WorkspaceGlobEngine {
    static func matches(pattern: String, text: String) -> Bool {
        match(Array(pattern), Array(text), 0, 0)
    }

    private static func match(_ p: [Character], _ t: [Character], _ pi: Int, _ ti: Int) -> Bool {
        var pi = pi
        var ti = ti
        while pi < p.count {
            if p[pi] == "*", pi + 1 < p.count, p[pi + 1] == "*" {
                let afterStars = pi + 2
                if afterStars >= p.count { return true }
                var next = afterStars
                if p[next] == "/" { next += 1 }
                if next >= p.count { return true }
                var k = ti
                while true {
                    if match(p, t, next, k) { return true }
                    if k >= t.count { break }
                    k += 1
                }
                return false
            }
            if p[pi] == "*" {
                let next = pi + 1
                if next >= p.count {
                    return !t[ti...].contains("/")
                }
                var k = ti
                while true {
                    if match(p, t, next, k) { return true }
                    if k >= t.count || t[k] == "/" { break }
                    k += 1
                }
                return false
            }
            if p[pi] == "?" {
                guard ti < t.count, t[ti] != "/" else { return false }
                pi += 1
                ti += 1
                continue
            }
            if p[pi] == "[" {
                guard ti < t.count else { return false }
                guard let (ok, end) = matchClass(p, from: pi, char: t[ti]) else { return false }
                if !ok { return false }
                pi = end
                ti += 1
                continue
            }
            guard ti < t.count, p[pi] == t[ti] else { return false }
            pi += 1
            ti += 1
        }
        return ti == t.count
    }

    private static func matchClass(
        _ p: [Character],
        from: Int,
        char: Character
    ) -> (Bool, Int)? {
        var i = from + 1
        guard i < p.count else { return nil }
        var negate = false
        if p[i] == "!" || p[i] == "^" {
            negate = true
            i += 1
        }
        var matched = false
        var closed = false
        while i < p.count {
            if p[i] == "]" {
                closed = true
                i += 1
                break
            }
            if i + 2 < p.count, p[i + 1] == "-" {
                let lo = p[i]
                let hi = p[i + 2]
                if lo <= char && char <= hi { matched = true }
                i += 3
                continue
            }
            if p[i] == char { matched = true }
            i += 1
        }
        guard closed else { return nil }
        return (negate ? !matched : matched, i)
    }
}

// MARK: - Geometry helpers

enum SearchTextGeometry {
    static func lineColumn(utf16Offset: Int, in text: String) -> (line: Int, column: Int) {
        let ns = text as NSString
        let loc = min(max(0, utf16Offset), ns.length)
        var line = 0
        var lineStart = 0
        var i = 0
        while i < loc {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {
                line += 1
                lineStart = i
            } else if ch == 0x0D {
                if i < ns.length, ns.character(at: i) == 0x0A { i += 1 }
                line += 1
                lineStart = i
            }
        }
        return (line, max(0, loc - lineStart))
    }

    static func linePreview(utf16Offset: Int, in text: String) -> String {
        let ns = text as NSString
        let loc = min(max(0, utf16Offset), ns.length)
        var start = loc
        while start > 0 {
            let ch = ns.character(at: start - 1)
            if ch == 0x0A || ch == 0x0D { break }
            start -= 1
        }
        var end = loc
        while end < ns.length {
            let ch = ns.character(at: end)
            if ch == 0x0A || ch == 0x0D { break }
            end += 1
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
