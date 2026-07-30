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

    public init(
        id: ProblemMatcherID,
        owner: String,
        pattern: NSRegularExpression,
        fileGroup: Int = 1,
        lineGroup: Int = 2,
        columnGroup: Int = 3,
        severityGroup: Int? = nil,
        messageGroup: Int = 4
    ) {
        self.id = id
        self.owner = owner
        self.pattern = pattern
        self.fileGroup = fileGroup
        self.lineGroup = lineGroup
        self.columnGroup = columnGroup
        self.severityGroup = severityGroup
        self.messageGroup = messageGroup
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
        cwd: URL?
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
        let path = group(matcher.fileGroup) ?? ""
        let lineNum = max(0, (Int(group(matcher.lineGroup) ?? "1") ?? 1) - 1)
        let col = max(0, (Int(group(matcher.columnGroup) ?? "1") ?? 1) - 1)
        let severityRaw = matcher.severityGroup.flatMap { group($0) }?.lowercased()
        let severity: LanguageDiagnosticSeverity
        switch severityRaw {
        case "error": severity = .error
        case "warning": severity = .warning
        case "note", "info", "information": severity = .information
        default: severity = .error
        }

        // Approximate UTF-16 range on a synthetic line (host remaps with real file text if needed).
        let location = col
        let diag = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: location, length: max(1, message.count)),
            severity: severity,
            message: message,
            source: matcher.owner
        )

        var uri: DocumentURI?
        if !path.isEmpty {
            if path.hasPrefix("/") {
                uri = DocumentURI(fileURL: URL(fileURLWithPath: path))
            } else if let cwd {
                uri = DocumentURI(fileURL: cwd.appendingPathComponent(path))
            }
        }
        _ = lineNum
        return MatchedProblem(uri: uri, path: path, diagnostic: diag)
    }

    public static func matchAll(
        text: String,
        matchers: [ProblemMatcher],
        cwd: URL?
    ) -> [MatchedProblem] {
        var results: [MatchedProblem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for matcher in matchers {
                if let p = match(line: String(line), matcher: matcher, cwd: cwd) {
                    results.append(p)
                }
            }
        }
        return results
    }
}

public protocol TaskDiagnosticsSink: Sendable {
    func publish(uri: DocumentURI, diagnostics: [LanguageDiagnostic], owner: String) async
}

public actor InMemoryTaskDiagnosticsSink: TaskDiagnosticsSink {
    public private(set) var byURI: [DocumentURI: [LanguageDiagnostic]] = [:]

    public init() {}

    public func publish(uri: DocumentURI, diagnostics: [LanguageDiagnostic], owner: String) async {
        _ = owner
        byURI[uri] = diagnostics
    }

    public func diagnostics(for uri: DocumentURI) -> [LanguageDiagnostic] {
        byURI[uri] ?? []
    }
}
