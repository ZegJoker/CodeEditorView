import Foundation

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

    private init() {}

    // MARK: - Definitions

    public func register(_ definition: LanguageDefinition) {
        lock.lock()
        defer { lock.unlock() }
        definitions[definition.id] = definition
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

    // MARK: - Parsers

    public func registerParser(for id: LanguageID, factory: @escaping ParserFactory) {
        lock.lock()
        defer { lock.unlock() }
        parserFactories[id] = factory
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
    }

    public func queryURL(for id: LanguageID, query: String) -> URL? {
        let provider: QueryURLProvider?
        lock.lock()
        provider = queryProviders[id]
        lock.unlock()
        return provider?(query)
    }

    public func hasQueryProvider(for id: LanguageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return queryProviders[id] != nil
    }

    // MARK: - Testing / reset

    /// Removes all registrations. Intended for unit tests only.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        definitions.removeAll()
        parserFactories.removeAll()
        queryProviders.removeAll()
    }
}
