import Foundation

/// Wraps ``LocalDocumentIO`` with `NSFileCoordinator` for read/write.
public struct CoordinatedDocumentIO: DocumentIO {
    private let base: LocalDocumentIO

    public init(base: LocalDocumentIO = LocalDocumentIO()) {
        self.base = base
    }

    public func read(url: URL) async throws -> Data {
        try await read(url: url, maxBytes: UInt64.max)
    }

    public func read(url: URL, maxBytes: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            var result: Result<Data, Error>?
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { newURL in
                do {
                    // Delegate bounded read to LocalDocumentIO semantics.
                    if maxBytes < UInt64.max,
                        let values = try? newURL.resourceValues(forKeys: [.fileSizeKey]),
                        let size = values.fileSize,
                        UInt64(size) > maxBytes
                    {
                        result = .failure(DocumentIOError.tooLarge(UInt64(size)))
                        return
                    }
                    let handle = try FileHandle(forReadingFrom: newURL)
                    defer { try? handle.close() }
                    let data: Data
                    if maxBytes == UInt64.max {
                        data = try handle.readToEnd() ?? Data()
                    } else {
                        let limit = Int(min(maxBytes + 1, UInt64(Int.max)))
                        data = try handle.read(upToCount: limit) ?? Data()
                        if UInt64(data.count) > maxBytes {
                            result = .failure(DocumentIOError.tooLarge(UInt64(data.count)))
                            return
                        }
                    }
                    result = .success(data)
                } catch {
                    result = .failure(DocumentIOError.ioFailure(error.localizedDescription))
                }
            }
            // Exactly-once resume: prefer coordination result; only use coordinatorError if
            // the block never ran / did not produce a result.
            if let result {
                cont.resume(with: result)
            } else if let coordinatorError {
                cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
            } else {
                cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
            }
        }
    }

    public func writeAtomically(data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var result: Result<Void, Error>?
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forReplacing],
                error: &coordinatorError
            ) { newURL in
                do {
                    try LocalDocumentIO.writeAtomicallySync(data: data, to: newURL)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
            }
            if let result {
                cont.resume(with: result)
            } else if let coordinatorError {
                cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
            } else {
                cont.resume(throwing: DocumentIOError.ioFailure("file coordination produced no result"))
            }
        }
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
}
