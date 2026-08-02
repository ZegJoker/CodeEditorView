import CodeEditorCore
import CryptoKit
import Foundation

/// Low-level byte load/save. Implementations must never leave a partial primary file
/// after a failed save (temp + replace, or no change).
public protocol DocumentIO: Sendable {
    func read(url: URL) async throws -> Data
    /// Read at most `maxBytes` (+1 to detect overflow). Must not allocate the full file
    /// when metadata/stream APIs can reject early (DOC-N09 / §7.5).
    func read(url: URL, maxBytes: UInt64) async throws -> Data
    /// Single-pass content + identity (streaming hash). Preferred for load paths.
    func readContentAndIdentity(url: URL, maxBytes: UInt64) async throws -> (Data, DocumentFileIdentity)
    /// Hash-only identity without retaining full payload (DOC-N09).
    func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity?
    /// Atomically replace `url` with `data`. On failure, original content (if any) remains intact.
    func writeAtomically(data: Data, to url: URL) async throws
    /// Compare-and-swap write under coordinated identity check (DOC-N08 / DOC-N10).
    func writeAtomicallyComparingIdentity(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) async throws -> DocumentIOWriteResult
    func fileExists(at url: URL) async -> Bool
    func removeItem(at url: URL) async throws
}

/// Result of an identity-aware atomic write.
public enum DocumentIOWriteResult: Sendable, Equatable {
    case written(DocumentFileIdentity?)
    case conflict(live: DocumentFileIdentity?, change: DocumentFileChange)
    case cancelled
}

extension DocumentIO {
    public func read(url: URL) async throws -> Data {
        try await read(url: url, maxBytes: UInt64.max)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await readContentAndIdentity(url: url, maxBytes: maxBytes).0
    }

    public func writeAtomicallyComparingIdentity(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) async throws -> DocumentIOWriteResult {
        // Default: check then write (providers should override for tighter TOCTOU).
        if let expectedIdentity {
            let live = try await resourceIdentity(at: url)
            if live == nil {
                switch conflictPolicy {
                case .cancel: return .cancelled
                case .requireHostDecision: return .conflict(live: nil, change: .deleted)
                case .overwrite: break
                }
            } else if live?.contentHash != expectedIdentity.contentHash {
                switch conflictPolicy {
                case .cancel: return .cancelled
                case .requireHostDecision: return .conflict(live: live, change: .externalModified)
                case .overwrite: break
                }
            }
        }
        try await writeAtomically(data: data, to: url)
        let identity = try await resourceIdentity(at: url)
        _ = durability
        return .written(identity)
    }
}

/// Ordered failure points for fault-injection tests.
public enum DocumentIOFaultPoint: String, Sendable, Hashable, CaseIterable {
    case beforeWrite
    case afterTempWrite
    case beforeReplace
    case afterReplace
    case beforeFsync
    case beforeParentFsync
    case afterParentFsync
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
    case identityConflict
}

