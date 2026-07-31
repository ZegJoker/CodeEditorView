import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices

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

public struct MatchedProblem: Sendable, Hashable {
    public var uri: DocumentURI?
    public var path: String
    public var diagnostic: LanguageDiagnostic
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
        // Approximate UTF-16 location using line/col as offsets into a synthetic range.
        let location = lineNum * 200 + col
        let diagnostic = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: location, length: 1),
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
        return MatchedProblem(uri: uri, path: path, diagnostic: diagnostic)
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
                    results.append(MatchedProblem(uri: problem.uri, path: problem.path, diagnostic: diag))
                    if results.count >= matcher.maxProblems { return results }
                    matched = true
                    break
                }
            }
            if !matched { i += 1 } else if matchers.allSatisfy({ $0.multilineEndPattern == nil }) {
                i += 1
            }
        }
        return results
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
        lock.lock(); defer { lock.unlock() }
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
