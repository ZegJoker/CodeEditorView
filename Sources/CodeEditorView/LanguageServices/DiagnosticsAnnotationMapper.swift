import CodeEditorCore
import CodeEditorLanguageServices
import Foundation

/// Maps language-service diagnostics to View ``LineAnnotation`` models.
public enum DiagnosticsAnnotationMapper {
    public static func annotations(
        from diagnostics: [LanguageDiagnostic],
        documentText: String
    ) -> [LineAnnotation] {
        diagnostics.map { diagnostic in
            let cursor = LanguageServiceTextGeometry.cursorPosition(
                for: diagnostic.range.nsRange,
                in: documentText
            )
            return LineAnnotation(
                line: cursor.line,
                column: cursor.column,
                severity: mapSeverity(diagnostic.severity),
                message: diagnostic.message,
                detail: detail(for: diagnostic),
                range: diagnostic.range.nsRange
            )
        }
    }

    public static func mapSeverity(_ severity: LanguageDiagnosticSeverity) -> DiagnosticSeverity {
        switch severity {
        case .error: return .error
        case .warning: return .warning
        case .information: return .info
        case .hint: return .live
        }
    }

    private static func detail(for diagnostic: LanguageDiagnostic) -> String? {
        var parts: [String] = []
        if let source = diagnostic.source { parts.append(source) }
        if let code = diagnostic.code { parts.append(code) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
