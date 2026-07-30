import Foundation

/// Namespaced command identifier (e.g. `codeeditor.edit.indent`).
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
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
