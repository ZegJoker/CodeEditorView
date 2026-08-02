import Foundation

/// Builds Git-compatible unified diffs for hunk apply (SCM-N07).
public enum GitPatchBuilder {
    /// Quote a path the way Git expects in `diff --git` headers when needed.
    public static func quotePath(_ path: String) -> String {
        // Git C-quotes paths with spaces, tabs, quotes, backslashes, or non-ASCII control.
        let needsQuote =
            path.contains(" ")
            || path.contains("\t")
            || path.contains("\"")
            || path.contains("\\")
            || path.contains("\n")
            || path.unicodeScalars.contains(where: { $0.value < 0x20 })
        guard needsQuote else { return path }
        var escaped = "\""
        for ch in path {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(ch)
            }
        }
        escaped += "\""
        return escaped
    }

    public static func makePatch(path: String, hunk: SCMDiffHunk) -> String {
        // Quote full a/path and b/path segments when needed (paths with spaces).
        let aPath = quotePath("a/" + path)
        let bPath = quotePath("b/" + path)
        var lines = [
            "diff --git \(aPath) \(bPath)",
            "--- \(aPath)",
            "+++ \(bPath)",
            hunk.header,
        ]
        lines.append(contentsOf: hunk.lines)
        // Preserve in-line `\ No newline at end of file` markers already in hunk.lines.
        // Only append a trailing marker when the flag is set and lines do not already include it.
        let hasMarker = hunk.lines.contains(where: { $0.hasPrefix("\\") })
        if hunk.noNewlineAtEndOfFile && !hasMarker {
            lines.append("\\ No newline at end of file")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