/// Production filesystem IO with temp file + fsync + replace + parent fsync (DOC-N10).
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
            try Self.writeAtomicallySync(data: data, to: url, durability: .durable)
        }.value
    }

    public func writeAtomicallyComparingIdentity(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) async throws -> DocumentIOWriteResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.writeAtomicallyComparingIdentitySync(
                data: data,
                to: url,
                expectedIdentity: expectedIdentity,
                conflictPolicy: conflictPolicy,
                durability: durability
            )
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
        // Stream hash only — discard payload (DOC-N09).
        return try await Task.detached(priority: .userInitiated) {
            try Self.hashOnlyIdentitySync(url: url)
        }.value
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

    /// Metadata-first, stream-capped read with incremental SHA-256 (DOC-N09).
    ///
    /// When file size is known and within the cap, allocates a **single** `Data` buffer
    /// instead of retaining chunk arrays and combining them.
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
        let chunkSize = 64 * 1024
        let knownSize = values?.fileSize.map { UInt64($0) }

        let data: Data
        if let knownSize, knownSize <= maxBytes, knownSize <= UInt64(Int.max) {
            // Single preallocated buffer (DOC-N09).
            var buffer = Data(count: Int(knownSize))
            var offset = 0
            while offset < buffer.count {
                let want = min(chunkSize, buffer.count - offset)
                let piece: Data
                do {
                    piece = try handle.read(upToCount: want) ?? Data()
                } catch {
                    throw DocumentIOError.ioFailure(error.localizedDescription)
                }
                if piece.isEmpty { break }
                buffer.replaceSubrange(offset..<(offset + piece.count), with: piece)
                hasher.update(data: piece)
                offset += piece.count
            }
            if offset < buffer.count {
                buffer.count = offset
            }
            // Guard against size growth after metadata read.
            if maxBytes < UInt64.max {
                let extra = try handle.read(upToCount: 1) ?? Data()
                if !extra.isEmpty {
                    throw DocumentIOError.tooLarge(UInt64(offset) + 1)
                }
            }
            data = buffer
        } else {
            // Streaming path with single growing buffer (still one Data, not chunk array).
            var buffer = Data()
            if let knownSize, knownSize <= UInt64(Int.max) {
                buffer.reserveCapacity(Int(min(knownSize, maxBytes == UInt64.max ? knownSize : maxBytes)))
            }
            let hardCap: UInt64 = maxBytes == UInt64.max ? UInt64.max : maxBytes + 1
            var total: UInt64 = 0
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
                buffer.append(piece)
                total += UInt64(piece.count)
                if maxBytes < UInt64.max, total > maxBytes {
                    throw DocumentIOError.tooLarge(total)
                }
            }
            data = buffer
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

    /// Stream-hash only; never retains full file content (DOC-N09).
    static func hashOnlyIdentitySync(url: URL) throws -> DocumentFileIdentity {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DocumentIOError.ioFailure(error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: UInt64 = 0
        let chunkSize = 64 * 1024
        while true {
            let piece: Data
            do {
                piece = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw DocumentIOError.ioFailure(error.localizedDescription)
            }
            if piece.isEmpty { break }
            hasher.update(data: piece)
            total += UInt64(piece.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return DocumentFileIdentity(
            contentHash: digest,
            size: total,
            modificationTime: values?.contentModificationDate?.timeIntervalSince1970,
            fileResourceIdentifier: values?.fileResourceIdentifier as? Data
        )
    }

    /// Synchronous atomic write used by detached tasks and tests (DOC-N10).
    static func writeAtomicallySync(
        data: Data,
        to url: URL,
        durability: SaveDurability = .durable
    ) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempName = ".\(url.lastPathComponent).codeeditor-tmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempName)

        // Capture existing permissions / symlink policy: never follow symlinks for replace target.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType,
            type == .typeSymbolicLink
        {
            throw DocumentIOError.ioFailure("refusing to write through symlink at \(url.path)")
        }

        let existingPerms: Int? = {
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }()

        do {
            try data.write(to: tempURL, options: .atomic)
            // fsync temp file content
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

            if durability == .durable {
                try fsyncDirectory(at: directory)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            if let io = error as? DocumentIOError { throw io }
            throw DocumentIOError.ioFailure(error.localizedDescription)
        }
    }

    /// Identity check immediately before replace under one write pipeline (DOC-N08).
    static func writeAtomicallyComparingIdentitySync(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) throws -> DocumentIOWriteResult {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)

        if let expectedIdentity {
            if !exists {
                switch conflictPolicy {
                case .cancel: return .cancelled
                case .requireHostDecision: return .conflict(live: nil, change: .deleted)
                case .overwrite: break
                }
            } else {
                let live = try hashOnlyIdentitySync(url: url)
                if live.contentHash != expectedIdentity.contentHash {
                    switch conflictPolicy {
                    case .cancel: return .cancelled
                    case .requireHostDecision: return .conflict(live: live, change: .externalModified)
                    case .overwrite: break
                    }
                }
            }
        }

        try writeAtomicallySync(data: data, to: url, durability: durability)

        // After-write identity verification
        let written = try hashOnlyIdentitySync(url: url)
        let expectedHash = DocumentFileIdentity.hash(of: data)
        if written.contentHash != expectedHash {
            throw DocumentIOError.ioFailure("post-write identity mismatch")
        }
        return .written(written)
    }

    /// fsync the parent directory so the rename is durable (DOC-N10).
    static func fsyncDirectory(at directory: URL) throws {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
            guard fd >= 0 else {
                // Directory fsync is best-effort on some volumes; surface failure.
                throw DocumentIOError.ioFailure(
                    "failed to open directory for fsync: \(directory.path)"
                )
            }
            defer { close(fd) }
            if fsync(fd) != 0 {
                throw DocumentIOError.ioFailure(
                    "fsync parent directory failed: \(directory.path)"
                )
            }
        #endif
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
        if let fault, fault != .beforeWrite {
            try await writeWithFault(data: data, to: url, fault: fault)
            return
        }
        try await base.writeAtomically(data: data, to: url)
    }

    public func writeAtomicallyComparingIdentity(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) async throws -> DocumentIOWriteResult {
        if fault == .beforeWrite {
            throw DocumentIOError.injectedFault(.beforeWrite)
        }
        if let expectedIdentity {
            let live = try await resourceIdentity(at: url)
            if live == nil {
                switch conflictPolicy {
                case .cancel: return .cancelled
                case .requireHostDecision: return .conflict(live: nil, change: .deleted)
                case .overwrite: break
                }
            } else if live?.contentHash != expectedIdentity.contentHash {
                switch conflictPolicy {
                case .cancel: return .cancelled
                case .requireHostDecision: return .conflict(live: live, change: .externalModified)
                case .overwrite: break
                }
            }
        }
        if let fault, fault != .beforeWrite {
            try await writeWithFault(data: data, to: url, fault: fault)
            let identity = try await resourceIdentity(at: url)
            return .written(identity)
        }
        try await base.writeAtomically(data: data, to: url)
        let identity = try await resourceIdentity(at: url)
        _ = durability
        return .written(identity)
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
            if fault == .beforeFsync || fault == .beforeReplace {
                try? fm.removeItem(at: tempURL)
                throw DocumentIOError.injectedFault(fault)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
            if fault == .afterReplace {
                throw DocumentIOError.injectedFault(.afterReplace)
            }
            if fault == .beforeParentFsync {
                throw DocumentIOError.injectedFault(.beforeParentFsync)
            }
            try LocalDocumentIO.fsyncDirectory(at: directory)
            if fault == .afterParentFsync {
                throw DocumentIOError.injectedFault(.afterParentFsync)
            }
        }.value
    }
}
