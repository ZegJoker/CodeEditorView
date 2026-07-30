import Foundation
import CodeEditorDocuments

/// Parses `git status --porcelain=v1` lines without invoking git.
public enum GitPorcelain {
    public static func parseStatus(_ text: String, repositoryRoot: URL) -> [SCMFileStatus] {
        var results: [SCMFileStatus] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard s.count >= 3 else { continue }
            let x = s[s.startIndex]
            let y = s[s.index(s.startIndex, offsetBy: 1)]
            var pathPart = String(s.dropFirst(3))
            // rename: "R  old -> new"
            if pathPart.contains(" -> ") {
                pathPart = pathPart.components(separatedBy: " -> ").last ?? pathPart
            }
            let path = pathPart.trimmingCharacters(in: .whitespaces)
            let url = repositoryRoot.appendingPathComponent(path)
            let uri = DocumentURI(fileURL: url)
            let (state, staged) = mapXY(x, y)
            results.append(SCMFileStatus(uri: uri, path: path, state: state, staged: staged))
        }
        return results
    }

    public static func mapXY(_ x: Character, _ y: Character) -> (SCMState, Bool) {
        // x = index, y = worktree
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
        case "C": state = .added; staged = true
        default: break
        }
        switch y {
        case "M": state = .modified; staged = staged || false
        case "D": state = .deleted
        case "A": state = .added
        default: break
        }
        if x == " " && y == "M" { staged = false; state = .modified }
        if x == "M" && y == " " { staged = true; state = .modified }
        if x == "A" && y == " " { staged = true; state = .added }
        return (state, staged)
    }
}
