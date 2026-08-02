import Foundation

/// Namespaced command identifier (e.g. `codeeditor.edit.indent`).
///
/// ## Grammar (audit §9.3)
/// ```
/// segment = [a-z][a-z0-9_-]*
/// command-id = segment ("." segment)+
/// ```
/// Length ≤ 200. Lowercase preferred; stored as provided after validation of allowed charset.
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

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

    public static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 200 else { return false }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let segment = #"^[a-zA-Z][a-zA-Z0-9_-]*$"#
        let regex = try! NSRegularExpression(pattern: segment)
        for p in parts {
            if p.isEmpty { return false }
            let range = NSRange(p.startIndex..<p.endIndex, in: p)
            if regex.firstMatch(in: p, options: [], range: range) == nil { return false }
        }
        return true
    }
}

public enum CommandIdentityError: Error, Sendable, Equatable {
    case invalidID(String)
    case duplicateRegistration(String)
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

/// Token returned from registry registration. Call ``dispose()`` to unregister.
public protocol CommandDisposable: AnyObject {
    func dispose()
}

public final class RegistrationToken: CommandDisposable {
    private var onDispose: (() -> Void)?

    public init(onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    public func dispose() {
        onDispose?()
        onDispose = nil
    }

    deinit {
        onDispose?()
    }
}
