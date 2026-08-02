import Foundation

/// Minimal gitignore-style matcher (root + nested rules, negation, `**`, directory rules).
public struct GitIgnoreRules: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        public var pattern: String
        public var isNegation: Bool
        public var directoryOnly: Bool
        /// Directory containing the .gitignore, relative to workspace root ("" = root).
        public var basePath: String

        public init(pattern: String, isNegation: Bool, directoryOnly: Bool, basePath: String) {
            self.pattern = pattern
            self.isNegation = isNegation
            self.directoryOnly = directoryOnly
            self.basePath = basePath
        }
    }

    public var rules: [Rule]
    public var alwaysExcludeNames: Set<String>

    public init(rules: [Rule] = [], alwaysExcludeNames: Set<String> = [".git", ".DS_Store"]) {
        self.rules = rules
        self.alwaysExcludeNames = alwaysExcludeNames
    }

    public static func parse(fileContents: String, basePath: String = "") -> GitIgnoreRules {
        var rules: [Rule] = []
        for rawLine in fileContents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var pattern = trimmed
            var negation = false
            if pattern.hasPrefix("!") {
                negation = true
                pattern = String(pattern.dropFirst())
            }
            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern = String(pattern.dropLast())
            }
            rules.append(
                Rule(
                    pattern: pattern,
                    isNegation: negation,
                    directoryOnly: directoryOnly,
                    basePath: basePath
                ))
        }
        return GitIgnoreRules(rules: rules)
    }

    public mutating func append(contentsOf other: GitIgnoreRules) {
        rules.append(contentsOf: other.rules)
        alwaysExcludeNames.formUnion(other.alwaysExcludeNames)
    }

    /// Path is relative to workspace root using `/` separators. `isDirectory` for trailing rules.
    public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if alwaysExcludeNames.contains(name) { return true }

        var ignored = false
        for rule in rules {
            // Only apply rules whose base is a prefix of the path.
            if !rule.basePath.isEmpty {
                let prefix = rule.basePath.hasSuffix("/") ? rule.basePath : rule.basePath + "/"
                if relativePath != rule.basePath && !relativePath.hasPrefix(prefix) {
                    continue
                }
            }
            if rule.directoryOnly && !isDirectory { continue }
            let pathForMatch: String
            if rule.basePath.isEmpty {
                pathForMatch = relativePath
            } else if relativePath == rule.basePath {
                pathForMatch = ""
            } else {
                let prefix = rule.basePath + "/"
                pathForMatch =
                    relativePath.hasPrefix(prefix)
                    ? String(relativePath.dropFirst(prefix.count))
                    : relativePath
            }
            if Self.matches(pattern: rule.pattern, path: pathForMatch, name: name) {
                ignored = !rule.isNegation
            }
        }
        return ignored
    }

    private static func matches(pattern: String, path: String, name: String) -> Bool {
        if pattern.contains("/") || pattern.contains("**") {
            return globMatch(pattern, path)
        }
        // basename rule
        return globMatch(pattern, name)
    }

    /// Simple glob: `*`, `**`, `?`.
    private static func globMatch(_ pattern: String, _ text: String) -> Bool {
        // Convert gitignore-ish glob to regex.
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex, pattern[i] == "/" {
                        // ** / optional slash already covered by .*
                    }
                    continue
                }
                regex += "[^/]*"
                i = next
                continue
            }
            if c == "?" {
                regex += "[^/]"
                i = pattern.index(after: i)
                continue
            }
            if "\\.[]{}()+-^$|".contains(c) {
                regex += "\\"
            }
            regex.append(c)
            i = pattern.index(after: i)
        }
        regex += "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }
}

public enum GitIgnoreLoader {
    /// Load root `.gitignore` plus nested ones under `root` (bounded walk).
    public static func load(root: URL, maxFiles: Int = 64) -> GitIgnoreRules {
        var combined = GitIgnoreRules()
        let rootIgnore = root.appendingPathComponent(".gitignore")
        if let data = try? Data(contentsOf: rootIgnore),
            let text = String(data: data, encoding: .utf8)
        {
            combined.append(contentsOf: .parse(fileContents: text, basePath: ""))
        }

        var count = 1
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return combined
        }
        while let url = enumerator.nextObject() as? URL {
            if count >= maxFiles { break }
            guard url.lastPathComponent == ".gitignore" else { continue }
            if url.path == rootIgnore.path { continue }
            guard let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            else { continue }
            let rel = String(url.deletingLastPathComponent().path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            combined.append(contentsOf: .parse(fileContents: text, basePath: rel))
            count += 1
        }
        return combined
    }
}
