import Foundation

/// Immutable snapshot of registered language metadata (no parser factories).
public struct LanguageRegistrySnapshot: Sendable, Hashable {
    public var definitions: [LanguageDefinition]
    public var languageIDsWithParsers: Set<LanguageID>
    public var languageIDsWithQueries: Set<LanguageID>
    public var generation: UInt64
    /// Effective registration records (one per language ID currently in force).
    public var effectiveRecords: [LanguageRegistrationRecord]

    public init(
        definitions: [LanguageDefinition],
        languageIDsWithParsers: Set<LanguageID>,
        languageIDsWithQueries: Set<LanguageID>,
        generation: UInt64,
        effectiveRecords: [LanguageRegistrationRecord] = []
    ) {
        self.definitions = definitions
        self.languageIDsWithParsers = languageIDsWithParsers
        self.languageIDsWithQueries = languageIDsWithQueries
        self.generation = generation
        self.effectiveRecords = effectiveRecords
    }
}

public enum LanguageRegistrationDiagnostic: Sendable, Hashable, Equatable {
    case duplicateID(LanguageID)
    case ambiguousExtension(String, existing: LanguageID, incoming: LanguageID)
    case ambiguousFilename(String, existing: LanguageID, incoming: LanguageID)
    case missingParser(LanguageID)
    case missingHighlightsQuery(LanguageID)
    case ownershipMismatch(LanguageID, expected: LanguageRegistrationTokenID, actual: LanguageRegistrationTokenID?)
    case lowerPriorityIgnored(LanguageID, existingOwner: ContributionOwner, incomingOwner: ContributionOwner)
    case replacedByHigherPriority(LanguageID, previousOwner: ContributionOwner, newOwner: ContributionOwner)
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
/// Prefer constructing an instance owned by the host (LANG-N07). ``shared`` remains
/// for process-wide bootstrap compatibility; hosts and tests should pass explicit
/// registry instances when possible.
///
/// Language packs and the umbrella ``CodeEditorLanguages`` product register into
/// a registry at bootstrap. ``CodeEditorView`` / Tree-sitter never link
/// grammar C targets directly — they resolve parsers only through this registry.
public final class LanguageRegistry: @unchecked Sendable {
    public static let shared = LanguageRegistry()

    /// Factory that returns a tree-sitter `TSLanguage *` (as `OpaquePointer`), or `nil`.
    ///
    /// Returned pointers must remain valid for the process lifetime of static grammar
    /// symbols (see ``TSLanguageRef``).
    public typealias ParserFactory = @Sendable () -> OpaquePointer?
    /// Resolves a query file URL for a basename such as `"highlights"`.
    public typealias QueryURLProvider = @Sendable (_ queryName: String) -> URL?

    private struct Slot {
        var records: [LanguageRegistrationRecord]
        var parserFactories: [LanguageRegistrationTokenID: ParserFactory]
        var queryProviders: [LanguageRegistrationTokenID: QueryURLProvider]
        /// Legacy (pre-token) parser factory attached to the language without a token.
        var legacyParser: ParserFactory?
        /// Legacy query provider without a token.
        var legacyQuery: QueryURLProvider?
    }

    private let lock = NSLock()
    private var slots: [LanguageID: Slot] = [:]
    private var generation: UInt64 = 0

    /// Host-owned registry (LANG-N07). Prefer this over ``shared`` for multi-workspace
    /// and deterministic test isolation.
    public init() {}

    // MARK: - Owned registration (LANG-N01)

