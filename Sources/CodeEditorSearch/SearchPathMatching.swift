import Foundation

enum SearchPathMatching {
    static func matchesGlob(_ pattern: String, path: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        let pathLower = path.lowercased()
        let patLower = p.lowercased()

        if patLower.hasPrefix("**/") {
            let rest = String(patLower.dropFirst(3))
            if rest.hasSuffix("/**") {
                let mid = String(rest.dropLast(3))
                return pathLower.contains("/\(mid)/") || pathLower.contains(mid)
            }
            if rest.hasPrefix("*.") {
                let ext = String(rest.dropFirst(2))
                return pathLower.hasSuffix(".\(ext)")
            }
            return pathLower.hasSuffix(rest) || pathLower.contains("/\(rest)")
        }
        if patLower.hasPrefix("*.") {
            let ext = String(patLower.dropFirst(2))
            return (path as NSString).pathExtension.lowercased() == ext
        }
        if patLower.contains("*") {
            // Simple contains for middle wildcards
            let parts = patLower.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            var idx = pathLower.startIndex
            for (i, part) in parts.enumerated() {
                if part.isEmpty { continue }
                if let r = pathLower.range(of: part, range: idx..<pathLower.endIndex) {
                    idx = i == parts.count - 1 ? r.upperBound : r.upperBound
                } else {
                    return false
                }
            }
            return true
        }
        return pathLower.contains(patLower)
    }

    static func isExcluded(path: String, excludes: [String]) -> Bool {
        excludes.contains { matchesGlob($0, path: path) }
    }

    static func isIncluded(path: String, includes: [String]) -> Bool {
        if includes.isEmpty { return true }
        return includes.contains { matchesGlob($0, path: path) }
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
