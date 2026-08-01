import Foundation
import CodeEditorDocuments

/// Parses machine-safe Git status / diff output.
public enum GitPorcelain {
    /// Parse `git status -z` (NUL-delimited porcelain v1).
    public static func parseStatusZ(_ data: Data, repositoryRoot: URL) -> [SCMFileStatus] {
        // Records are: XY SP path NUL  or  XY SP path NUL orig NUL for renames
        var results: [SCMFileStatus] = []
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
        var i = 0
        while i < parts.count {
            let chunk = parts[i]
            i += 1
            guard chunk.count >= 3 else { continue }
            guard let line = String(data: chunk, encoding: .utf8)
                    ?? String(data: chunk, encoding: .isoLatin1) else { continue }
            guard line.count >= 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(line.startIndex, offsetBy: 1)]
            // Porcelain v1 -z: `XY <path>\0` or for rename/copy `XY <dest>\0<source>\0`.
            // First path field is the destination (current path); second is the source (original).
            var path = String(line.dropFirst(3))
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < parts.count {
                    let src = String(data: parts[i], encoding: .utf8)
                        ?? String(data: parts[i], encoding: .isoLatin1)
                    if let src, !src.isEmpty {
                        original = src
                        i += 1
                    }
                }
            }
            let (state, staged) = mapXY(x, y)
            let url = repositoryRoot.appendingPathComponent(path)
            results.append(
                SCMFileStatus(
                    uri: DocumentURI(fileURL: url),
                    path: path,
                    state: state,
                    staged: staged,
                    originalPath: original,
                    isSubmodule: false
                )
            )
        }
        return results
    }

    /// Legacy newline porcelain (tests / fallback).
    public static func parseStatus(_ text: String, repositoryRoot: URL) -> [SCMFileStatus] {
        var results: [SCMFileStatus] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard s.count >= 3 else { continue }
            let x = s[s.startIndex]
            let y = s[s.index(s.startIndex, offsetBy: 1)]
            var pathPart = String(s.dropFirst(3))
            var original: String?
            if pathPart.contains(" -> ") {
                let bits = pathPart.components(separatedBy: " -> ")
                original = bits.first
                pathPart = bits.last ?? pathPart
            }
            let path = pathPart.trimmingCharacters(in: .whitespaces)
            let url = repositoryRoot.appendingPathComponent(path)
            let (state, staged) = mapXY(x, y)
            results.append(
                SCMFileStatus(
                    uri: DocumentURI(fileURL: url),
                    path: path,
                    state: state,
                    staged: staged,
                    originalPath: original
                )
            )
        }
        return results
    }

    public static func mapXY(_ x: Character, _ y: Character) -> (SCMState, Bool) {
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
            return (.conflicted, false)
        }
        if x == "?" && y == "?" {
            return (.untracked, false)
        }
        if x == "!" {
            return (.ignored, false)
        }
        var staged = false
        var state: SCMState = .unmodified
        switch x {
        case "M": state = .modified; staged = true
        case "A": state = .added; staged = true
        case "D": state = .deleted; staged = true
        case "R": state = .renamed; staged = true
        case "C": state = .copied; staged = true
        default: break
        }
        switch y {
        case "M": state = .modified
        case "D": state = .deleted
        case "A": state = .added
        default: break
        }
        if x == " " && y == "M" { staged = false; state = .modified }
        if x == "M" && y == " " { staged = true; state = .modified }
        if x == "A" && y == " " { staged = true; state = .added }
        return (state, staged)
    }

    public static func parseDiff(_ raw: String, path: String) -> SCMDiff {
        var hunks: [SCMDiffHunk] = []
        var currentHeader = ""
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var lines: [String] = []
        let hunkRe = try! NSRegularExpression(
            pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#,
            options: []
        )
        func flush() {
            if !currentHeader.isEmpty {
                hunks.append(
                    SCMDiffHunk(
                        header: currentHeader,
                        oldStart: oldStart,
                        oldCount: oldCount,
                        newStart: newStart,
                        newCount: newCount,
                        lines: lines
                    )
                )
            }
            lines = []
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = hunkRe.firstMatch(in: line, options: [], range: range) {
                flush()
                currentHeader = line
                oldStart = Int(ns.substring(with: m.range(at: 1))) ?? 0
                oldCount = m.range(at: 2).location != NSNotFound
                    ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 1
                newStart = Int(ns.substring(with: m.range(at: 3))) ?? 0
                newCount = m.range(at: 4).location != NSNotFound
                    ? Int(ns.substring(with: m.range(at: 4))) ?? 0 : 1
            } else if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") {
                lines.append(line)
            }
        }
        flush()
        return SCMDiff(path: path, raw: raw, hunks: hunks)
    }
}

/// Repository discovery helpers.
public enum GitRepositoryDiscovery {
    /// Walk parents for `.git` (file or directory).
    public static func discover(from start: URL) -> URL? {
        var url = start.standardizedFileURL
        let fm = FileManager.default
        while true {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    public static func validateRelativePath(_ path: String, root: URL) throws -> String {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") {
            throw SCMError.pathEscape(path)
        }
        // Reject `.` / `..` path components and absolute Windows-style segments.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." {
                throw SCMError.pathEscape(path)
            }
            if segment.contains("\\") {
                throw SCMError.pathEscape(path)
            }
        }
        let standardized = (path as NSString).standardizingPath
        if standardized.hasPrefix("..") || standardized.contains("/../") || standardized.hasPrefix("/") {
            throw SCMError.pathEscape(path)
        }
        let full = root.appendingPathComponent(standardized).standardizedFileURL
        let rootURL = root.standardizedFileURL
        // Component-aware containment: string prefix alone accepts `/repo-other` for root `/repo`.
        let rootPath = rootURL.path
        let fullPath = full.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if fullPath != rootPath && !fullPath.hasPrefix(rootPrefix) {
            throw SCMError.pathEscape(path)
        }
        // Extra defense: require standardized relative path under root via path components.
        let rootComponents = rootURL.pathComponents
        let fullComponents = full.pathComponents
        guard fullComponents.count >= rootComponents.count,
              Array(fullComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw SCMError.pathEscape(path)
        }
        return standardized
    }
}
