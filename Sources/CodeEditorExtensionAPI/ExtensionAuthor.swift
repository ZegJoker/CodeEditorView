import Foundation

/// Transport-neutral author context surface (host may provide richer concrete context).
public protocol ExtensionAuthorContext: AnyObject, Sendable {
    var extensionID: ExtensionID { get }
    var grantedPermissions: Set<ExtensionPermission> { get }
    func requirePermission(_ permission: ExtensionPermission) throws
    func hasPermission(_ permission: ExtensionPermission) -> Bool
    func track(_ disposable: any ExtensionDisposable)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

/// In-process / multi-driver extension author contract.
public protocol CodeEditorExtension: Sendable {
    var manifest: ExtensionManifest { get }
    func activate(in context: any ExtensionAuthorContext) async throws
    func deactivate() async
}

extension CodeEditorExtension {
    public func deactivate() async {}
}

/// Preferred alias for authors.
public typealias EditorExtension = CodeEditorExtension
