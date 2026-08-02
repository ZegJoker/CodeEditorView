import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation

public struct ProblemMatcher: Sendable {
    public var id: ProblemMatcherID
    public var owner: String
    /// Named groups: file, line, column, severity, message (message required).
    public var pattern: NSRegularExpression
    public var fileGroup: Int
    public var lineGroup: Int
    public var columnGroup: Int
    public var severityGroup: Int?
    public var messageGroup: Int
    /// When set, continues matching subsequent lines until this end pattern.
    public var multilineEndPattern: NSRegularExpression?
    public var maxProblems: Int

    public init(
        id: ProblemMatcherID,
        owner: String,
        pattern: NSRegularExpression,
        fileGroup: Int = 1,
        lineGroup: Int = 2,
        columnGroup: Int = 3,
        severityGroup: Int? = nil,
        messageGroup: Int = 4,
        multilineEndPattern: NSRegularExpression? = nil,
        maxProblems: Int = 2_000
    ) {
        self.id = id
        self.owner = owner
        self.pattern = pattern
        self.fileGroup = fileGroup
        self.lineGroup = lineGroup
        self.columnGroup = columnGroup
        self.severityGroup = severityGroup
        self.messageGroup = messageGroup
        self.multilineEndPattern = multilineEndPattern
        self.maxProblems = maxProblems
    }

    /// Swift compiler-style: `file:line:col: error: message`
    public static func swiftCompiler(owner: String = "swift") throws -> ProblemMatcher {
        let pattern = try NSRegularExpression(
            pattern: #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#,
            options: []
        )
        return ProblemMatcher(
            id: "swift",
            owner: owner,
            pattern: pattern,
            fileGroup: 1,
            lineGroup: 2,
            columnGroup: 3,
            severityGroup: 4,
            messageGroup: 5
        )
    }
}

/// Protocol-level source position (line/column) before snapshot resolution.
///
/// Task/compiler diagnostics must **not** invent UTF-16 offsets (TASK-001).
public struct TaskSourcePosition: Sendable, Hashable, Codable {
    /// Zero-based line index.
    public var line: Int
    /// Zero-based column in the matcher's column encoding (typically 1-based tools → 0-based here).
    public var column: Int
    /// How `column` was counted by the problem matcher / compiler.
    public var encoding: ColumnEncoding

    public enum ColumnEncoding: String, Sendable, Hashable, Codable {
        case utf16
        case utf8
        case scalar
        case display
    }

    public init(line: Int, column: Int, encoding: ColumnEncoding = .utf16) {
        self.line = max(0, line)
        self.column = max(0, column)
        self.encoding = encoding
    }
}

public struct MatchedProblem: Sendable, Hashable {
    public var uri: DocumentURI?
    public var path: String
    public var diagnostic: LanguageDiagnostic
    /// Exact line/column from the matcher; resolve to UTF-16 only against a document snapshot.
    public var position: TaskSourcePosition

    public init(
        uri: DocumentURI?,
        path: String,
        diagnostic: LanguageDiagnostic,
        position: TaskSourcePosition
    ) {
        self.uri = uri
        self.path = path
        self.diagnostic = diagnostic
        self.position = position
    }

    /// Resolve `position` against `text` into a UTF-16 range for navigation.
    public func resolvedRange(in text: String) throws -> CodeEditorCore.TextRange {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else {
            throw DocumentStoreError.invalidOffset(position.line)
        }
        var utf16Offset = 0
        for i in 0..<position.line {
            utf16Offset += (String(lines[i]) as NSString).length + 1  // +1 for '\n'
        }
        let lineText = String(lines[position.line])
        let lineUTF16 = (lineText as NSString).length
        let col = min(position.column, lineUTF16)
        let location = utf16Offset + col
        return CodeEditorCore.TextRange(location: location, length: max(0, min(1, lineUTF16 - col)))
    }
}

