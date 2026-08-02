import Foundation

/// Stable ID for a single language registration attempt (LANG-N01).
public struct LanguageRegistrationTokenID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Immutable registration bookkeeping for one language contribution (LANG-N01).
///
/// A language ID may have multiple concurrent records from different owners; the
/// registry surfaces the effective (winning) record by priority then generation.
public struct LanguageRegistrationRecord: Sendable, Hashable {
    public let languageID: LanguageID
    public let owner: ContributionOwner
    public let generation: UInt64
    public let priority: Int
    public let definition: LanguageDefinition
    public let tokenID: LanguageRegistrationTokenID

    public init(
        languageID: LanguageID,
        owner: ContributionOwner,
        generation: UInt64,
        priority: Int,
        definition: LanguageDefinition,
        tokenID: LanguageRegistrationTokenID
    ) {
        self.languageID = languageID
        self.owner = owner
        self.generation = generation
        self.priority = priority
        self.definition = definition
        self.tokenID = tokenID
    }

    /// Alias for audit `LanguageDescriptor` naming.
    public var descriptor: LanguageDefinition { definition }
}

/// Explicit dispose-only token; disposing removes **only** this registration (LANG-N01).
///
/// No deinit cleanup — hosts and extension registrars must call ``dispose()``
/// (matches command registration policy).
public final class LanguageRegistrationToken: @unchecked Sendable {
    public let id: LanguageRegistrationTokenID
    private let lock = NSLock()
    private var onDispose: (@Sendable () -> Void)?
    private var disposed = false

    public var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    public init(
        id: LanguageRegistrationTokenID = LanguageRegistrationTokenID(),
        onDispose: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.onDispose = onDispose
    }

    public func dispose() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        disposed = true
        let action = onDispose
        onDispose = nil
        lock.unlock()
        action?()
    }
}

/// How the registry handles a contribution when a language ID is already present.
public enum LanguageRegistrationPolicy: Sendable, Hashable {
    /// Keep existing effective registration when incoming priority is lower;
    /// still retain the incoming record so a later dispose of the winner can
    /// promote it. Always records the contribution.
    case retainByPriority
    /// Reject when an effective registration already exists and incoming priority
    /// does not strictly exceed the current winner.
    case rejectUnlessHigherPriority
}

/// Outcome of a token-bearing language registration.
public struct LanguageOwnedRegistrationResult: Sendable {
    public var didBecomeEffective: Bool
    public var record: LanguageRegistrationRecord
    public var token: LanguageRegistrationToken
    public var diagnostics: [LanguageRegistrationDiagnostic]

    public init(
        didBecomeEffective: Bool,
        record: LanguageRegistrationRecord,
        token: LanguageRegistrationToken,
        diagnostics: [LanguageRegistrationDiagnostic] = []
    ) {
        self.didBecomeEffective = didBecomeEffective
        self.record = record
        self.token = token
        self.diagnostics = diagnostics
    }
}
