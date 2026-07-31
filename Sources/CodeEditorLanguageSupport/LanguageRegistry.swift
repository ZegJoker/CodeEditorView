import Foundation

/// Immutable snapshot of registered language metadata (no parser factories).
public struct LanguageRegistrySnapshot: Sendable, Hashable {
    public var definitions: [LanguageDefinition]
    public var languageIDsWithParsers: Set<LanguageID>
    public var languageIDsWithQueries: Set<LanguageID>
    public var generation: UInt64

    public init(
        definitions: [LanguageDefinition],
        languageIDsWithParsers: Set<LanguageID>,
        languageIDsWithQueries: Set<LanguageID>,
        generation: UInt64
    ) {
        self.definitions = definitions
        self.languageIDsWithParsers = languageIDsWithParsers
        self.languageIDsWithQueries = languageIDsWithQueries
        self.generation = generation
    }
}

public enum LanguageRegistrationDiagnostic: Sendable, Hashable, Equatable {
    case duplicateID(LanguageID)
    case ambiguousExtension(String, existing: LanguageID, incoming: LanguageID)
    case ambiguousFilename(String, existing: LanguageID, incoming: LanguageID)
    case missingParser(LanguageID)
    case missingHighlightsQuery(LanguageID)
}

public struct LanguageRegistrationResult: Sendable, Hashable {
    public var didRegister: Bool
    public var diagnostics: [LanguageRegistrationDiagnostic]

    public init(didRegister: Bool, diagnostics: [LanguageRegistrationDiagnostic] = []) {
        self.didRegister = didRegister
        self.diagnostics = diagnostics
    }
}

/// Thread-safe registry for language metadata, parser factories, and query resources.
///
/// Language packs and the umbrella ``CodeEditorLanguages`` product register into
/// this shared registry at bootstrap. ``CodeEditorView`` / Tree-sitter never link
/// grammar C targets directly — they resolve parsers only through this registry.
public final class LanguageRegistry: @unchecked Sendable {
    public static let shared = LanguageRegistry()

    /// Factory that returns a tree-sitter `TSLanguage *` (as `OpaquePointer`), or `nil`.
    public typealias ParserFactory = @Sendable () -> OpaquePointer?
    /// Resolves a query file URL for a basename such as `"highlights"`.
    public typealias QueryURLProvider = @Sendable (_ queryName: String) -> URL?

    private let lock = NSLock()
    private var definitions: [LanguageID: LanguageDefinition] = [:]
    private var parserFactories: [LanguageID: ParserFactory] = [:]
    private var queryProviders: [LanguageID: QueryURLProvider] = [:]
    private var generation: UInt64 = 0

    /// Process-wide default used by language packs.
    public init() {}

    // MARK: - Definitions

    @discardableResult
    public func register(_ definition: LanguageDefinition) -> LanguageRegistrationResult {
        lock.lock()
        defer { lock.unlock() }
        var diagnostics: [LanguageRegistrationDiagnostic] = []
        if definitions[definition.id] != nil {
            diagnostics.append(.duplicateID(definition.id))
        }
        for ext in definition.fileExtensions {
            if let other = definitions.values.first(where: {
                $0.id != definition.id && $0.fileExtensions.contains(ext)
            }) {
                diagnostics.append(.ambiguousExtension(ext, existing: other.id, incoming: definition.id))
            }
        }
        for name in definition.filenames {
            if let other = definitions.values.first(where: {
                $0.id != definition.id && $0.filenames.contains(name)
            }) {
                diagnostics.append(.ambiguousFilename(name, existing: other.id, incoming: definition.id))
            }
        }
        definitions[definition.id] = definition
        generation &+= 1
        return LanguageRegistrationResult(didRegister: true, diagnostics: diagnostics)
    }

    /// Removes a language definition (e.g. extension deactivation).
    public func unregisterDefinition(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        definitions.removeValue(forKey: id)
        generation &+= 1
    }

    public func definition(for id: LanguageID) -> LanguageDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return definitions[id]
    }

    public func allDefinitions() -> [LanguageDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return Array(definitions.values)
    }

    public func snapshot() -> LanguageRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LanguageRegistrySnapshot(
            definitions: Array(definitions.values),
            languageIDsWithParsers: Set(parserFactories.keys),
            languageIDsWithQueries: Set(queryProviders.keys),
            generation: generation
        )
    }

    // MARK: - Parsers

    public func registerParser(for id: LanguageID, factory: @escaping ParserFactory) {
        lock.lock()
        defer { lock.unlock() }
        parserFactories[id] = factory
        generation &+= 1
    }

    public func unregisterParser(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        parserFactories.removeValue(forKey: id)
        generation &+= 1
    }

    public func parser(for id: LanguageID) -> OpaquePointer? {
        let factory: ParserFactory?
        lock.lock()
        factory = parserFactories[id]
        lock.unlock()
        return factory?()
    }

    public func hasParser(for id: LanguageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parserFactories[id] != nil
    }

    // MARK: - Query resources

    public func registerQueryProvider(for id: LanguageID, provider: @escaping QueryURLProvider) {
        lock.lock()
        defer { lock.unlock() }
        queryProviders[id] = provider
        generation &+= 1
    }

    public func unregisterQueryProvider(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        queryProviders.removeValue(forKey: id)
        generation &+= 1
    }

    public func queryURL(for id: LanguageID, query: String) -> URL? {
        let provider: QueryURLProvider?
        lock.lock()
        provider = queryProviders[id]
        lock.unlock()
        return provider?(query)
    }

    public func queryURL(for id: LanguageID, kind: QueryKind) -> URL? {
        queryURL(for: id, query: kind.fileBasename)
    }

    public func unregisterAll(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        definitions.removeValue(forKey: id)
        parserFactories.removeValue(forKey: id)
        queryProviders.removeValue(forKey: id)
        generation &+= 1
    }

    public func hasQueryProvider(for id: LanguageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return queryProviders[id] != nil
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        definitions.removeAll()
        parserFactories.removeAll()
        queryProviders.removeAll()
        generation &+= 1
    }

    /// Collect completeness diagnostics for a registered language.
    public func validateCompleteness(for id: LanguageID) -> [LanguageRegistrationDiagnostic] {
        var out: [LanguageRegistrationDiagnostic] = []
        lock.lock()
        let hasDef = definitions[id] != nil
        let hasParser = parserFactories[id] != nil
        let provider = queryProviders[id]
        lock.unlock()
        guard hasDef else { return out }
        if !hasParser { out.append(.missingParser(id)) }
        if let provider, provider("highlights") == nil {
            out.append(.missingHighlightsQuery(id))
        } else if provider == nil {
            out.append(.missingHighlightsQuery(id))
        }
        return out
    }
}
