import Foundation

/// Wraps ``LocalDocumentIO`` with `NSFileCoordinator` for read/write.
public struct CoordinatedDocumentIO: DocumentIO {
    private let base: LocalDocumentIO

    public init(base: LocalDocumentIO = LocalDocumentIO()) {
        self.base = base
    }

    public func read(url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { newURL in
                do {
                    let data = try Data(contentsOf: newURL)
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: DocumentIOError.ioFailure(error.localizedDescription))
                }
            }
            if let coordinatorError {
                cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
            }
        }
    }

    public func writeAtomically(data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forReplacing],
                error: &coordinatorError
            ) { newURL in
                do {
                    try LocalDocumentIO.writeAtomicallySync(data: data, to: newURL)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            if let coordinatorError {
                cont.resume(throwing: DocumentIOError.ioFailure(coordinatorError.localizedDescription))
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
