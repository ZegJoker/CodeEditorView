import Foundation

/// Explicit enable/disable matrix for native text services (UI-005 / audit §11.7).
///
/// Defaults are code-editor oriented: disable “helpful” substitutions that corrupt source.
public struct EditorTextServicesPolicy: Sendable, Equatable, Hashable {
    public var allowsSpellingCorrections: Bool
    public var allowsAutocorrection: Bool
    public var allowsSmartQuotes: Bool
    public var allowsSmartDashes: Bool
    public var allowsSmartInsertDelete: Bool
    public var allowsDataDetectors: Bool
    public var allowsServicesMenu: Bool
    public var allowsDictation: Bool
    public var allowsTextReplacement: Bool

    public init(
        allowsSpellingCorrections: Bool = false,
        allowsAutocorrection: Bool = false,
        allowsSmartQuotes: Bool = false,
        allowsSmartDashes: Bool = false,
        allowsSmartInsertDelete: Bool = false,
        allowsDataDetectors: Bool = false,
        allowsServicesMenu: Bool = true,
        allowsDictation: Bool = true,
        allowsTextReplacement: Bool = false
    ) {
        self.allowsSpellingCorrections = allowsSpellingCorrections
        self.allowsAutocorrection = allowsAutocorrection
        self.allowsSmartQuotes = allowsSmartQuotes
        self.allowsSmartDashes = allowsSmartDashes
        self.allowsSmartInsertDelete = allowsSmartInsertDelete
        self.allowsDataDetectors = allowsDataDetectors
        self.allowsServicesMenu = allowsServicesMenu
        self.allowsDictation = allowsDictation
        self.allowsTextReplacement = allowsTextReplacement
    }

    /// Code-editor defaults (Stable claim: intentional disables are explicit).
    public static let codeEditor = EditorTextServicesPolicy()

    /// Plain-prose defaults (for hosts that opt in).
    public static let prose = EditorTextServicesPolicy(
        allowsSpellingCorrections: true,
        allowsAutocorrection: true,
        allowsSmartQuotes: true,
        allowsSmartDashes: true,
        allowsSmartInsertDelete: true,
        allowsDataDetectors: true,
        allowsServicesMenu: true,
        allowsDictation: true,
        allowsTextReplacement: true
    )
}
