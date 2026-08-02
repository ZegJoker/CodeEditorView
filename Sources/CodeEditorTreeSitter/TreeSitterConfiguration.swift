import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Supplies language catalog + compiled highlight configurations to the generic Tree-sitter layer.
public protocol TreeSitterConfigurationProviding: Sendable {
    func codeLanguage(id: String) -> CodeLanguage?
    func languageConfiguration(for languageID: String) throws -> LanguageConfiguration?
}

/// Process-wide language configuration registry isolated behind an actor (TS-001).
public actor TreeSitterLanguageRuntime {
    public static let shared = TreeSitterLanguageRuntime()

    private var configurationProvider: (any TreeSitterConfigurationProviding)?
    private var onDemandBootstrap: (@Sendable () -> Void)?
    private var generation: UInt64 = 0

    public func install(_ provider: any TreeSitterConfigurationProviding) {
        configurationProvider = provider
        generation &+= 1
    }

    public func setBootstrap(_ bootstrap: (@Sendable () -> Void)?) {
        onDemandBootstrap = bootstrap
    }

    public func resolveProvider() -> (any TreeSitterConfigurationProviding)? {
        if let configurationProvider { return configurationProvider }
        onDemandBootstrap?()
        return configurationProvider
    }

    public func currentGeneration() -> UInt64 { generation }

    public func reset() {
        configurationProvider = nil
        onDemandBootstrap = nil
        generation &+= 1
    }
}

/// Thread-safe process-wide façade (no `nonisolated(unsafe)`).
public enum TreeSitterLanguageEnvironment: Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var provider: (any TreeSitterConfigurationProviding)?
        var bootstrap: (@Sendable () -> Void)?
    }

    private static let box = Box()

    /// Whether a provider is currently installed (synchronous).
    public static var hasProvider: Bool {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.provider != nil
    }

    /// Back-compat: read-only peek (prefer ``hasProvider`` / async resolve).
    public static var configurationProvider: (any TreeSitterConfigurationProviding)? {
        get {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.provider
        }
        set {
            if let newValue {
                install(newValue)
            } else {
                reset()
            }
        }
    }

    /// Back-compat bootstrap hook.
    public static var onDemandBootstrap: (@Sendable () -> Void)? {
        get {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.bootstrap
        }
        set {
            box.lock.lock()
            box.bootstrap = newValue
            box.lock.unlock()
            Task { await TreeSitterLanguageRuntime.shared.setBootstrap(newValue) }
        }
    }

    public static func install(_ provider: any TreeSitterConfigurationProviding) {
        box.lock.lock()
        box.provider = provider
        box.lock.unlock()
        Task { await TreeSitterLanguageRuntime.shared.install(provider) }
    }

    public static func reset() {
        box.lock.lock()
        box.provider = nil
        box.bootstrap = nil
        box.lock.unlock()
        Task { await TreeSitterLanguageRuntime.shared.reset() }
    }

    public static func resolveProvider() -> (any TreeSitterConfigurationProviding)? {
        box.lock.lock()
        if let p = box.provider {
            box.lock.unlock()
            return p
        }
        let boot = box.bootstrap
        box.lock.unlock()
        boot?()
        box.lock.lock()
        let p = box.provider
        box.lock.unlock()
        return p
    }

    public static func resolveProviderAsync() async -> (any TreeSitterConfigurationProviding)? {
        let p = await TreeSitterLanguageRuntime.shared.resolveProvider()
        if let p {
            // Update sync cache from a non-async helper.
            installCacheOnly(p)
        }
        return p
    }

    private static func installCacheOnly(_ provider: any TreeSitterConfigurationProviding) {
        box.lock.lock()
        box.provider = provider
        box.lock.unlock()
    }
}
