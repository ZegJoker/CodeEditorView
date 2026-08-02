import Foundation

/// Wraps ``LocalDocumentIO`` with `NSFileCoordinator` for read/write.
///
/// Identity comparison for CAS saves runs **inside** the coordinated write block
/// immediately before replace (DOC-N08).
public struct CoordinatedDocumentIO: DocumentIO {
    private let base: LocalDocumentIO

    public init(base: LocalDocumentIO = LocalDocumentIO()) {
        self.base = base
    }

    public func read(url: URL) async throws -> Data {
        try await readContentAndIdentity(url: url, maxBytes: UInt64.max).0
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await readContentAndIdentity(url: url, maxBytes: maxBytes).0
    }

    public func readContentAndIdentity(
        url: URL,
        maxBytes: UInt64
    ) async throws -> (Data, DocumentFileIdentity) {
        try await withCheckedThrowingContinuation { cont in
            // Exactly-once resume (DOC-006 / §7.8): single mutable box closed after first use.
            final class Box: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func resume(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    body()
                }
            }
            let box = Box()
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { newURL in
                do {
                    let value = try LocalDocumentIO.readContentAndIdentitySync(
                        url: newURL,
                        maxBytes: maxBytes
                    )
                    box.resume { cont.resume(returning: value) }
                } catch {
                    box.resume { cont.resume(throwing: error) }
                }
            }
            if let coordinatorError {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
                }
            } else {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
                }
            }
        }
    }

    public func writeAtomically(data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Box: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func resume(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    body()
                }
            }
            let box = Box()
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forReplacing],
                error: &coordinatorError
            ) { newURL in
                do {
                    try LocalDocumentIO.writeAtomicallySync(data: data, to: newURL, durability: .durable)
                    box.resume { cont.resume(returning: ()) }
                } catch {
                    box.resume { cont.resume(throwing: error) }
                }
            }
            if let coordinatorError {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
                }
            } else {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
                }
            }
        }
    }

    public func writeAtomicallyComparingIdentity(
        data: Data,
        to url: URL,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy,
        durability: SaveDurability
    ) async throws -> DocumentIOWriteResult {
        try await withCheckedThrowingContinuation { cont in
            final class Box: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func resume(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    body()
                }
            }
            let box = Box()
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forReplacing],
                error: &coordinatorError
            ) { newURL in
                do {
                    // DOC-N08: identity check + replace under the same coordination.
                    let result = try LocalDocumentIO.writeAtomicallyComparingIdentitySync(
                        data: data,
                        to: newURL,
                        expectedIdentity: expectedIdentity,
                        conflictPolicy: conflictPolicy,
                        durability: durability
                    )
                    box.resume { cont.resume(returning: result) }
                } catch {
                    box.resume { cont.resume(throwing: error) }
                }
            }
            if let coordinatorError {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
                }
            } else {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
                }
            }
        }
    }

    public func fileExists(at url: URL) async -> Bool {
        await base.fileExists(at: url)
    }

    public func resourceIdentity(at url: URL) async throws -> DocumentFileIdentity? {
        guard await fileExists(at: url) else { return nil }
        // Hash-only under coordination (DOC-N09).
        return try await withCheckedThrowingContinuation { cont in
            final class Box: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func resume(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    body()
                }
            }
            let box = Box()
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { newURL in
                do {
                    let identity = try LocalDocumentIO.hashOnlyIdentitySync(url: newURL)
                    box.resume { cont.resume(returning: identity) }
                } catch {
                    box.resume { cont.resume(throwing: error) }
                }
            }
            if let coordinatorError {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
                }
            } else {
                box.resume {
                    cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
                }
            }
        }
    }

    public func removeItem(at url: URL) async throws {
        try await base.removeItem(at: url)
    }
}
