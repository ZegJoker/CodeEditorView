import Foundation

/// A single UTF-16 replacement to apply to a document (high→low order when applying many).
public struct TextReplacement: Equatable, Sendable {
    public var range: NSRange
    public var string: String

    public init(range: NSRange, string: String) {
        self.range = range
        self.string = string
    }
}

/// Pure structure-edit planners over a full document string + selection ranges.
public enum StructureCommands: Sendable {
    // MARK: - Line helpers

    /// UTF-16 ranges of full lines intersecting any of `selections` (including trailing newline except last line).
    public static func lineRanges(
        intersecting selections: [NSRange],
        in document: String
    ) -> [NSRange] {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        var lineStarts = Set<Int>()
        for sel in selections {
            let loc = min(max(0, sel.location), length)
            let end = min(length, max(loc, sel.location + max(0, sel.length)))
            // Empty caret: one line. Non-empty: all lines from loc..<end.
            var probe = loc
            while true {
                let p = min(probe, max(0, length - 1))
                var lineStart = 0
                var lineEnd = 0
                var contentsEnd = 0
                ns.getLineStart(
                    &lineStart,
                    end: &lineEnd,
                    contentsEnd: &contentsEnd,
                    for: NSRange(location: p, length: 0)
                )
                lineStarts.insert(lineStart)
                if sel.length == 0 { break }
                if lineEnd >= end { break }
                if lineEnd <= probe { break }
                probe = lineEnd
            }
        }

        return lineStarts.sorted().map { start in
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: start, length: 0)
            )
            return NSRange(location: lineStart, length: lineEnd - lineStart)
        }
    }

    public static func lineContent(range: NSRange, in document: String) -> String {
        let ns = document as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    // MARK: - Indent / outdent

    /// Replacements that indent each full line intersecting `selections`.
    public static func indentLines(
        selections: [NSRange],
        document: String,
        indent: IndentOption
    ) -> [TextReplacement] {
        let lines = lineRanges(intersecting: selections, in: document)
        let unit = indent.string
        guard !unit.isEmpty else { return [] }
        return lines.map { line in
            TextReplacement(range: NSRange(location: line.location, length: 0), string: unit)
        }
        .sorted { $0.range.location > $1.range.location }
    }

    public static func outdentLines(
        selections: [NSRange],
        document: String,
        indent: IndentOption
    ) -> [TextReplacement] {
        let ns = document as NSString
        let lines = lineRanges(intersecting: selections, in: document)
        var replacements: [TextReplacement] = []
        for line in lines {
            let text = ns.substring(with: line)
            // Only the content without stripping the newline for outdent match
            let hasNL = text.hasSuffix("\n") || text.hasSuffix("\r")
            let content: String
            let nl: String
            if text.hasSuffix("\r\n") {
                content = String(text.dropLast(2))
                nl = "\r\n"
            } else if hasNL, let last = text.last {
                content = String(text.dropLast())
                nl = String(last)
            } else {
                content = text
                nl = ""
            }
            let outdented = TextFilters.outdentLine(content, indent: indent)
            if outdented != content {
                replacements.append(
                    TextReplacement(range: line, string: outdented + nl)
                )
            }
        }
        return replacements.sorted { $0.range.location > $1.range.location }
    }

    // MARK: - Move lines

    /// Move the contiguous block of lines covering `selections` up or down by one line.
    public static func moveLines(
        selections: [NSRange],
        document: String,
        up: Bool
    ) -> (replacements: [TextReplacement], newSelection: NSRange)? {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return nil }

        let lines = lineRanges(intersecting: selections, in: document)
        guard let first = lines.first, let last = lines.last else { return nil }
        let block = NSRange(
            location: first.location,
            length: last.location + last.length - first.location
        )
        let blockText = ns.substring(with: block)

        if up {
            guard first.location > 0 else { return nil }
            var prevStart = 0
            var prevEnd = 0
            var prevContents = 0
            ns.getLineStart(
                &prevStart,
                end: &prevEnd,
                contentsEnd: &prevContents,
                for: NSRange(location: first.location - 1, length: 0)
            )
            let prevRange = NSRange(location: prevStart, length: prevEnd - prevStart)
            let prevText = ns.substring(with: prevRange)
            let combined = NSRange(location: prevStart, length: block.location + block.length - prevStart)
            let newText = blockText + prevText
            let newSel = NSRange(location: prevStart, length: block.length)
            return (
                [TextReplacement(range: combined, string: newText)],
                newSel
            )
        } else {
            let blockEnd = block.location + block.length
            guard blockEnd < length else { return nil }
            var nextStart = 0
            var nextEnd = 0
            var nextContents = 0
            ns.getLineStart(
                &nextStart,
                end: &nextEnd,
                contentsEnd: &nextContents,
                for: NSRange(location: blockEnd, length: 0)
            )
            let nextRange = NSRange(location: nextStart, length: nextEnd - nextStart)
            let nextText = ns.substring(with: nextRange)
            let combined = NSRange(location: block.location, length: nextEnd - block.location)
            let newText = nextText + blockText
            let newSel = NSRange(location: block.location + nextRange.length, length: block.length)
            return (
                [TextReplacement(range: combined, string: newText)],
                newSel
            )
        }
    }

    // MARK: - Comments

    public static func toggleLineComment(
        selections: [NSRange],
        document: String,
        lineComment: String
    ) -> [TextReplacement] {
        let marker = lineComment
        guard !marker.isEmpty else { return [] }
        let ns = document as NSString
        let lines = lineRanges(intersecting: selections, in: document)
        // If every non-empty line is commented, uncomment; else comment.
        var contentLines: [(range: NSRange, content: String, nl: String)] = []
        for line in lines {
            let text = ns.substring(with: line)
            let nl: String
            let content: String
            if text.hasSuffix("\r\n") {
                content = String(text.dropLast(2))
                nl = "\r\n"
            } else if text.hasSuffix("\n") || text.hasSuffix("\r") {
                content = String(text.dropLast())
                nl = String(text.last!)
            } else {
                content = text
                nl = ""
            }
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            contentLines.append((line, content, nl))
        }
        guard !contentLines.isEmpty else { return [] }

        let allCommented = contentLines.allSatisfy { item in
            let trimmed = item.content.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(marker)
        }

        var replacements: [TextReplacement] = []
        for item in contentLines {
            let leading = TextFilters.leadingWhitespace(ofLine: item.content)
            let rest = String(item.content.dropFirst(leading.count))
            let newContent: String
            if allCommented {
                if rest.hasPrefix(marker + " ") {
                    newContent = leading + String(rest.dropFirst(marker.count + 1))
                } else if rest.hasPrefix(marker) {
                    newContent = leading + String(rest.dropFirst(marker.count))
                } else {
                    newContent = item.content
                }
            } else {
                newContent = leading + marker + " " + rest
            }
            if newContent != item.content {
                replacements.append(
                    TextReplacement(range: item.range, string: newContent + item.nl)
                )
            }
        }
        return replacements.sorted { $0.range.location > $1.range.location }
    }

    public static func toggleBlockComment(
        selection: NSRange,
        document: String,
        open: String,
        close: String
    ) -> TextReplacement? {
        guard !open.isEmpty, !close.isEmpty, selection.length > 0 else { return nil }
        let ns = document as NSString
        guard selection.location + selection.length <= ns.length else { return nil }
        let text = ns.substring(with: selection)
        if text.hasPrefix(open), text.hasSuffix(close), text.count >= open.count + close.count {
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            return TextReplacement(range: selection, string: inner)
        }
        return TextReplacement(range: selection, string: open + text + close)
    }
}
