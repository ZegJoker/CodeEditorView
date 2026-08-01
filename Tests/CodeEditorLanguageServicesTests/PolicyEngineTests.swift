import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorLanguageServices

@Suite("LanguageServices policy engine")
struct PolicyEngineTests {
    private func snapshot(_ text: String = "hello world", version: UInt64 = 1) -> DocumentSnapshot {
        DocumentSnapshot(version: DocumentVersion(rawValue: version), text: text)
    }

    private var version1: @Sendable () -> DocumentVersion {
        { DocumentVersion(rawValue: 1) }
    }

    @Test func failureIsolationKeepsHealthyProvider() async throws {
        let registry = LanguageServiceRegistry()
        await registry.register(
            MockLanguageSuite(
                id: "bad",
                priority: 100,
                completionItems: [CompletionItem(label: "bad")],
                failure: .provider("boom")
            ) as any CompletionProvider)
        await registry.register(
            MockLanguageSuite(
                id: "good",
                priority: 1,
                completionItems: [CompletionItem(label: "good")]
            ) as any CompletionProvider)
        let host = LanguageServiceHost(registry: registry)
        let list = try await host.completions(
            for: CompletionRequest(document: snapshot(), position: TextPosition(utf16Offset: 0)),
            currentVersion: version1
        )
        #expect(list.items.map(\.label) == ["good"])
        let badHealth = await registry.healthSnapshot(for: "bad")
        #expect(badHealth.failureCount >= 1)
        let goodHealth = await registry.healthSnapshot(for: "good")
        #expect(goodHealth.successCount >= 1)
    }

    @Test func providerTimeoutIsIsolated() async throws {
        let registry = LanguageServiceRegistry()
        await registry.register(
            MockLanguageSuite(
                id: "slow",
                priority: 50,
                completionItems: [CompletionItem(label: "slow")],
                delayNanoseconds: 200_000_000
            ) as any CompletionProvider)
        await registry.register(
            MockLanguageSuite(
                id: "fast",
                priority: 1,
                completionItems: [CompletionItem(label: "fast")]
            ) as any CompletionProvider)
        var limits = LanguageServiceLimits.default
        limits.providerTimeout = .milliseconds(20)
        let host = LanguageServiceHost(registry: registry, limits: limits)
        let list = try await host.completions(
            for: CompletionRequest(document: snapshot(), position: TextPosition(utf16Offset: 0)),
            currentVersion: version1
        )
        #expect(list.items.map(\.label) == ["fast"])
        let health = await registry.healthSnapshot(for: "slow")
        #expect(health.timeoutCount >= 1)
    }

