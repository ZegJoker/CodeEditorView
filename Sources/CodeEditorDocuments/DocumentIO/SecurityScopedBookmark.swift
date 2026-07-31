import Foundation

/// Security-scoped bookmark helpers for sandboxed hosts.
public enum SecurityScopedBookmark: Sendable {
    public struct Handle: Sendable {
        public let bookmarkData: Data
        public let url: URL

        public init(bookmarkData: Data, url: URL) {
            self.bookmarkData = bookmarkData
            self.url = url
        }
    }

    /// Creates a security-scoped bookmark for `url` when the platform supports it.
    public static func create(for url: URL) throws -> Data {
        #if os(macOS) || os(iOS)
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        throw DocumentIOError.ioFailure("Security-scoped bookmarks unavailable on this platform")
        #endif
    }

    public static func resolve(_ data: Data) throws -> Handle {
        #if os(macOS) || os(iOS)
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        _ = isStale
        return Handle(bookmarkData: data, url: url)
        #else
        throw DocumentIOError.ioFailure("Security-scoped bookmarks unavailable on this platform")
        #endif
    }

    /// Starts security-scoped access; returns a closure that must be called to stop access.
    public static func access<T>(_ url: URL, body: () throws -> T) rethrows -> T {
        #if os(macOS) || os(iOS)
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return try body()
        #else
        return try body()
        #endif
    }
}
