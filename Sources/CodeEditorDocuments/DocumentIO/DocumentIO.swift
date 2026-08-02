import CodeEditorCore
import CryptoKit
import Foundation

/// Low-level byte load/save. Implementations must never leave a partial primary file
/// after a failed save (temp + replace, or no change).
public protocol DocumentIO: Sendable {
    func read(url: URL) async throws -> Data
    /// Read at most `maxBytes` (+1 to detect overflow). Must not allocate the full file
    /// when metadata/stream APIs can reject early (DOC-005 / §7.5).
    func read(url: URL, maxBytes: UInt64) async throws -> Data
    /// Single-pass content + identity (streaming hash). Preferred for load paths.
    func readContentAndIdentity(url: URL, maxBytes: UInt64) async throws -> (Data, DocumentFileIdentity)
    /// Atomically replace `url` with `data`. On failure, original content (if any) remains intact.
    func writeAtomically(data: Data, to url: URL) async throws
    func fileExists(at url: URL) async -> Bool
    /// Streaming identity; must not use unbounded full-file allocation for huge files.
    func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity?
    func removeItem(at url: URL) async throws
}

extension DocumentIO {
    public func read(url: URL) async throws -> Data {
        try await read(url: url, maxBytes: UInt64.max)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await readContentAndIdentity(url: url, maxBytes: maxBytes).0
    }

    public func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity? {
        guard await fileExists(at: url) else { return nil }
        // Stream-hash without returning payload to callers that only need identity.
        let (_, identity) = try await readContentAndIdentity(url: url, maxBytes: UInt64.max)
        return identity
    }
}

/// Ordered failure points for fault-injection tests.
public enum DocumentIOFaultPoint: String, Sendable, Hashable, CaseIterable {
    case beforeWrite
    case afterTempWrite
    case beforeReplace
    case afterReplace
    case beforeFsync
}

public enum DocumentIOError: Error, Sendable, Equatable {
    case notFound(String)
    case ioFailure(String)
    case tooLarge(UInt64)
    case injectedFault(DocumentIOFaultPoint)
    case readOnly
    case encodingFailed
    case unsupportedEncoding(String)
    case corruptRecoveryJournal(String)
    case recoveryQuotaExceeded
}

/// Production filesystem IO with temp file + fsync + replace.
public struct LocalDocumentIO: DocumentIO {
    public init() {}

    public func read(url: URL) async throws -> Data {
        try await read(url: url, maxBytes: UInt64.max)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await readContentAndIdentity(url: url, maxBytes: maxBytes).0
    }

    public func readContentAndIdentity(
        url: URL,
        maxBytes: UInt64
    ) async throws -> (Data, DocumentFileIdentity) {
        try await Task.detached(priority: .userInitiated) {
            try Self.readContentAndIdentitySync(url: url, maxBytes: maxBytes)
        }.value
    }

