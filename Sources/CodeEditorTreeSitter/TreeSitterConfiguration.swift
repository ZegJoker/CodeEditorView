import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Supplies language catalog + compiled highlight configurations to the generic Tree-sitter layer.
///
/// Implemented by the umbrella (`CodeEditorLanguages`) and/or individual language packs.
/// ``TreeSitterHighlightProvider`` never imports grammar targets — it only uses this provider.
public protocol TreeSitterConfigurationProviding: Sendable {
    func codeLanguage(id: String) -> CodeLanguage?
    func languageConfiguration(for languageID: String) throws -> LanguageConfiguration?
}

/// Process-wide language configuration registry isolated behind an actor (TS-001).
public actor TreeSitterLanguageRuntime {
    public static let shared = TreeSitterLanguageRuntime()

    private var configurationProvider: (any TreeSitterConfigurationProviding)?
    private var onDemandBootstrap: (@Sendable () -> Void)?

    public func install(_ provider: any TreeSitterConfigurationProviding) {
        configurationProvider = provider
    }

    public func setBootstrap(_ bootstrap: (@Sendable () -> Void)?) {
        onDemandBootstrap = bootstrap
    }

    public func resolveProvider() -> (any TreeSitterConfigurationProviding)? {
        if let configurationProvider { return configurationProvider }
        onDemandBootstrap?()
        return configurationProvider
    }

    public func reset() {
        configurationProvider = nil
        onDemandBootstrap = nil
    }
}

/// Process-wide installation point for the active Tree-sitter configuration provider.
///
/// Stored properties remain for ABI compatibility with language packs/tests.
/// ``TreeSitterLanguageRuntime`` mirrors installs for actor-safe resolution.
public enum TreeSitterLanguageEnvironment {
    nonisolated(unsafe) public static var configurationProvider: (any TreeSitterConfigurationProviding)?

    /// Optional hook invoked when a configuration is needed but no provider is installed yet.
    nonisolated(unsafe) public static var onDemandBootstrap: (@Sendable () -> Void)?

    public static func install(_ provider: any TreeSitterConfigurationProviding) {
        configurationProvider = provider
        Task { await TreeSitterLanguageRuntime.shared.install(provider) }
    }

    public static func reset() {
        configurationProvider = nil
        onDemandBootstrap = nil
        Task { await TreeSitterLanguageRuntime.shared.reset() }
    }

    /// Returns the installed provider, running ``onDemandBootstrap`` once if needed.
    public static func resolveProvider() -> (any TreeSitterConfigurationProviding)? {
        if let configurationProvider { return configurationProvider }
        onDemandBootstrap?()
        return configurationProvider
    }
}
