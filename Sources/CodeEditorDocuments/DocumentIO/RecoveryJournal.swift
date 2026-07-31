import Foundation

/// Sidecar recovery journal for dirty document content.
///
/// Layout: `<directory>/.<basename>.codeeditor-recovery` containing UTF-8 text.
public struct RecoveryJournal: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func journalURL(forPrimary primary: URL) -> URL {
        let name = ".\(primary.lastPathComponent).codeeditor-recovery"
        return primary.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func write(text: String, forPrimary primary: URL, io: any DocumentIO) async throws {
        let data = Data(text.utf8)
        let url = journalURL(forPrimary: primary)
        try await io.writeAtomically(data: data, to: url)
    }

    public func read(forPrimary primary: URL, io: any DocumentIO) async throws -> String? {
        let url = journalURL(forPrimary: primary)
        guard await io.fileExists(at: url) else { return nil }
        let data = try await io.read(url: url)
        return String(data: data, encoding: .utf8)
    }

    public func clear(forPrimary primary: URL, io: any DocumentIO) async throws {
        let url = journalURL(forPrimary: primary)
        try await io.removeItem(at: url)
    }
}