    /// Registers a language definition with explicit owner, priority, and disposal token.
    ///
    /// Multiple owners may contribute the same ``LanguageID``. The effective definition
    /// is the record with the highest priority, then the highest generation.
    /// Disposing a token removes **only** that record; other owners remain.
    @discardableResult
    public func register(
        _ definition: LanguageDefinition,
        owner: ContributionOwner,
        priority: Int = 0,
        policy: LanguageRegistrationPolicy = .retainByPriority,
        parserFactory: ParserFactory? = nil,
        queryProvider: QueryURLProvider? = nil
    ) -> LanguageOwnedRegistrationResult {
        lock.lock()
        defer { lock.unlock() }

        var diagnostics: [LanguageRegistrationDiagnostic] = []
        let id = definition.id

        // Ambiguity diagnostics against *effective* definitions of other languages.
        for ext in definition.fileExtensions {
            if let other = effectiveDefinitionsLocked().first(where: {
                $0.id != id && $0.fileExtensions.contains(ext)
            }) {
                diagnostics.append(.ambiguousExtension(ext, existing: other.id, incoming: id))
            }
        }
        for name in definition.filenames {
            if let other = effectiveDefinitionsLocked().first(where: {
                $0.id != id && $0.filenames.contains(name)
            }) {
                diagnostics.append(.ambiguousFilename(name, existing: other.id, incoming: id))
            }
        }

        var slot = slots[id] ?? Slot(records: [], parserFactories: [:], queryProviders: [:])
        if let existingWinner = Self.winningRecord(in: slot.records) {
            diagnostics.append(.duplicateID(id))
            switch policy {
            case .rejectUnlessHigherPriority:
                if priority <= existingWinner.priority {
                    diagnostics.append(
                        .lowerPriorityIgnored(
                            id,
                            existingOwner: existingWinner.owner,
                            incomingOwner: owner
                        )
                    )
                    // Still create a non-effective retained record? Policy says reject —
                    // do not store; return a dummy disposed-ready token that no-ops.
                    generation &+= 1
                    let tokenID = LanguageRegistrationTokenID()
                    let record = LanguageRegistrationRecord(
                        languageID: id,
                        owner: owner,
                        generation: generation,
                        priority: priority,
                        definition: definition,
                        tokenID: tokenID
                    )
                    let token = LanguageRegistrationToken(id: tokenID) { /* rejected; no-op */ }
                    // Mark as disposed conceptually: never inserted.
                    return LanguageOwnedRegistrationResult(
                        didBecomeEffective: false,
                        record: record,
                        token: token,
                        diagnostics: diagnostics
                    )
                }
            case .retainByPriority:
                if priority < existingWinner.priority {
                    diagnostics.append(
                        .lowerPriorityIgnored(
                            id,
                            existingOwner: existingWinner.owner,
                            incomingOwner: owner
                        )
                    )
                } else if priority > existingWinner.priority {
                    diagnostics.append(
                        .replacedByHigherPriority(
                            id,
                            previousOwner: existingWinner.owner,
                            newOwner: owner
                        )
                    )
                }
            }
        }

        generation &+= 1
        let tokenID = LanguageRegistrationTokenID()
        let record = LanguageRegistrationRecord(
            languageID: id,
            owner: owner,
            generation: generation,
            priority: priority,
            definition: definition,
            tokenID: tokenID
        )
        slot.records.append(record)
        if let parserFactory {
            slot.parserFactories[tokenID] = parserFactory
        }
        if let queryProvider {
            slot.queryProviders[tokenID] = queryProvider
        }
        slots[id] = slot

        let winner = Self.winningRecord(in: slot.records)
        let didBecomeEffective = winner?.tokenID == tokenID

        let token = LanguageRegistrationToken(id: tokenID) { [weak self] in
            self?.unregister(tokenID: tokenID)
        }
        return LanguageOwnedRegistrationResult(
            didBecomeEffective: didBecomeEffective,
            record: record,
            token: token,
            diagnostics: diagnostics
        )
    }

    /// Removes a single registration by token. Does not remove other owners' records.
    public func unregister(tokenID: LanguageRegistrationTokenID) {
        lock.lock()
        defer { lock.unlock() }
        for (id, var slot) in slots {
            let before = slot.records.count
            slot.records.removeAll { $0.tokenID == tokenID }
            slot.parserFactories.removeValue(forKey: tokenID)
            slot.queryProviders.removeValue(forKey: tokenID)
            if slot.records.count != before {
                generation &+= 1
                if slot.records.isEmpty && slot.legacyParser == nil && slot.legacyQuery == nil {
                    slots.removeValue(forKey: id)
                } else {
                    slots[id] = slot
                }
                return
            }
        }
    }

