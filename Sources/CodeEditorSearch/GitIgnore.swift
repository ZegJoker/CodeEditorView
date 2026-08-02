import Foundation

/// Git-compatible ignore matcher (SRCH-N01 / SRCH-N02).
///
/// Semantics target Git’s documented `.gitignore` rules and are regression-tested
/// against `git check-ignore --no-index` on a fixture corpus.
public struct GitIgnoreRules: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        /// Pattern after stripping negation / directory-only markers (unescaped).
        public var pattern: String
        public var isNegation: Bool
        public var directoryOnly: Bool
        /// True when the original pattern had a leading `/` (anchored to base).
        public var anchored: Bool
        /// True when the pattern contains a `/` (after stripping trailing slash) — path match.
        public var hasSlash: Bool
        /// Directory containing the `.gitignore`, relative to workspace root (`""` = root).
        public var basePath: String

        public init(
            pattern: String,
            isNegation: Bool,
            directoryOnly: Bool,
            anchored: Bool,
            hasSlash: Bool,
            basePath: String
        ) {
            self.pattern = pattern
            self.isNegation = isNegation
            self.directoryOnly = directoryOnly
            self.anchored = anchored
            self.hasSlash = hasSlash
            self.basePath = basePath
        }
    }

    public var rules: [Rule]
    public var alwaysExcludeNames: Set<String>

    public init(rules: [Rule] = [], alwaysExcludeNames: Set<String> = [".git", ".DS_Store"]) {
        self.rules = rules
        self.alwaysExcludeNames = alwaysExcludeNames
    }

    /// Parse a single `.gitignore` file body for `basePath` (relative to workspace root).
    public static func parse(fileContents: String, basePath: String = "") -> GitIgnoreRules {
        var rules: [Rule] = []
        for rawLine in fileContents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }

            // Strip unescaped trailing spaces (SRCH-N02).
            line = stripUnescapedTrailingSpaces(line)
            if line.isEmpty { continue }

            // Comment lines: leading `#` unless escaped as `\#`.
            if line.first == "#", !line.hasPrefix("\\#") { continue }

            var isNegation = false
            if line.first == "!", !line.hasPrefix("\\!") {
                isNegation = true
                line = String(line.dropFirst())
                line = stripUnescapedTrailingSpaces(line)
                if line.isEmpty { continue }
            }

            // Unescape leading literal `#` / `!` after optional negation handling.
            if line.hasPrefix("\\#") || line.hasPrefix("\\!") {
                line = String(line.dropFirst()) // drop backslash, keep # or !
            }

            var directoryOnly = false
            if line.hasSuffix("/"), !line.hasSuffix("\\/") {
                directoryOnly = true
                line = String(line.dropLast())
            }
            if line.isEmpty { continue }

            var anchored = false
            if line.hasPrefix("/") {
                anchored = true
                line = String(line.dropFirst())
            }

            // Unescape remaining backslash-escapes for matching (`\ `, `\*`, etc.).
            let pattern = unescapePattern(line)
            let hasSlash = pattern.contains("/")

            rules.append(
                Rule(
                    pattern: pattern,
                    isNegation: isNegation,
                    directoryOnly: directoryOnly,
                    anchored: anchored,
                    hasSlash: hasSlash || anchored,
                    basePath: basePath
                )
            )
        }
        return GitIgnoreRules(rules: rules)
    }

    public mutating func append(contentsOf other: GitIgnoreRules) {
        rules.append(contentsOf: other.rules)
        alwaysExcludeNames.formUnion(other.alwaysExcludeNames)
    }

    /// Path is relative to workspace root using `/` separators.
    public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let normalized = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
        if normalized.isEmpty { return false }

        let name = (normalized as NSString).lastPathComponent
        if alwaysExcludeNames.contains(name) { return true }

        // Walk every path prefix so an ignored parent directory makes children ignored
        // unless a later rule re-includes them *and* the parent itself is not ignored.
        let segments = normalized.split(separator: "/").map(String.init)
        var ignored = false

        // Evaluate full path and each ancestor directory for parent-directory exclusion.
        for depth in 1...segments.count {
            let partial = segments.prefix(depth).joined(separator: "/")
            let partialIsDir = depth < segments.count || isDirectory
            ignored = applyRules(to: partial, isDirectory: partialIsDir, currentlyIgnored: ignored)
            // If a parent directory remains ignored, children are ignored (git performance rule).
            if depth < segments.count, ignored {
                return true
            }
        }
        return ignored
    }

    private func applyRules(to relativePath: String, isDirectory: Bool, currentlyIgnored: Bool) -> Bool {
        var ignored = currentlyIgnored
        let name = (relativePath as NSString).lastPathComponent

        for rule in rules {
            // Only rules whose base is a prefix of the path apply.
            let pathForMatch: String
            if rule.basePath.isEmpty {
                pathForMatch = relativePath
            } else if relativePath == rule.basePath {
                // The base directory itself is not matched by nested rules against children.
                continue
            } else {
                let prefix = rule.basePath.hasSuffix("/") ? rule.basePath : rule.basePath + "/"
                guard relativePath.hasPrefix(prefix) else { continue }
                pathForMatch = String(relativePath.dropFirst(prefix.count))
            }
            if pathForMatch.isEmpty { continue }
            if rule.directoryOnly && !isDirectory { continue }

            if matches(rule: rule, path: pathForMatch, name: name) {
                ignored = !rule.isNegation
            }
        }
        return ignored
    }

    private func matches(rule: Rule, path: String, name: String) -> Bool {
        // Path-scoped patterns (slash or anchored) match against path relative to base.
        if rule.hasSlash || rule.anchored {
            return GitIgnoreGlob.matches(pattern: rule.pattern, text: path)
        }
        // Basename pattern: match name at any level (git: no-slash patterns).
        if GitIgnoreGlob.matches(pattern: rule.pattern, text: name) {
            return true
        }
        // Also allow full-path ** patterns written without intermediate slash after unescape edge cases.
        if rule.pattern.contains("**") {
            return GitIgnoreGlob.matches(pattern: rule.pattern, text: path)
        }
        return false
    }

    // MARK: - Parse helpers

    private static func stripUnescapedTrailingSpaces(_ line: String) -> String {
        var chars = Array(line)
        while let last = chars.last, last == " " {
            // Count preceding backslashes — odd means escaped space.
            var bs = 0
            var i = chars.count - 2
            while i >= 0, chars[i] == "\\" {
                bs += 1
                i -= 1
            }
            if bs % 2 == 1 {
                // Escaped trailing space: remove the backslash, keep the space, stop.
                chars.remove(at: chars.count - 2)
                break
            }
            chars.removeLast()
        }
        return String(chars)
    }

    private static func unescapePattern(_ pattern: String) -> String {
        var out = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "\\", pattern.index(after: i) < pattern.endIndex {
                let next = pattern.index(after: i)
                out.append(pattern[next])
                i = pattern.index(after: next)
                continue
            }
            out.append(c)
            i = pattern.index(after: i)
        }
        return out
    }
}