    @Test func categoryMatrixIsolationAndMerge() async throws {
        let registry = LanguageServiceRegistry()
        let bad = MockLanguageSuite(id: "bad", priority: 100, failure: .provider("x"))
        let good = MockLanguageSuite.sample(priority: 10)
        await bad.register(in: registry)
        await good.register(in: registry)
        let host = LanguageServiceHost(registry: registry)
        let doc = snapshot()
        let ctx = LanguageServiceContext(languageID: "swift", uri: DocumentURI(rawValue: "inmemory:sample"))
        let pos = PositionRequest(document: doc, position: TextPosition(utf16Offset: 0), context: ctx)
        let full = DocumentRequest(document: doc, context: ctx)
        let range = RangeRequest(
            document: doc,
            range: CodeEditorCore.TextRange(location: 0, length: 3),
            context: ctx
        )

        #expect(
            !(try await host.completions(
                for: CompletionRequest(document: doc, position: TextPosition(utf16Offset: 0), context: ctx),
                currentVersion: version1
            )).items.isEmpty)
        #expect(try await host.hover(for: pos, currentVersion: version1) != nil)
        #expect(!(try await host.definitions(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.declarations(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.implementations(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.references(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.diagnostics(for: full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.pullDiagnostics(for: full, currentVersion: version1)).items.isEmpty)
        #expect(!(try await host.documentSymbols(for: full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.workspaceSymbols(query: "hel", context: ctx)).isEmpty)
        #expect(!(try await host.format(full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.rename(pos, newName: "x", currentVersion: version1)).documentEdits.isEmpty)
        #expect(!(try await host.codeActions(for: range, currentVersion: version1)).isEmpty)
        #expect(!(try await host.semanticTokens(for: full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.inlayHints(for: range, currentVersion: version1)).isEmpty)
        #expect(!(try await host.foldingRanges(for: full, currentVersion: version1)).isEmpty)
        #expect(try await host.signatureHelp(for: pos, currentVersion: version1) != nil)
        #expect(!(try await host.documentLinks(for: full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.documentColors(for: full, currentVersion: version1)).isEmpty)
        #expect(!(try await host.documentHighlights(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.prepareTypeHierarchy(for: pos, currentVersion: version1)).isEmpty)
        #expect(!(try await host.prepareCallHierarchy(for: pos, currentVersion: version1)).isEmpty)
        let cmd = try await host.executeCommand(
            ExecuteCommandRequest(command: "mock.sample", context: ctx)
        )
        #expect(cmd.message == "ok")
    }

    @Test func sanitizeClampsMalformedRanges() {
        let ok = LanguageServiceSanitize.clampRange(
            CodeEditorCore.TextRange(location: 2, length: 3),
            documentLength: 5
        )
        #expect(ok?.location == 2)
        #expect(ok?.length == 3)

        let overflow = LanguageServiceSanitize.clampRange(
            CodeEditorCore.TextRange(location: 4, length: 10),
            documentLength: 5
        )
        #expect(overflow?.location == 4)
        #expect(overflow?.length == 1)

        let bad = LanguageServiceSanitize.sanitizeEdit(
            TextEditPlan(range: CodeEditorCore.TextRange(location: 100, length: 1), newText: "x"),
            documentLength: 5
        )
        #expect(bad?.range.location == 5)
        #expect(bad?.range.length == 0)

        let markup = LanguageServiceSanitize.truncateMarkup(
            .markdown(String(repeating: "a", count: 100)),
            maxCharacters: 10
        )
        #expect(markup.value.count == 10)
    }

    @Test func largeResultLimitsApplied() async throws {
        let registry = LanguageServiceRegistry()
        let many = (0..<100).map { CompletionItem(label: "item\($0)") }
        await registry.register(
            MockLanguageSuite(
                id: "many",
                completionItems: many
            ) as any CompletionProvider)
        var limits = LanguageServiceLimits.default
        limits.maxCompletionItems = 5
        let host = LanguageServiceHost(registry: registry, limits: limits)
        let list = try await host.completions(
            for: CompletionRequest(document: snapshot(), position: TextPosition(utf16Offset: 0)),
            currentVersion: version1
        )
        #expect(list.items.count == 5)
    }

    @Test func unregisterRaceDoesNotCrash() async throws {
        let registry = LanguageServiceRegistry()
        let mock = MockLanguageSuite(
            id: "race",
            completionItems: [CompletionItem(label: "x")],
            delayNanoseconds: 30_000_000
        )
        await mock.register(in: registry)
        let host = LanguageServiceHost(registry: registry)
        async let result = host.completions(
            for: CompletionRequest(document: snapshot(), position: TextPosition(utf16Offset: 0)),
            currentVersion: version1
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        await registry.unregister(id: "race")
        _ = try? await result
    }

    @Test func executeCommandNoProviderThrows() async throws {
        let registry = LanguageServiceRegistry()
        let host = LanguageServiceHost(registry: registry)
        do {
            _ = try await host.executeCommand(ExecuteCommandRequest(command: "missing"))
            Issue.record("expected noProvider")
        } catch let error as LanguageServiceError {
            #expect(error == .noProvider)
        }
    }
}
