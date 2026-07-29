import Foundation

/// A message displayed inline on a code line (mchakravarty CodeEditorView–style).
///
/// Hosts supply these via ``EditorController/setAnnotations(_:)``. The package does not
/// run LSP; apps map build/linter/LSP issues into this model.
public struct LineAnnotation: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Zero-based line index.
    public var line: Int
    /// Zero-based UTF-16 column within the line (0 = whole-line message).
    public var column: Int
    public var severity: DiagnosticSeverity
    /// Short one-line summary shown in the trailing inline chip and popup title.
    public var message: String
    /// Optional longer detail shown only in the expanded popup (mchakravarty `description`).
    public var detail: String?
    /// Optional precise document UTF-16 range for underline emphasis.
    public var range: NSRange?

    public init(
        id: UUID = UUID(),
        line: Int,
        column: Int = 0,
        severity: DiagnosticSeverity,
        message: String,
        detail: String? = nil,
        range: NSRange? = nil
    ) {
        self.id = id
        self.line = max(0, line)
        self.column = max(0, column)
        self.severity = severity
        self.message = message
        self.detail = detail
        self.range = range
    }
}

/// Metrics for trailing inline message chips (mchakravarty `MessageInlineView`).
public enum AnnotationMetrics: Sendable {
    /// Minimum width of the trailing chip.
    public static let minimumChipWidth: CGFloat = 60
    /// Max width as a fraction of the content width (remaining space on the right).
    public static let maxWidthFraction: CGFloat = 0.45
    public static let cornerRadius: CGFloat = 5
    public static let horizontalPadding: CGFloat = 4
    public static let iconSize: CGFloat = 11
    public static let trailingInset: CGFloat = 8
    /// Gap between end of code and the chip.
    public static let codeGap: CGFloat = 12

    /// Priority for “top” summary: lower is more severe / shown first.
    public static func priority(_ severity: DiagnosticSeverity) -> Int {
        switch severity {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .live: return 3
        }
    }

    /// No extra line height — chips sit in the trailing margin of the code line.
    public static func bandHeight(forCount count: Int) -> CGFloat { 0 }
}
