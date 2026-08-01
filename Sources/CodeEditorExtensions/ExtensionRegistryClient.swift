import CodeEditorExtensionAPI
import Foundation

public enum ExtensionRegistryError: Error, Sendable, Equatable {
    case invalidScheme(String)
    case invalidIndex(String)
    case notFound(String)
    case network(String)
}

/// Host-side registry/index client. Tests use `file://` indexes; remote is HTTPS-only.
public struct ExtensionRegistryClient: Sendable {
    public var allowHTTP: Bool

    public init(allowHTTP: Bool = false) {
        self.allowHTTP = allowHTTP
    }

    public func fetchIndex(from url: URL) async throws -> ExtensionIndexDocument {
        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
        case "file":
            let data = try Data(contentsOf: url)
            return try decodeIndex(data)
        case "https":
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ExtensionRegistryError.network("HTTP \(http.statusCode)")
            }
            return try decodeIndex(data)
        case "http":
            if allowHTTP {
                let (data, _) = try await URLSession.shared.data(from: url)
                return try decodeIndex(data)
            }
            throw ExtensionRegistryError.invalidScheme("http")
        default:
            throw ExtensionRegistryError.invalidScheme(scheme.isEmpty ? "missing" : scheme)
        }
    }

    public func resolve(
        index: ExtensionIndexDocument,
        id: ExtensionID,
        version: String? = nil,
        channel: String = "stable",
        baseURL: URL? = nil
    ) throws -> ExtensionArtifactRef {
        guard let entry = index.packages.first(where: { $0.id == id.rawValue }) else {
            throw ExtensionRegistryError.notFound(id.rawValue)
        }
        let candidates = entry.versions.filter { $0.channel == channel || channel == "*" }
        let chosen: ExtensionIndexVersion
        if let version {
            guard let v = candidates.first(where: { $0.version == version }) else {
                throw ExtensionRegistryError.notFound("\(id.rawValue)@\(version)")
            }
            chosen = v
        } else {
            guard let v = candidates.sorted(by: { $0.version > $1.version }).first else {
                throw ExtensionRegistryError.notFound(id.rawValue)
            }
            chosen = v
        }
        var local: URL?
        var remote: URL?
        if chosen.artifactPath.hasPrefix("file:") {
            local = URL(string: chosen.artifactPath)
        } else if chosen.artifactPath.hasPrefix("https:") {
            remote = URL(string: chosen.artifactPath)
        } else if let base = baseURL {
            let resolved = Self.join(base: base, relative: chosen.artifactPath)
            if (base.scheme ?? "").lowercased() == "https" {
                remote = resolved
            } else {
                local = resolved
            }
        } else if chosen.artifactPath.hasPrefix("/") {
            local = URL(fileURLWithPath: chosen.artifactPath)
        } else {
            local = URL(fileURLWithPath: chosen.artifactPath).standardizedFileURL
        }
        return ExtensionArtifactRef(
            packageID: id.rawValue,
            version: chosen.version,
            localPath: local,
            remoteURL: remote,
            digest: chosen.digest
        )
    }

    /// Materialize an artifact into `destinationDirectory` (local copy or HTTPS download).
    public func materialize(
        ref: ExtensionArtifactRef,
        into destinationDirectory: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let dest =
            destinationDirectory
            .appendingPathComponent(ref.packageID, isDirectory: true)
            .appendingPathComponent(ref.version, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        if let local = ref.localPath {
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw ExtensionRegistryError.notFound(local.path)
            }
            try FileManager.default.copyItem(at: local, to: dest)
            return dest
        }
        if let remote = ref.remoteURL {
            let scheme = (remote.scheme ?? "").lowercased()
            if scheme == "http" && !allowHTTP {
                throw ExtensionRegistryError.invalidScheme("http")
            }
            if scheme != "https" && scheme != "http" {
                throw ExtensionRegistryError.invalidScheme(scheme)
            }
            let (data, response) = try await URLSession.shared.data(from: remote)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ExtensionRegistryError.network("HTTP \(http.statusCode)")
            }
            // Remote artifacts are expected to be zip or directory archives in production;
            // for file payloads write a package directory with the downloaded bytes as artifact.bin
            // only when Content-Type is not a directory listing — tests use localPath.
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try data.write(to: dest.appendingPathComponent("artifact.bin"), options: .atomic)
            return dest
        }
        throw ExtensionRegistryError.notFound("\(ref.packageID)@\(ref.version)")
    }

    private static func join(base: URL, relative: String) -> URL {
        var url = base
        if !url.hasDirectoryPath {
            url = url.deletingLastPathComponent()
        }
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        for part in parts {
            url = url.appendingPathComponent(part, isDirectory: false)
        }
        // If last segment looks like a version dir, treat as directory for copy source.
        return url
    }

    private func decodeIndex(_ data: Data) throws -> ExtensionIndexDocument {
        do {
            return try JSONDecoder().decode(ExtensionIndexDocument.self, from: data)
        } catch {
            throw ExtensionRegistryError.invalidIndex(String(describing: error))
        }
    }
}
