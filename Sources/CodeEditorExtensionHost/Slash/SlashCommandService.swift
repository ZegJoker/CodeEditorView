import CodeEditorExtensionAPI
import Foundation

/// Host registry for slash commands (compatibility surface).
public actor SlashCommandService {
    private var contributions: [String: SlashCommandContribution] = [:]
    private var providers: [ExtensionID: any SlashCommandProvider] = [:]

    public init() {}

    public func registerContribution(_ c: SlashCommandContribution) {
        contributions[c.id] = c
    }

    public func registerProvider(_ provider: any SlashCommandProvider, extensionID: ExtensionID) {
        providers[extensionID] = provider
    }

    public func allContributions() -> [SlashCommandContribution] {
        contributions.values.sorted { $0.id < $1.id }
    }

    public func compatibilityStatus(for commandID: String) -> CompatibilityFeatureStatus {
        contributions[commandID]?.compatibility ?? .stable
    }

    public func execute(
        commandID: String,
        arguments: String,
        extensionID: ExtensionID,
        worktreeRoot: String? = nil
    ) -> AsyncThrowingStream<SlashCommandChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let contrib = contributions[commandID] else {
                        throw SlashCommandError.unknownCommand(commandID)
                    }
                    try SlashCommandSanitize.validateArguments(arguments, maxLength: contrib.maxArgumentLength)
                    if contrib.requiresWorktree, worktreeRoot == nil {
                        throw SlashCommandError.requiresWorktree
                    }
                    guard let provider = providers[extensionID] else {
                        throw SlashCommandError.unknownCommand(commandID)
                    }
                    let ctx = SlashCommandExecuteContext(
                        extensionID: extensionID,
                        worktreeRoot: worktreeRoot
                    )
                    for try await chunk in provider.execute(
                        commandID: commandID,
                        arguments: arguments,
                        context: ctx
                    ) {
                        if Task.isCancelled {
                            throw SlashCommandError.cancelled
                        }
                        let safe = SlashCommandChunk(
                            markdown: SlashCommandSanitize.sanitizeMarkdown(chunk.markdown),
                            isFinal: chunk.isFinal
                        )
                        continuation.yield(safe)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
