import Foundation

/// Namespaced command identifier (e.g. `codeeditor.edit.indent`).
///
/// ## Grammar (CMD-N02 / audit recommended)
/// ```
/// ^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$
/// ```
/// Length 1…200. Uppercase is rejected. Host namespace `codeeditor` is reserved.
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Maximum accepted length for a command ID.
    public static let maxLength = 200

    /// Host-owned namespace prefixes that extensions must not claim.
    public static let reservedHostNamespacePrefixes: [String] = ["codeeditor"]

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Validating initializer — throws on invalid grammar.
    public init(validating raw: String) throws {
        guard Self.isValid(raw) else {
            throw CommandIdentityError.invalidID(raw)
        }
        self.rawValue = raw
    }

    /// String literal convenience for built-in catalogs. Traps if invalid.
    public init(stringLiteral value: String) {
        guard let id = CommandID(rawValue: value) else {
            fatalError("Invalid CommandID string literal: \(value)")
        }
        self = id
    }

    /// Validates against the recommended lowercase grammar.
    public static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= maxLength else { return false }
        // ^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$
        let pattern = #"^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length == (raw as NSString).length
    }

    /// Whether `raw` starts with a reserved host namespace prefix.
    public static func isReservedHostNamespace(_ raw: String) -> Bool {
        let head = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? raw
        return reservedHostNamespacePrefixes.contains(head)
    }
}

public enum CommandIdentityError: Error, Sendable, Equatable {
    case invalidID(String)
    case duplicateRegistration(String)
    case ownershipMismatch(String)
}

/// Registration policy for ``CommandRegistry/register(_:policy:)`` (CMD-N01).
public enum CommandRegistrationPolicy: Sendable, Equatable {
    /// Reject when the command ID is already registered (default).
    case rejectDuplicate
    /// Replace only when the caller proves ownership of the existing registration token.
    case replaceOwnedRegistration(expectedToken: CommandRegistrationToken.ID)
}

/// Diagnostic events emitted by registration (CMD-N01).
public enum CommandRegistrationDiagnostic: Sendable, Equatable {
    case replacedOwnedRegistration(commandID: CommandID, previousToken: CommandRegistrationToken.ID)
    case rejectedDuplicate(commandID: CommandID)
    case ownershipMismatch(commandID: CommandID, expected: CommandRegistrationToken.ID, actual: CommandRegistrationToken.ID?)
}

/// Command grouping for palette / menus.
public struct CommandCategory: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let edit = CommandCategory(rawValue: "Edit")
    public static let find = CommandCategory(rawValue: "Find")
    public static let view = CommandCategory(rawValue: "View")
    public static let navigate = CommandCategory(rawValue: "Navigate")
    public static let general = CommandCategory(rawValue: "General")
}

/// Placement metadata (menus / toolbar / palette). Data only — no UI types.
public struct CommandPlacement: Sendable, Hashable, Codable {
    public var menuPath: [String]?
    public var toolbarGroup: String?
    public var paletteHidden: Bool

    public init(
        menuPath: [String]? = nil,
        toolbarGroup: String? = nil,
        paletteHidden: Bool = false
    ) {
        self.menuPath = menuPath
        self.toolbarGroup = toolbarGroup
        self.paletteHidden = paletteHidden
    }

    public static let `default` = CommandPlacement()
    public static let hiddenInPalette = CommandPlacement(paletteHidden: true)
}

/// Token returned from registry registration. Call ``dispose()`` to unregister (CMD-N03).
///
/// `deinit` does **not** schedule unstructured unregister work; callers must dispose explicitly.
public protocol CommandDisposable: AnyObject {
    func dispose()
}

/// Runs a MainActor unregister/dispose body synchronously (CMD-N03 — no unstructured Task).
private func runMainActorDispose(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}

/// Simple composite / ad-hoc disposable (no registration ownership ID).
public final class RegistrationToken: CommandDisposable, @unchecked Sendable {
    private let lock = NSLock()
    private var onDispose: (@MainActor () -> Void)?
    private var disposed = false

    public init(onDispose: @escaping @MainActor () -> Void) {
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
        guard let action else { return }
        runMainActorDispose(action)
    }

    // CMD-N03: no deinit cleanup — explicit dispose only. Never schedule
    // unstructured MainActor tasks from deinit (indeterminate unregister timing).
}

/// Ownership-bearing registration token for command registry entries (CMD-N01 / CMD-N03).
public final class CommandRegistrationToken: CommandDisposable, @unchecked Sendable {
    public typealias ID = UUID

    public let id: ID
    private let lock = NSLock()
    private var onDispose: (@MainActor () -> Void)?
    private var disposed = false

    public var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    public init(id: ID = UUID(), onDispose: @escaping @MainActor () -> Void) {
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
        guard let action else { return }
        runMainActorDispose(action)
    }

    // CMD-N03: never schedule unstructured Task unregister from deinit.
    // Callers must dispose() explicitly for deterministic unregistration.
}