    /// Unregisters every record owned by `owner` (e.g. extension deactivation).
    public func unregister(owner: ContributionOwner) {
        lock.lock()
        defer { lock.unlock() }
        var touched = false
        for (id, var slot) in slots {
            let removeIDs = Set(slot.records.filter { $0.owner == owner }.map(\.tokenID))
            guard !removeIDs.isEmpty else { continue }
            slot.records.removeAll { removeIDs.contains($0.tokenID) }
            for tid in removeIDs {
                slot.parserFactories.removeValue(forKey: tid)
                slot.queryProviders.removeValue(forKey: tid)
            }
            touched = true
            if slot.records.isEmpty && slot.legacyParser == nil && slot.legacyQuery == nil {
                slots.removeValue(forKey: id)
            } else {
                slots[id] = slot
            }
        }
        if touched { generation &+= 1 }
    }

    public func record(for tokenID: LanguageRegistrationTokenID) -> LanguageRegistrationRecord? {
        lock.lock()
        defer { lock.unlock() }
        for slot in slots.values {
            if let r = slot.records.first(where: { $0.tokenID == tokenID }) {
                return r
            }
        }
        return nil
    }

    public func effectiveRecord(for id: LanguageID) -> LanguageRegistrationRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[id] else { return nil }
        return Self.winningRecord(in: slot.records)
    }

    public func allRecords(for id: LanguageID) -> [LanguageRegistrationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots[id]?.records ?? []
    }

    public func allEffectiveRecords() -> [LanguageRegistrationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots.values.compactMap { Self.winningRecord(in: $0.records) }
    }

    // MARK: - Definitions (legacy + convenience)

    /// Registers a definition under ``ContributionOwner/builtIn`` (backward compatible).
    ///
    /// Overwrites an existing built-in definition for the same ID while preserving
    /// other owners' records. Prefer the owner-aware ``register(_:owner:priority:policy:parserFactory:queryProvider:)``.
    @discardableResult
    public func register(_ definition: LanguageDefinition) -> LanguageRegistrationResult {
        let result = register(
            definition,
            owner: .builtIn,
            priority: definition.detectionPriority,
            policy: .retainByPriority
        )
        // If a previous built-in record existed, replace it: dispose prior built-in tokens.
        // The new record is already inserted; drop older built-in duplicates keeping newest.
        lock.lock()
        if var slot = slots[definition.id] {
            let builtIns = slot.records.filter { $0.owner == .builtIn }
            if builtIns.count > 1 {
                let keep = builtIns.max(by: { $0.generation < $1.generation })!
                let drop = builtIns.filter { $0.tokenID != keep.tokenID }.map(\.tokenID)
                slot.records.removeAll { drop.contains($0.tokenID) }
                for tid in drop {
                    slot.parserFactories.removeValue(forKey: tid)
                    slot.queryProviders.removeValue(forKey: tid)
                }
                slots[definition.id] = slot
            }
        }
        lock.unlock()
        return LanguageRegistrationResult(
            didRegister: true,
            diagnostics: result.diagnostics
        )
    }

    /// Removes **all** definitions/parsers/queries for a language ID (aggressive).
    /// Prefer token or owner-based unregister so other extensions survive (LANG-N01).
    public func unregisterDefinition(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        if slots.removeValue(forKey: id) != nil {
            generation &+= 1
        }
    }

