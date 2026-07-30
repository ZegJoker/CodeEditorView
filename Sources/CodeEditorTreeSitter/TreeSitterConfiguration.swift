import Foundation
import SwiftTreeSitter
import CodeEditorLanguageSupport

/// Supplies language catalog + compiled highlight configurations to the generic Tree-sitter layer.
///
/// Implemented by the umbrella (`CodeEditorLanguages`) and/or individual language packs.
/// ``TreeSitterHighlightProvider`` never imports grammar targets — it only uses this provider.
public protocol TreeSitterConfigurationProviding: Sendable {
    func codeLanguage(id: String) -> CodeLanguage?
    func languageConfiguration(for languageID: String) throws -> LanguageConfiguration?
}

/// Process-wide installation point for the active Tree-sitter configuration provider.
public enum TreeSitterLanguageEnvironment {
    nonisolated(unsafe) public static var configurationProvider: (any TreeSitterConfigurationProviding)?

    /// Optional hook invoked when a configuration is needed but no provider is installed yet.
    /// Language pack modules set this so the first highlight load can auto-bootstrap.
    nonisolated(unsafe) public static var onDemandBootstrap: (@Sendable () -> Void)?

    public static func install(_ provider: any TreeSitterConfigurationProviding) {
        configurationProvider = provider
    }

    public static func reset() {
        configurationProvider = nil
        onDemandBootstrap = nil
    }

    /// Returns the installed provider, running ``onDemandBootstrap`` once if needed.
    public static func resolveProvider() -> (any TreeSitterConfigurationProviding)? {
        if let configurationProvider { return configurationProvider }
        onDemandBootstrap?()
        return configurationProvider
    }
}