public enum ProblemMatcherEngine {
    public static func match(
        line: String,
        matcher: ProblemMatcher,
        cwd: URL?,
        workspaceRoot: URL? = nil
    ) -> MatchedProblem? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = matcher.pattern.firstMatch(in: line, options: [], range: range) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        }
        guard let message = group(matcher.messageGroup) else { return nil }
        let rawPath = group(matcher.fileGroup) ?? ""
        let path = normalizePath(rawPath, cwd: cwd, workspaceRoot: workspaceRoot)
        guard let path else { return nil }
        let lineNum = max(0, (Int(group(matcher.lineGroup) ?? "1") ?? 1) - 1)
        let col = max(0, (Int(group(matcher.columnGroup) ?? "1") ?? 1) - 1)
        let severityText = matcher.severityGroup.flatMap { group($0) }?.lowercased() ?? "error"
        let severity: LanguageDiagnosticSeverity
        switch severityText {
        case "warning", "warn": severity = .warning
        case "note", "info", "information": severity = .information
        case "hint": severity = .hint
        default: severity = .error
        }
        // TASK-001: never invent UTF-16 offsets from line*N+col. Keep protocol coordinates;
        // hosts resolve against a document snapshot via MatchedProblem.resolvedRange(in:).
        let position = TaskSourcePosition(line: lineNum, column: col, encoding: .utf16)
        let diagnostic = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: 0, length: 0),
            severity: severity,
            message: message,
            source: matcher.owner
        )
        let uri: DocumentURI
        if path.hasPrefix("/") {
            uri = DocumentURI(fileURL: URL(fileURLWithPath: path))
        } else if let cwd {
            uri = DocumentURI(fileURL: cwd.appendingPathComponent(path))
        } else {
            uri = DocumentURI(rawValue: path)
        }
        return MatchedProblem(uri: uri, path: path, diagnostic: diagnostic, position: position)
    }

    public static func matchAll(
        text: String,
        matchers: [ProblemMatcher],
        cwd: URL?,
        workspaceRoot: URL? = nil
    ) -> [MatchedProblem] {
        var results: [MatchedProblem] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            var matched = false
            for matcher in matchers {
                if let problem = match(line: line, matcher: matcher, cwd: cwd, workspaceRoot: workspaceRoot) {
                    var message = problem.diagnostic.message
                    if let end = matcher.multilineEndPattern {
                        var j = i + 1
                        while j < lines.count {
                            let next = lines[j]
                            let range = NSRange(next.startIndex..<next.endIndex, in: next)
                            if end.firstMatch(in: next, options: [], range: range) != nil {
                                break
                            }
                            message += "\n" + next
                            j += 1
                        }
                        i = j
                    }
                    var diag = problem.diagnostic
                    diag.message = message
                    results.append(
                        MatchedProblem(
                            uri: problem.uri,
                            path: problem.path,
                            diagnostic: diag,
                            position: problem.position
                        ))
                    if results.count >= matcher.maxProblems { return results }
                    matched = true
                    break
                }
            }
            if !matched {
                i += 1
            } else if matchers.allSatisfy({ $0.multilineEndPattern == nil }) {
                i += 1
            }
        }
        return results
    }

    /// Streaming matcher with rolling window for chunk-split lines (TASK-002).
    public final class StreamingState: @unchecked Sendable {
        private var buffer = ""
        private let windowMax = 64 * 1024
        private var problems: [MatchedProblem] = []
        private let matchers: [ProblemMatcher]
        private let cwd: URL?
        private let workspaceRoot: URL?

        public init(matchers: [ProblemMatcher], cwd: URL?, workspaceRoot: URL? = nil) {
            self.matchers = matchers
            self.cwd = cwd
            self.workspaceRoot = workspaceRoot
        }

        public var results: [MatchedProblem] { problems }

        public func append(_ chunk: String) {
            buffer += chunk
            if buffer.count > windowMax {
                buffer = String(buffer.suffix(windowMax))
            }
            consumeCompleteLines(flush: false)
        }

        public func flush() {
            consumeCompleteLines(flush: true)
        }

        private func consumeCompleteLines(flush: Bool) {
            var lines = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !flush {
                // Keep incomplete last line in buffer.
                if !buffer.hasSuffix("\n") {
                    buffer = lines.popLast() ?? ""
                } else {
                    buffer = ""
                    if lines.last == "" { lines.removeLast() }
                }
            } else {
                buffer = ""
            }
            let joined = lines.joined(separator: "\n")
            let more = ProblemMatcherEngine.matchAll(
                text: joined, matchers: matchers, cwd: cwd, workspaceRoot: workspaceRoot)
            problems.append(contentsOf: more)
            if let max = matchers.map(\.maxProblems).min() {
                if problems.count > max {
                    problems = Array(problems.prefix(max))
                }
            }
        }
    }

    /// Returns nil when path escapes workspace root.
    public static func normalizePath(
        _ raw: String,
        cwd: URL?,
        workspaceRoot: URL?
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let base = cwd ?? workspaceRoot
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else if let base {
            url = base.appendingPathComponent(trimmed).standardizedFileURL
        } else {
            return trimmed
        }
        if let root = workspaceRoot?.standardizedFileURL {
            let rootPath = root.path
            let path = url.path
            if path != rootPath && !path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                // Also allow equal after standardization
                if !path.hasPrefix(rootPath) {
                    return nil
                }
            }
        }
        return url.path
    }
}

