/// How a capability is offered on a given host profile.
public enum CapabilityAvailability: Sendable, Hashable, Codable {
    /// Implemented with local OS resources (process, PTY, Git CLI, …).
    case local
    /// Available only through a remote provider.
    case remote
    /// Host application must inject an implementation.
    case hostProvided
    /// Declarative / data-only path (no executable side effects).
    case dataOnly
    /// Not offered; operations must fail before starting work.
    case unavailable(reason: String)

    public var isLocallyAvailable: Bool {
        if case .local = self { return true }
        return false
    }
}
