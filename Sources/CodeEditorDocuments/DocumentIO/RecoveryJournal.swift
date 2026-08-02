import CryptoKit
import Foundation

/// Versioned recovery journal envelope (DOC-008 / §7.10).
public struct RecoveryJournalRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var documentURI: String
    public var contentHash: String
    public var payloadSize: UInt64
    public var payloadChecksum: String
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    /// UTF-8 payload stored as base64 for JSON safety.
    public var payloadBase64: String

    public init(
        schemaVersion: Int = RecoveryJournalRecord.currentSchemaVersion,
        documentURI: String,
        contentHash: String,
        payloadSize: UInt64,
        payloadChecksum: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        payloadBase64: String
    ) {
        self.schemaVersion = schemaVersion
        self.documentURI = documentURI
        self.contentHash = contentHash
        self.payloadSize = payloadSize
        self.payloadChecksum = payloadChecksum
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadBase64 = payloadBase64
    }
}

/// Sidecar recovery journal for dirty document content.
///
/// Layout: `<directory>/.<basename>.codeeditor-recovery` containing a versioned JSON envelope
/// with SHA-256 payload checksum, quotas, and restricted permissions.
public struct RecoveryJournal: Sendable {
    public let directory: URL
    public var maxBytesPerDocument: UInt64
    public var maxBytesGlobal: UInt64

    public init(
        directory: URL,
        maxBytesPerDocument: UInt64 = 8 * 1024 * 1024,
        maxBytesGlobal: UInt64 = 64 * 1024 * 1024
    ) {
        self.directory = directory
        self.maxBytesPerDocument = maxBytesPerDocument
        self.maxBytesGlobal = maxBytesGlobal
    }

    public func journalURL(forPrimary primary: URL) -> URL {
        let name = ".\(primary.lastPathComponent).codeeditor-recovery"
        return primary.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func quarantineURL(forPrimary primary: URL) -> URL {
        let name = ".\(primary.lastPathComponent).codeeditor-recovery.quarantine"
        return primary.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func write(
        text: String,
        forPrimary primary: URL,
        io: any DocumentIO,
        documentURI: String? = nil
    ) async throws {
        let payload = Data(text.utf8)
        if UInt64(payload.count) > maxBytesPerDocument {
            throw DocumentIOError.recoveryQuotaExceeded
        }
        try await enforceGlobalQuota(adding: UInt64(payload.count), excluding: journalURL(forPrimary: primary))

        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        let record = RecoveryJournalRecord(
            documentURI: documentURI ?? primary.absoluteString,
            contentHash: DocumentFileIdentity.hash(of: payload),
            payloadSize: UInt64(payload.count),
            payloadChecksum: checksum,
            createdAt: now,
            updatedAt: now,
            payloadBase64: payload.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let url = journalURL(forPrimary: primary)
        try await io.writeAtomically(data: data, to: url)
        try Self.applyRestrictedPermissions(at: url)
    }

    public func read(forPrimary primary: URL, io: any DocumentIO) async throws -> String? {
        let url = journalURL(forPrimary: primary)
        guard await io.fileExists(at: url) else { return nil }
        let data: Data
        do {
            data = try await io.read(url: url, maxBytes: maxBytesPerDocument + 64 * 1024)
        } catch {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("unreadable journal: \(error)")
        }
        let record: RecoveryJournalRecord
        do {
            record = try JSONDecoder().decode(RecoveryJournalRecord.self, from: data)
        } catch {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("invalid envelope")
        }
        guard record.schemaVersion == RecoveryJournalRecord.currentSchemaVersion else {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("unsupported schema \(record.schemaVersion)")
        }
        guard let payload = Data(base64Encoded: record.payloadBase64) else {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("invalid payload encoding")
        }
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard checksum == record.payloadChecksum, UInt64(payload.count) == record.payloadSize else {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("checksum mismatch")
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            try await quarantine(primary: primary, io: io)
            throw DocumentIOError.corruptRecoveryJournal("payload is not UTF-8")
        }
        return text
    }

    public func clear(forPrimary primary: URL, io: any DocumentIO) async throws {
        let url = journalURL(forPrimary: primary)
        try await io.removeItem(at: url)
    }

    private func quarantine(primary: URL, io: any DocumentIO) async throws {
        let src = journalURL(forPrimary: primary)
        let dst = quarantineURL(forPrimary: primary)
        guard await io.fileExists(at: src) else { return }
        // Best-effort: read + rewrite as quarantine, then remove source.
        if let data = try? await io.read(url: src, maxBytes: maxBytesPerDocument + 64 * 1024) {
            try? await io.writeAtomically(data: data, to: dst)
            try? Self.applyRestrictedPermissions(at: dst)
        }
        try? await io.removeItem(at: src)
    }

    private func enforceGlobalQuota(adding extra: UInt64, excluding: URL) async throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return }
        var total: UInt64 = 0
        for item in items {
            guard item.lastPathComponent.contains(".codeeditor-recovery") else { continue }
            if item.standardizedFileURL == excluding.standardizedFileURL { continue }
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            total += size
        }
        if total + extra > maxBytesGlobal {
            throw DocumentIOError.recoveryQuotaExceeded
        }
    }

    static func applyRestrictedPermissions(at url: URL) throws {
        #if os(macOS) || os(Linux)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        #endif
    }
}
