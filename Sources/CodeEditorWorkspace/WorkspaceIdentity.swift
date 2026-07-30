import Foundation
import CodeEditorDocuments

public struct WorkspaceID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct WorkspaceRootID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct WorkspaceRoot: Hashable, Codable, Sendable {
    public let id: WorkspaceRootID
    public let uri: DocumentURI
    public let name: String

    public init(id: WorkspaceRootID = WorkspaceRootID(), uri: DocumentURI, name: String) {
        self.id = id
        self.uri = uri
        self.name = name
    }

    public init(directoryURL: URL, id: WorkspaceRootID = WorkspaceRootID()) {
        self.id = id
        self.uri = DocumentURI(fileURL: directoryURL)
        self.name = directoryURL.lastPathComponent
    }
}

/// Provider-qualified workspace item identity (root + normalized relative path).
public struct WorkspaceItemID: Hashable, Codable, Sendable {
    public let rootID: WorkspaceRootID
    /// Normalized relative path using `/`. Empty string = root itself.
    public let path: String

    public init(rootID: WorkspaceRootID, path: String) {
        self.rootID = rootID
        self.path = WorkspacePath.normalize(path)
    }

    public var parentPath: String? {
        if path.isEmpty { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    public var name: String {
        if path.isEmpty { return "" }
        return path.split(separator: "/").map(String.init).last ?? path
    }
}

public struct WorkspaceItem: Hashable, Codable, Sendable {
    public let id: WorkspaceItemID
    public let name: String
    public let isDirectory: Bool
    public let uri: DocumentURI

    public init(id: WorkspaceItemID, name: String, isDirectory: Bool, uri: DocumentURI) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.uri = uri
    }
}

public struct EditorPaneID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct EditorSplitID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct EditorTabID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public enum EditorSplitAxis: String, Codable, Sendable, Hashable {
    case horizontal
    case vertical
}

public enum WorkspacePath {
    public static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        var stack: [String] = []
        for part in parts {
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(part)
            }
        }
        return stack.joined(separator: "/")
    }

    public static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty { return normalize(name) }
        return normalize(base + "/" + name)
    }
}
