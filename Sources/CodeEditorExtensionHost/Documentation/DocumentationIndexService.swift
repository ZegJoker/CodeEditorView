import CodeEditorExtensionAPI
import Foundation

/// Host-owned documentation index store with quotas. Never invents entries without source or provider data.
public actor DocumentationIndexService {
    public struct Config: Sendable {
        public var storageRoot: URL
        public var maxBytes: Int
        public var maxEntries: Int

        public init(storageRoot: URL, maxBytes: Int = 8 * 1024 * 1024, maxEntries: Int = 50_000) {
            self.storageRoot = storageRoot
            self.maxBytes = maxBytes
            self.maxEntries = maxEntries
        }
    }

    private let config: Config
    private var entries: [String: [DocumentationIndexEntry]] = [:]
    private var bytesUsed: Int = 0
    private var providers: [ExtensionID: any DocumentationIndexProvider] = [:]

    public init(config: Config) {
        self.config = config
        try? FileManager.default.createDirectory(at: config.storageRoot, withIntermediateDirectories: true)
    }

    public func registerProvider(_ provider: any DocumentationIndexProvider, extensionID: ExtensionID) {
        providers[extensionID] = provider
    }

    public func suggest(
        extensionID: ExtensionID,
        context: LanguageServerResolveContext
    ) async throws -> [DocumentationPackageSuggestion] {
        guard let provider = providers[extensionID] else {
            throw DocumentationIndexError.notFound("no documentation provider for \(extensionID.rawValue)")
        }
        return try await provider.suggestPackages(context: context)
    }

    public func buildIndex(
        package: DocumentationPackageSuggestion,
        extensionID: ExtensionID,
        context: LanguageServerResolveContext,
        worktreeRoot: URL?
    ) async throws -> [DocumentationIndexEntry] {
        var collected: [DocumentationIndexEntry] = []

        // Prefer explicit worktree source path when present.
        if let path = package.sourcePath {
            if path.contains("..") {
                throw DocumentationIndexError.pathDenied(path)
            }
            guard let root = worktreeRoot else {
                throw DocumentationIndexError.pathDenied("no worktree root for \(path)")
            }
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
            if url.path != rootResolved.path && !url.path.hasPrefix(rootResolved.path + "/") {
                throw DocumentationIndexError.pathDenied(path)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DocumentationIndexError.notFound(path)
            }
            let data = try Data(contentsOf: url)
            collected = try store(packageID: package.id, from: data, title: package.title)
            return collected
        }

        // Provider-driven build: must emit real entries.
        guard let provider = providers[extensionID] else {
            throw DocumentationIndexError.notFound("no documentation provider and no sourcePath")
        }
        for try await event in provider.buildIndex(package: package, context: context) {
            if Task.isCancelled { throw DocumentationIndexError.cancelled }
            switch event {
            case .progress:
                continue
            case .entry(let entry):
                collected.append(contentsOf: try store(packageID: package.id, entries: [entry]))
            case .completed:
                break
            }
        }
        if collected.isEmpty {
            throw DocumentationIndexError.notFound(package.id)
        }
        return collected
    }

    public func invalidate(packageID: String?, extensionID: ExtensionID? = nil) async {
        if let packageID {
            let removed = entries.removeValue(forKey: packageID) ?? []
            bytesUsed -= removed.reduce(0) { $0 + $1.snippet.utf8.count }
            bytesUsed = max(0, bytesUsed)
        } else {
            entries.removeAll()
            bytesUsed = 0
        }
        if let extensionID, let provider = providers[extensionID] {
            await provider.invalidate(packageID: packageID)
        }
    }

    public func allEntries(packageID: String? = nil) -> [DocumentationIndexEntry] {
        if let packageID {
            return entries[packageID] ?? []
        }
        return entries.values.flatMap { $0 }
    }

    public func bytesInUse() -> Int { bytesUsed }

    private func store(packageID: String, from data: Data, title: String) throws -> [DocumentationIndexEntry] {
        if bytesUsed + data.count > config.maxBytes {
            throw DocumentationIndexError.quotaExceeded
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.isEmpty {
            throw DocumentationIndexError.notFound(packageID)
        }
        // Split simple markdown headings into entries when possible.
        var built: [DocumentationIndexEntry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var currentTitle = title
        var currentBody: [String] = []
        var section = 0
        func flush() throws {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty || section == 0 else { return }
            section += 1
            let snippet = String((body.isEmpty ? currentTitle : body).prefix(500))
            let entry = DocumentationIndexEntry(
                id: "\(packageID)::\(section)",
                title: currentTitle,
                uri: "doc://\(packageID)/\(section)",
                snippet: snippet,
                packageID: packageID
            )
            built.append(entry)
        }
        for line in lines {
            if line.hasPrefix("#") {
                try flush()
                currentTitle =
                    line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).isEmpty
                    ? title
                    : line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }
        try flush()
        if built.isEmpty {
            throw DocumentationIndexError.notFound(packageID)
        }
        return try store(packageID: packageID, entries: built)
    }

    private func store(
        packageID: String, entries newEntries: [DocumentationIndexEntry]
    ) throws -> [DocumentationIndexEntry] {
        let addBytes = newEntries.reduce(0) { $0 + $1.snippet.utf8.count }
        if bytesUsed + addBytes > config.maxBytes {
            throw DocumentationIndexError.quotaExceeded
        }
        var list = entries[packageID] ?? []
        let total = entries.values.reduce(0) { $0 + $1.count }
        if total + newEntries.count > config.maxEntries {
            throw DocumentationIndexError.quotaExceeded
        }
        list.append(contentsOf: newEntries)
        entries[packageID] = list
        bytesUsed += addBytes
        let dest = config.storageRoot.appendingPathComponent("\(packageID).json")
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: dest, options: .atomic)
        }
        return newEntries
    }
}
