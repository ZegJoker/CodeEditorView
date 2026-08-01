import CodeEditorCore
import Foundation

/// Low-level byte load/save. Implementations must never leave a partial primary file
/// after a failed save (temp + replace, or no change).
public protocol DocumentIO: Sendable {
    func read(url: URL) async throws -> Data
    /// Read at most `maxBytes` (+1 to detect overflow). Rejects oversized files without
    /// allocating the full content when the platform allows (DOC size gate).
    func read(url: URL, maxBytes: UInt64) async throws -> Data
    /// Atomically replace `url` with `data`. On failure, original content (if any) remains intact.
    func writeAtomically(data: Data, to url: URL) async throws
    func fileExists(at url: URL) async -> Bool
    func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity?
    func removeItem(at url: URL) async throws
}

extension DocumentIO {
    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        let data = try await read(url: url)
        if UInt64(data.count) > maxBytes {
            throw DocumentIOError.tooLarge(UInt64(data.count))
        }
        return data
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
}

/// Production filesystem IO with temp file + fsync + replace.
public struct LocalDocumentIO: DocumentIO {
    public init() {}

    public func read(url: URL) async throws -> Data {
        try await read(url: url, maxBytes: UInt64.max)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            // Metadata-first size check before full allocation.
            if maxBytes < UInt64.max,
                let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize,
                UInt64(size) > maxBytes
            {
                throw DocumentIOError.tooLarge(UInt64(size))
            }
            do {
                // Stream into memory with a hard cap: maxBytes + 1 to detect oversize.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                if maxBytes == UInt64.max {
                    return try handle.readToEnd() ?? Data()
                }
                let limit = Int(min(maxBytes + 1, UInt64(Int.max)))
                let data = try handle.read(upToCount: limit) ?? Data()
                if UInt64(data.count) > maxBytes {
                    throw DocumentIOError.tooLarge(UInt64(data.count))
                }
                return data
            } catch let error as DocumentIOError {
                throw error
            } catch {
                throw DocumentIOError.ioFailure(error.localizedDescription)
            }
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
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return nil }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DocumentIOError.ioFailure(error.localizedDescription)
            }
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey,
            ])
            return DocumentFileIdentity(
                contentHash: DocumentFileIdentity.hash(of: data),
                size: UInt64(values?.fileSize ?? data.count),
                modificationTime: values?.contentModificationDate?.timeIntervalSince1970,
                fileResourceIdentifier: values?.fileResourceIdentifier as? Data
            )
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
            defer { try? handle.close() }
            try handle.synchronize()

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(
                    url,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }

            if let existingPerms {
                try? fm.setAttributes([.posixPermissions: existingPerms], ofItemAtPath: url.path)
            }

            // Best-effort fsync directory (helps durability of the rename).
            if let dirHandle = try? FileHandle(forWritingTo: directory) {
                try? dirHandle.synchronize()
                try? dirHandle.close()
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
            if fault == .beforeFsync {
                // already synced; treat as before replace
            }
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