// MARK: - Gitignore glob

/// Glob engine for gitignore patterns (`*`, `?`, `**`, character classes).
enum GitIgnoreGlob {
    static func matches(pattern: String, text: String) -> Bool {
        match(Array(pattern), Array(text), 0, 0)
    }

    private static func match(_ p: [Character], _ t: [Character], _ pi: Int, _ ti: Int) -> Bool {
        var pi = pi
        var ti = ti
        while pi < p.count {
            // **
            if p[pi] == "*", pi + 1 < p.count, p[pi + 1] == "*" {
                let after = pi + 2
                // trailing ** matches rest
                if after >= p.count { return true }
                // **/ → also allow zero directories (optional slash)
                var next = after
                if p[next] == "/" { next += 1 }
                // Try consuming zero or more path segments / chars
                if next >= p.count { return true }
                var k = ti
                while true {
                    if match(p, t, next, k) { return true }
                    if k >= t.count { break }
                    k += 1
                }
                // Also try with slash-only skip when pattern had **/
                return false
            }

            if p[pi] == "*" {
                // * — any chars except /
                let next = pi + 1
                if next >= p.count {
                    // trailing * — rest of segment must not need more pattern
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

    /// Returns (matched, indexAfterClass).
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

// MARK: - Loader (SRCH-N01)

public enum GitIgnoreLoader {
    /// Load root `.gitignore` plus nested ones under `root`.
    ///
    /// Nested discovery **must not** use `skipsHiddenFiles` — `.gitignore` itself is hidden
    /// (SRCH-N01). The walk still refuses to enter `.git` for performance/safety.
    public static func load(root: URL, maxFiles: Int = 256) -> GitIgnoreRules {
        var combined = GitIgnoreRules()
        let rootIgnore = root.appendingPathComponent(".gitignore")
        if let data = try? Data(contentsOf: rootIgnore),
            let text = String(data: data, encoding: .utf8)
        {
            combined.append(contentsOf: .parse(fileContents: text, basePath: ""))
        }

        var count = 1
        // SRCH-N01: do not skip hidden files — otherwise nested `.gitignore` is invisible.
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        else {
            return combined
        }

        let rootPath = root.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            if count >= maxFiles { break }
            let name = url.lastPathComponent
            if name == ".git" {
                enumerator.skipDescendants()
                continue
            }
            // Skip other VCS / build trees for discovery walk.
            if name == ".build" || name == "DerivedData" || name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard name == ".gitignore" else { continue }
            if url.standardizedFileURL.path == rootIgnore.standardizedFileURL.path { continue }
            guard let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            else { continue }

            let dirPath = url.deletingLastPathComponent().standardizedFileURL.path
            var rel = ""
            if dirPath.hasPrefix(rootPath) {
                rel = String(dirPath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            combined.append(contentsOf: .parse(fileContents: text, basePath: rel))
            count += 1
        }
        return combined
    }
}
