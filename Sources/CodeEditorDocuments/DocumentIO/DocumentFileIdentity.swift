import Foundation
import CryptoKit
import CodeEditorCore

/// On-disk identity snapshot for external-change detection.
public struct DocumentFileIdentity: Sendable, Hashable, Codable {
    public var contentHash: String
    public var size: UInt64
    public var modificationTime: TimeInterval?
    public var fileResourceIdentifier: Data?

    public init(
        contentHash: String,
        size: UInt64,
        modificationTime: TimeInterval? = nil,
        fileResourceIdentifier: Data? = nil
    ) {
        self.contentHash = contentHash
        self.size = size
        self.modificationTime = modificationTime
        self.fileResourceIdentifier = fileResourceIdentifier
    }

    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Comparison of a stored identity against the live file.
public enum DocumentFileChange: Sendable, Hashable, Equatable {
    case unchanged
    case externalModified
    case deleted
    case moved
}

/// How to treat line endings when encoding text for disk.
public enum LineEndingSavePolicy: Sendable, Hashable, Codable {
    /// Leave text as-is.
    case preserve
    /// Rewrite all newlines to the given ending.
    case convert(LineEnding)
}

/// Whether to emit a UTF BOM when encoding.
public enum BOMPolicy: Sendable, Hashable, Codable {
    case none
    /// Emit BOM when encoding is UTF-8 / UTF-16 family.
    case whenEncodingSupports
}

/// Host policies for document lifecycle (defaults are conservative).
public struct DocumentLifecyclePolicy: Sendable, Hashable, Codable {
    public var lineEndingOnSave: LineEndingSavePolicy
    public var bomPolicy: BOMPolicy
    public var maxLoadBytes: UInt64
    public var writeRecoveryJournal: Bool
    public var isReadOnly: Bool

    public init(
        lineEndingOnSave: LineEndingSavePolicy = .preserve,
        bomPolicy: BOMPolicy = .none,
        maxLoadBytes: UInt64 = 64 * 1024 * 1024,
        writeRecoveryJournal: Bool = true,
        isReadOnly: Bool = false
    ) {
        self.lineEndingOnSave = lineEndingOnSave
        self.bomPolicy = bomPolicy
        self.maxLoadBytes = maxLoadBytes
        self.writeRecoveryJournal = writeRecoveryJournal
        self.isReadOnly = isReadOnly
    }

    public static let `default` = DocumentLifecyclePolicy()
}