    public func writeAtomically(data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.writeAtomicallySync(data: data, to: url)
        }.value
    }

    public func fileExists(at url: URL) async -> Bool {
        await Task.detached {
            FileManager.default.fileExists(atPath: url.path)
        }.value
    }

    public func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity? {
        let exists = await fileExists(at: url)
        guard exists else { return nil }
        // Stream hash only — discard payload (DOC-005).
        let (_, identity) = try await readContentAndIdentity(url: url, maxBytes: UInt64.max)
        return identity
    }

    public func removeItem(at url: URL) async throws {
        try await Task.detached {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw DocumentIOError.ioFailure(error.localizedDescription)
            }
        }.value
    }

    // MARK: - Sync helpers

    /// Metadata-first, stream-capped read with incremental SHA-256 (DOC-005 / §7.5–7.6).
    static func readContentAndIdentitySync(
        url: URL,
        maxBytes: UInt64
    ) throws -> (Data, DocumentFileIdentity) {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        if maxBytes < UInt64.max,
            let size = values?.fileSize,
            UInt64(size) > maxBytes
        {
            throw DocumentIOError.tooLarge(UInt64(size))
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DocumentIOError.ioFailure(error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunks: [Data] = []
        var total: UInt64 = 0
        let chunkSize = 64 * 1024
        let hardCap: UInt64 = maxBytes == UInt64.max ? UInt64.max : maxBytes + 1

        while true {
            let remaining: Int
            if hardCap == UInt64.max {
                remaining = chunkSize
            } else {
                let left = hardCap - total
                if left == 0 { break }
                remaining = Int(min(UInt64(chunkSize), left))
            }
            let piece: Data
            do {
                piece = try handle.read(upToCount: remaining) ?? Data()
            } catch {
                throw DocumentIOError.ioFailure(error.localizedDescription)
            }
            if piece.isEmpty { break }
            hasher.update(data: piece)
            chunks.append(piece)
            total += UInt64(piece.count)
            if maxBytes < UInt64.max, total > maxBytes {
                throw DocumentIOError.tooLarge(total)
            }
        }

        let data: Data
        if chunks.count == 1 {
            data = chunks[0]
        } else {
            var combined = Data()
            combined.reserveCapacity(Int(min(total, UInt64(Int.max))))
            for c in chunks { combined.append(c) }
            data = combined
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = DocumentFileIdentity(
            contentHash: digest,
            size: UInt64(data.count),
            modificationTime: values?.contentModificationDate?.timeIntervalSince1970,
            fileResourceIdentifier: values?.fileResourceIdentifier as? Data
        )
        return (data, identity)
    }

    /// Synchronous atomic write used by detached tasks and tests.
    static func writeAtomicallySync(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempName = ".\(url.lastPathComponent).codeeditor-tmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempName)

        // Capture existing permissions to re-apply after replace.
        let existingPerms: Int? = {
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }()

        do {
            try data.write(to: tempURL, options: .atomic)
            // fsync temp file
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.synchronize()
            try handle.close()

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }

            if let perms = existingPerms {
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            if let io = error as? DocumentIOError { throw io }
            throw DocumentIOError.ioFailure(error.localizedDescription)
        }
    }
}

/// IO wrapper that injects failures at a configured point (tests / fault injection).
public struct FaultInjectingDocumentIO: DocumentIO {
    public let base: any DocumentIO
    public let fault: DocumentIOFaultPoint?

    public init(base: any DocumentIO = LocalDocumentIO(), fault: DocumentIOFaultPoint?) {
        self.base = base
        self.fault = fault
    }

    public func read(url: URL) async throws -> Data {
        try await base.read(url: url)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await base.read(url: url, maxBytes: maxBytes)
    }

    public func readContentAndIdentity(
        url: URL,
        maxBytes: UInt64
    ) async throws -> (Data, DocumentFileIdentity) {
        try await base.readContentAndIdentity(url: url, maxBytes: maxBytes)
    }

    public func writeAtomically(data: Data, to url: URL) async throws {
        if fault == .beforeWrite {
            throw DocumentIOError.injectedFault(.beforeWrite)
        }
        // Use a custom path when we need mid-pipeline faults.
        if let fault, fault != .beforeWrite {
            try await writeWithFault(data: data, to: url, fault: fault)
            return
        }
        try await base.writeAtomically(data: data, to: url)
    }

    public func fileExists(at url: URL) async -> Bool {
        await base.fileExists(at: url)
    }

    public func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity? {
        try await base.resourceIdentity(at: url)
    }

    public func removeItem(at url: URL) async throws {
        try await base.removeItem(at: url)
    }

    private func writeWithFault(data: Data, to url: URL, fault: DocumentIOFaultPoint) async throws {
        try await Task.detached {
            let fm = FileManager.default
            let directory = url.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let tempURL = directory.appendingPathComponent(
                ".\(url.lastPathComponent).codeeditor-tmp-\(UUID().uuidString)"
            )
            if fault == .beforeWrite { throw DocumentIOError.injectedFault(.beforeWrite) }
            try data.write(to: tempURL, options: .atomic)
            if fault == .afterTempWrite {
                try? fm.removeItem(at: tempURL)
                throw DocumentIOError.injectedFault(.afterTempWrite)
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.synchronize()
            try handle.close()
            if fault == .beforeReplace {
                try? fm.removeItem(at: tempURL)
                throw DocumentIOError.injectedFault(.beforeReplace)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
            if fault == .afterReplace {
                throw DocumentIOError.injectedFault(.afterReplace)
            }
        }.value
    }
}
