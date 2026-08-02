import CodeEditorCore
import CryptoKit
import Foundation

/// Versioned recovery record envelope (DOC-N11).
///
/// Layout:
/// ```
/// header: schema, document URI, base file identity, content state, encoding
/// payload: snapshot (base64) with SHA-256 checksum
/// write: temp → fsync → rename → fsync directory
/// ```
public struct RecoveryJournalRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var documentURI: String
    public var contentHash: String
    public var payloadSize: UInt64
    public var payloadChecksum: String
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    /// Content state at journal write (DOC-N11 / DOC-N01).
    public var contentStateRaw: String?
    /// Base file identity content hash when known.
    public var baseFileIdentityHash: String?
    public var encodingName: String?
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
        contentStateRaw: String? = nil,
        baseFileIdentityHash: String? = nil,
        encodingName: String? = nil,
        payloadBase64: String
    ) {
        self.schemaVersion = schemaVersion
        self.documentURI = documentURI
        self.contentHash = contentHash
        self.payloadSize = payloadSize
        self.payloadChecksum = payloadChecksum
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentStateRaw = contentStateRaw
        self.baseFileIdentityHash = baseFileIdentityHash
        self.encodingName = encodingName
        self.payloadBase64 = payloadBase64
    }
}

/// Sidecar recovery journal for dirty document content.
///
/// Layout: `<directory>/.<basename>.codeeditor-recovery` containing a versioned JSON envelope
/// with SHA-256 payload checksum, quotas, and restricted permissions.
///
/// Discovery is deterministic (fixed name), bounded (quotas), and corrupt-record tolerant
/// (quarantine fails closed when IO errors prevent safe isolation) (DOC-N11).
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
        documentURI: String? = nil,
        contentState: DocumentContentStateID? = nil,
        baseFileIdentity: DocumentFileIdentity? = nil,
        encoding: DocumentEncoding? = nil
    ) async throws {
        let payload = Data(text.utf8)
        if UInt64(payload.count) > maxBytesPerDocument {
            throw DocumentIOError.recoveryQuotaExceeded
        }
        try await enforceGlobalQuota(adding: UInt64(payload.count), excluding: journalURL(forPrimary: primary))

        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        // Preserve createdAt on update when an existing valid record is present.
        let existingCreated = try? await readCreatedAt(forPrimary: primary, io: io)
        let record = RecoveryJournalRecord(
            documentURI: documentURI ?? primary.absoluteString,
            contentHash: DocumentFileIdentity.hash(of: payload),
            payloadSize: UInt64(payload.count),
            payloadChecksum: checksum,
            createdAt: existingCreated ?? now,
            updatedAt: now,
            contentStateRaw: contentState?.rawValue.uuidString,
            baseFileIdentityHash: baseFileIdentity?.contentHash,
            encodingName: encoding.map(Self.encodingName(for:)),
            payloadBase64: payload.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let url = journalURL(forPrimary: primary)
        // Durable write: temp → fsync → rename → fsync directory (via LocalDocumentIO).
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
        guard record.schemaVersion == RecoveryJournalRecord.currentSchemaVersion
            || record.schemaVersion == 1
        else {
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

    /// Deterministic, bounded discovery of recovery records under `directory`.
    ///
    /// Recovery sidecars are **dotfiles** (`.name.codeeditor-recovery`); discovery
    /// must include hidden files and exclude quarantine suffixes (DOC-N11).
    public func discoverRecords(io: any DocumentIO) async throws -> [URL] {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []  // include hidden recovery sidecars
            )
        } catch {
            throw DocumentIOError.ioFailure(
                "recovery discovery failed: \(error.localizedDescription)"
            )
        }
        _ = io
        return items
            .filter {
                $0.lastPathComponent.hasSuffix(".codeeditor-recovery")
                    && !$0.lastPathComponent.hasSuffix(".codeeditor-recovery.quarantine")
                    && !$0.lastPathComponent.contains(".codeeditor-recovery.quarantine")
            }
            .filter { !$0.lastPathComponent.hasSuffix(".quarantine") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readCreatedAt(forPrimary primary: URL, io: any DocumentIO) async throws -> TimeInterval? {
        let url = journalURL(forPrimary: primary)
        guard await io.fileExists(at: url) else { return nil }
        guard let data = try? await io.read(url: url, maxBytes: maxBytesPerDocument + 64 * 1024),
            let record = try? JSONDecoder().decode(RecoveryJournalRecord.self, from: data)
        else { return nil }
        return record.createdAt
    }

    private func quarantine(primary: URL, io: any DocumentIO) async throws {
        let src = journalURL(forPrimary: primary)
        let dst = quarantineURL(forPrimary: primary)
        guard await io.fileExists(at: src) else { return }
        // Fail closed: quarantine must succeed or surface the error (DOC-N11).
        let data = try await io.read(url: src, maxBytes: maxBytesPerDocument + 64 * 1024)
        try await io.writeAtomically(data: data, to: dst)
        try Self.applyRestrictedPermissions(at: dst)
        try await io.removeItem(at: src)
    }

    private func enforceGlobalQuota(adding extra: UInt64, excluding: URL) async throws {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []
            )
        } catch {
            throw DocumentIOError.ioFailure("recovery quota scan failed: \(error.localizedDescription)")
        }
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

    static func encodingName(for encoding: DocumentEncoding) -> String {
        switch encoding {
        case .utf8: return "utf8"
        case .utf16: return "utf16"
        case .utf16LittleEndian: return "utf16le"
        case .utf16BigEndian: return "utf16be"
        case .other(let name): return "other:\(name)"
        }
    }
}
