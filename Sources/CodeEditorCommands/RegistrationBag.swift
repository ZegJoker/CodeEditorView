import Foundation

/// Owns registration tokens for a host lifetime (CMD-001 / audit §9.1).
///
/// Contributions that return a ``RegistrationToken`` must be retained here so
/// `deinit` does not unregister them while the host is still alive. Call
/// ``disposeAll()`` only on host shutdown.
@MainActor
public final class RegistrationBag {
    private var tokens: [any CommandDisposable] = []
    private var disposed = false

    public init() {}

    public var count: Int { tokens.count }
    public var isDisposed: Bool { disposed }

    /// Retain a disposable for the bag lifetime.
    @discardableResult
    public func retain(_ token: any CommandDisposable) -> any CommandDisposable {
        precondition(!disposed, "RegistrationBag already disposed")
        tokens.append(token)
        return token
    }

    /// Dispose every retained token and clear the bag.
    public func disposeAll() {
        guard !disposed else { return }
        disposed = true
        for token in tokens {
            token.dispose()
        }
        tokens.removeAll()
    }
}