/// Incremental line-buffered matcher for live task output.
public final class StreamingProblemMatcherEngine: @unchecked Sendable {
    private let matchers: [ProblemMatcher]
    private let cwd: URL?
    private let workspaceRoot: URL?
    private var buffer = ""
    private var problems: [MatchedProblem] = []
    private let lock = NSLock()
    private let maxProblems: Int

    public init(matchers: [ProblemMatcher], cwd: URL?, workspaceRoot: URL? = nil) {
        self.matchers = matchers
        self.cwd = cwd
        self.workspaceRoot = workspaceRoot ?? cwd
        self.maxProblems = matchers.map(\.maxProblems).min() ?? 2_000
    }

    public func feed(_ text: String) -> [MatchedProblem] {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        var emitted: [MatchedProblem] = []
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            if problems.count >= maxProblems { break }
            for matcher in matchers {
                if let p = ProblemMatcherEngine.match(
                    line: line,
                    matcher: matcher,
                    cwd: cwd,
                    workspaceRoot: workspaceRoot
                ) {
                    problems.append(p)
                    emitted.append(p)
                    break
                }
            }
        }
        return emitted
    }

    public func finish() -> [MatchedProblem] {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            let line = buffer
            buffer = ""
            for matcher in matchers {
                if let p = ProblemMatcherEngine.match(
                    line: line,
                    matcher: matcher,
                    cwd: cwd,
                    workspaceRoot: workspaceRoot
                ) {
                    problems.append(p)
                    return [p]
                }
            }
        }
        return []
    }

    public var allProblems: [MatchedProblem] {
        lock.lock()
        defer { lock.unlock() }
        return problems
    }
}

// MARK: - Diagnostics sink

public protocol TaskDiagnosticsSink: Sendable {
    func publish(uri: DocumentURI, diagnostics: [LanguageDiagnostic], owner: String) async
}

public actor InMemoryTaskDiagnosticsSink: TaskDiagnosticsSink {
    private var store: [DocumentURI: [LanguageDiagnostic]] = [:]

    public init() {}

    public func publish(uri: DocumentURI, diagnostics: [LanguageDiagnostic], owner: String) async {
        _ = owner
        store[uri, default: []].append(contentsOf: diagnostics)
    }

    public func diagnostics(for uri: DocumentURI) -> [LanguageDiagnostic] {
        store[uri] ?? []
    }

    public func clear() {
        store.removeAll()
    }
}
