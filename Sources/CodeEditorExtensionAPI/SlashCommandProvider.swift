import Foundation

public struct SlashCommandContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var requiresWorktree: Bool
    public var maxArgumentLength: Int
    public var extensionID: ExtensionID?
    /// Feature classification (stable after residual closure).
    public var compatibility: CompatibilityFeatureStatus

    public init(
        id: String,
        name: String,
        description: String = "",
        requiresWorktree: Bool = false,
        maxArgumentLength: Int = 4_096,
        extensionID: ExtensionID? = nil,
        compatibility: CompatibilityFeatureStatus = .stable
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.requiresWorktree = requiresWorktree
        self.maxArgumentLength = maxArgumentLength
        self.extensionID = extensionID
        self.compatibility = compatibility
    }
}

public struct SlashCommandChunk: Sendable, Hashable, Codable {
    public var markdown: String
    public var isFinal: Bool

    public init(markdown: String, isFinal: Bool = false) {
        self.markdown = markdown
        self.isFinal = isFinal
    }
}

public struct SlashCommandExecuteContext: Sendable {
    public var extensionID: ExtensionID
    public var worktreeRoot: String?
    public var projectName: String?

    public init(extensionID: ExtensionID, worktreeRoot: String? = nil, projectName: String? = nil) {
        self.extensionID = extensionID
        self.worktreeRoot = worktreeRoot
        self.projectName = projectName
    }
}

public protocol SlashCommandProvider: Sendable {
    var commandIDs: [String] { get }
    func execute(
        commandID: String,
        arguments: String,
        context: SlashCommandExecuteContext
    ) -> AsyncThrowingStream<SlashCommandChunk, Error>
}

/// Sanitizes slash-command markdown before host rendering.
public enum SlashCommandSanitize {
    public static let maxChunkBytes = 32_768

    public static func sanitizeMarkdown(_ text: String) -> String {
        var out = text
        // Strip dangerous URL schemes
        let patterns = ["javascript:", "data:text/html", "vbscript:"]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
        }
        if out.utf8.count > maxChunkBytes {
            let idx = out.utf8.index(out.utf8.startIndex, offsetBy: maxChunkBytes)
            out = String(out.utf8[..<idx])!
        }
        return out
    }

    public static func validateArguments(_ args: String, maxLength: Int) throws {
        if args.utf8.count > maxLength {
            throw SlashCommandError.argumentsTooLong(args.utf8.count)
        }
    }
}

public enum SlashCommandError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case argumentsTooLong(Int)
    case cancelled
    case requiresWorktree
}
