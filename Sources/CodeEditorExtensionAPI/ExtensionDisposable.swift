import Foundation

/// Token returned from extension contribution registration.
public protocol ExtensionDisposable: AnyObject, Sendable {
    func dispose()
}

/// Closure-based disposal token.
public final class ExtensionRegistrationToken: ExtensionDisposable, @unchecked Sendable {
    private let lock = NSLock()
    private var onDispose: (() -> Void)?

    public init(onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    public func dispose() {
        lock.lock()
        let action = onDispose
        onDispose = nil
        lock.unlock()
        action?()
    }

    deinit {
        onDispose?()
    }
}

/// Composite dispose (LIFO).
public final class CompositeExtensionDisposable: ExtensionDisposable, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any ExtensionDisposable]

    public init(_ tokens: [any ExtensionDisposable] = []) {
        self.tokens = tokens
    }

    public func add(_ token: any ExtensionDisposable) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    public func dispose() {
        lock.lock()
        let list = tokens
        tokens.removeAll()
        lock.unlock()
        for token in list.reversed() {
            token.dispose()
        }
    }
}
