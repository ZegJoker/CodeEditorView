import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Versioned method identifiers for the extension wire protocol.
public struct ExtensionMethodID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    // Lifecycle
    public static let activate: ExtensionMethodID = "lifecycle.activate"
    public static let deactivate: ExtensionMethodID = "lifecycle.deactivate"
    public static let ping: ExtensionMethodID = "lifecycle.ping"

    // Language services (S2 subset for dual-run parity)
    public static let completion: ExtensionMethodID = "ls.completion"
    public static let hover: ExtensionMethodID = "ls.hover"
    public static let definition: ExtensionMethodID = "ls.definition"
    public static let diagnostics: ExtensionMethodID = "ls.diagnostics"

    // Language-server procedural (Phase 12)
    public static let lsResolveLaunchPlan: ExtensionMethodID = "ls.resolveLaunchPlan"
    public static let lsInitializationOptions: ExtensionMethodID = "ls.initializationOptions"
    public static let lsWorkspaceConfiguration: ExtensionMethodID = "ls.workspaceConfiguration"
    public static let lsTransformCompletionLabel: ExtensionMethodID = "ls.transformCompletionLabel"
    public static let lsTransformSymbolLabel: ExtensionMethodID = "ls.transformSymbolLabel"
    public static let lsStatus: ExtensionMethodID = "ls.status"
    public static let lsRestart: ExtensionMethodID = "ls.restart"

    // Broker
    public static let worktreeList: ExtensionMethodID = "broker.worktree.list"
    public static let worktreeRead: ExtensionMethodID = "broker.worktree.read"
    public static let worktreeWhich: ExtensionMethodID = "broker.worktree.which"
    public static let worktreeEnvironment: ExtensionMethodID = "broker.worktree.environment"
    public static let projectInfo: ExtensionMethodID = "broker.project.info"
    public static let settingsGet: ExtensionMethodID = "broker.settings.get"
    public static let settingsSet: ExtensionMethodID = "broker.settings.set"
    public static let storageGet: ExtensionMethodID = "broker.storage.get"
    public static let storageSet: ExtensionMethodID = "broker.storage.set"
    public static let processSpawn: ExtensionMethodID = "broker.process.spawn"
    public static let processKill: ExtensionMethodID = "broker.process.kill"
    public static let downloadFetch: ExtensionMethodID = "broker.download.fetch"
    public static let npmInstall: ExtensionMethodID = "broker.npm.install"

    // Conformance / test
    public static let echo: ExtensionMethodID = "test.echo"
    public static let spawnChild: ExtensionMethodID = "test.spawnChild"
}

/// Canonical method catalog + schema hash (committed constant; tests verify stability).
public enum ExtensionMethodCatalog {
    public static let protocolMajor = 1
    public static let protocolMinor = 0

    /// Ordered list is the schema source of truth.
    public static let entries: [ExtensionMethodID] = [
        .activate, .deactivate, .ping,
        .completion, .hover, .definition, .diagnostics,
        .lsResolveLaunchPlan, .lsInitializationOptions, .lsWorkspaceConfiguration,
        .lsTransformCompletionLabel, .lsTransformSymbolLabel, .lsStatus, .lsRestart,
        .worktreeList, .worktreeRead, .worktreeWhich, .worktreeEnvironment, .projectInfo,
        .settingsGet, .settingsSet,
        .storageGet, .storageSet,
        .processSpawn, .processKill,
        .downloadFetch, .npmInstall,
        .echo, .spawnChild,
    ]

    public static var canonicalSchemaText: String {
        entries.map(\.rawValue).joined(separator: "\n") + "\n"
    }

    /// SHA-256 hex of ``canonicalSchemaText`` UTF-8.
    public static let schemaHash: String = computeSchemaHash()

    public static func contains(_ id: ExtensionMethodID) -> Bool {
        entries.contains(id)
    }

    private static func computeSchemaHash() -> String {
        let data = Data(canonicalSchemaText.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 5381
        for b in data { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return String(format: "%016llx", hash)
        #endif
    }
}