    public func definition(for id: LanguageID) -> LanguageDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return Self.winningRecord(in: slots[id]?.records ?? [])?.definition
    }

    public func allDefinitions() -> [LanguageDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return effectiveDefinitionsLocked()
    }

    public func snapshot() -> LanguageRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let records = slots.values.compactMap { Self.winningRecord(in: $0.records) }
        var withParsers = Set<LanguageID>()
        var withQueries = Set<LanguageID>()
        for (id, slot) in slots {
            if Self.effectiveParserLocked(slot) != nil { withParsers.insert(id) }
            if Self.effectiveQueryLocked(slot) != nil { withQueries.insert(id) }
        }
        return LanguageRegistrySnapshot(
            definitions: records.map(\.definition),
            languageIDsWithParsers: withParsers,
            languageIDsWithQueries: withQueries,
            generation: generation,
            effectiveRecords: records
        )
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // MARK: - Parsers

    /// Registers a parser factory for the language (legacy, no ownership token).
    /// Prefer attaching the factory via owned ``register(_:owner:priority:policy:parserFactory:queryProvider:)``.
    public func registerParser(for id: LanguageID, factory: @escaping ParserFactory) {
        lock.lock()
        defer { lock.unlock() }
        var slot = slots[id] ?? Slot(records: [], parserFactories: [:], queryProviders: [:])
        slot.legacyParser = factory
        slots[id] = slot
        generation &+= 1
    }

    public func unregisterParser(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[id] else { return }
        slot.legacyParser = nil
        slot.parserFactories.removeAll()
        slots[id] = slot
        generation &+= 1
    }

    public func parser(for id: LanguageID) -> OpaquePointer? {
        let factory: ParserFactory?
        lock.lock()
        factory = slots[id].map { Self.effectiveParserLocked($0) } ?? nil
        lock.unlock()
        return factory?()
    }

    /// Owned language pointer wrapper when a parser is registered (LANG-N04).
    public func languageRef(for id: LanguageID) -> TSLanguageRef? {
        guard let pointer = parser(for: id) else { return nil }
        return TSLanguageRef(languageID: id, pointer: pointer, ownership: .staticGrammarSymbol)
    }

    public func hasParser(for id: LanguageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[id] else { return false }
        return Self.effectiveParserLocked(slot) != nil
    }

    // MARK: - Query resources

    public func registerQueryProvider(for id: LanguageID, provider: @escaping QueryURLProvider) {
        lock.lock()
        defer { lock.unlock() }
        var slot = slots[id] ?? Slot(records: [], parserFactories: [:], queryProviders: [:])
        slot.legacyQuery = provider
        slots[id] = slot
        generation &+= 1
    }

    public func unregisterQueryProvider(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[id] else { return }
        slot.legacyQuery = nil
        slot.queryProviders.removeAll()
        slots[id] = slot
        generation &+= 1
    }

    public func queryURL(for id: LanguageID, query: String) -> URL? {
        let provider: QueryURLProvider?
        lock.lock()
        provider = slots[id].map { Self.effectiveQueryLocked($0) } ?? nil
        lock.unlock()
        return provider?(query)
    }

    public func queryURL(for id: LanguageID, kind: QueryKind) -> URL? {
        queryURL(for: id, query: kind.fileBasename)
    }

    public func unregisterAll(for id: LanguageID) {
        lock.lock()
        defer { lock.unlock() }
        if slots.removeValue(forKey: id) != nil {
            generation &+= 1
        }
    }

    public func hasQueryProvider(for id: LanguageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[id] else { return false }
        return Self.effectiveQueryLocked(slot) != nil
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        slots.removeAll()
        generation &+= 1
    }

    /// Collect completeness diagnostics for a registered language.
    public func validateCompleteness(for id: LanguageID) -> [LanguageRegistrationDiagnostic] {
        var out: [LanguageRegistrationDiagnostic] = []
        lock.lock()
        let hasDef = slots[id].map { !$0.records.isEmpty } ?? false
        let hasParser = slots[id].map { Self.effectiveParserLocked($0) != nil } ?? false
        let provider = slots[id].map { Self.effectiveQueryLocked($0) } ?? nil
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

    // MARK: - Internals

    private static func winningRecord(in records: [LanguageRegistrationRecord]) -> LanguageRegistrationRecord? {
        records.max { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.generation < b.generation
        }
    }

    private func effectiveDefinitionsLocked() -> [LanguageDefinition] {
        slots.values.compactMap { Self.winningRecord(in: $0.records)?.definition }
    }

    private static func effectiveParserLocked(_ slot: Slot) -> ParserFactory? {
        if let winner = winningRecord(in: slot.records),
            let factory = slot.parserFactories[winner.tokenID]
        {
            return factory
        }
        // Prefer any token-bound factory, then legacy.
        if let any = slot.parserFactories.values.first {
            return any
        }
        return slot.legacyParser
    }

    private static func effectiveQueryLocked(_ slot: Slot) -> QueryURLProvider? {
        if let winner = winningRecord(in: slot.records),
            let provider = slot.queryProviders[winner.tokenID]
        {
            return provider
        }
        if let any = slot.queryProviders.values.first {
            return any
        }
        return slot.legacyQuery
    }
}
