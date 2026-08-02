import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorLanguageServices

@Suite("LanguageServiceHost")
struct LanguageServiceHostTests {
    private func snapshot(_ text: String = "hello world", version: UInt64 = 1) -> DocumentSnapshot {
        DocumentSnapshot(version: DocumentVersion(rawValue: version), text: text)
    }

    @Test func mockSampleCoversAllCapabilities() async throws {
        let registry = LanguageServiceRegistry()
        let mock = MockLanguageSuite.sample()
        await mock.register(in: registry)
        let host = LanguageServiceHost(registry: registry)
        let doc = snapshot()
        let ctx = LanguageServiceContext(languageID: "swift", uri: DocumentURI(rawValue: "inmemory:sample"))
        let pos = PositionRequest(document: doc, position: TextPosition(utf16Offset: 0), context: ctx)
        let full = DocumentRequest(document: doc, context: ctx)
        let range = RangeRequest(
            document: doc,
            range: CodeEditorCore.TextRange(location: 0, length: 5),
            context: ctx
        )
        let version: @Sendable () -> DocumentVersion = { DocumentVersion(rawValue: 1) }

        let completions = try await host.completions(
            for: CompletionRequest(document: doc, position: TextPosition(utf16Offset: 0), context: ctx),
            currentVersion: version
        )
        #expect(!completions.items.isEmpty)
        #expect(completions.items[0].textEdit != nil)

        #expect(try await host.hover(for: pos, currentVersion: version) != nil)
        #expect(!(try await host.definitions(for: pos, currentVersion: version)).isEmpty)
        #expect(!(try await host.declarations(for: pos, currentVersion: version)).isEmpty)
        #expect(!(try await host.implementations(for: pos, currentVersion: version)).isEmpty)
        #expect(!(try await host.references(for: pos, currentVersion: version)).isEmpty)
        #expect(!(try await host.diagnostics(for: full, currentVersion: version)).isEmpty)
        #expect(!(try await host.documentSymbols(for: full, currentVersion: version)).isEmpty)
        #expect(!(try await host.workspaceSymbols(query: "hel", context: ctx)).isEmpty)
        #expect(!(try await host.format(full, currentVersion: version)).isEmpty)
        #expect(!(try await host.rename(pos, newName: "x", currentVersion: version)).documentEdits.isEmpty)
        #expect(!(try await host.codeActions(for: range, currentVersion: version)).isEmpty)
        #expect(!(try await host.semanticTokens(for: full, currentVersion: version)).isEmpty)
        #expect(!(try await host.inlayHints(for: range, currentVersion: version)).isEmpty)
        #expect(!(try await host.foldingRanges(for: full, currentVersion: version)).isEmpty)
        #expect(try await host.signatureHelp(for: pos, currentVersion: version) != nil)
        #expect(!(try await host.documentLinks(for: full, currentVersion: version)).isEmpty)
        #expect(!(try await host.documentColors(for: full, currentVersion: version)).isEmpty)
    }

    @Test func formattingUsesHighestPriorityOnly() async throws {
        let registry = LanguageServiceRegistry()
        let low = MockLanguageSuite(
            id: "fmt.low",
            priority: 1,
            formatEdits: [TextEditPlan(range: CodeEditorCore.TextRange(location: 0, length: 1), newText: "L")]
        )
        let high = MockLanguageSuite(
            id: "fmt.high",
            priority: 50,
            formatEdits: [TextEditPlan(range: CodeEditorCore.TextRange(location: 0, length: 1), newText: "H")]
        )
        await registry.register(low as any FormattingProvider)
        await registry.register(high as any FormattingProvider)
        let host = LanguageServiceHost(registry: registry)
        let doc = snapshot()
        let edits = try await host.format(
            DocumentRequest(document: doc, context: LanguageServiceContext()),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(edits.count == 1)
        #expect(edits[0].newText == "H")
    }

    @Test func completionsMergeByPriority() async throws {
        let registry = LanguageServiceRegistry()
        await registry.register(
            MockLanguageSuite(
                id: "a",
                priority: 1,
                completionItems: [CompletionItem(label: "low")]
            ) as any CompletionProvider)
        await registry.register(
            MockLanguageSuite(
                id: "b",
                priority: 10,
                completionItems: [CompletionItem(label: "high")]
            ) as any CompletionProvider)
        let host = LanguageServiceHost(registry: registry)
        let list = try await host.completions(
            for: CompletionRequest(
                document: snapshot(),
                position: TextPosition(utf16Offset: 0)
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(Set(list.items.map(\.label)) == Set(["low", "high"]))
    }

    @Test func staleVersionThrows() async throws {
        let registry = LanguageServiceRegistry()
        let mock = MockLanguageSuite(
            id: "slow",
            completionItems: [CompletionItem(label: "x")],
            delayNanoseconds: 30_000_000
        )
        await registry.register(mock as any CompletionProvider)
        let host = LanguageServiceHost(registry: registry)

        final class Box: @unchecked Sendable {
            var version = DocumentVersion(rawValue: 1)
        }
        let box = Box()
        let request = CompletionRequest(
            document: snapshot(version: 1),
            position: TextPosition(utf16Offset: 0)
        )

        async let result = host.completions(for: request) { box.version }
        try await Task.sleep(nanoseconds: 5_000_000)
        box.version = DocumentVersion(rawValue: 2)

        do {
            _ = try await result
            Issue.record("expected staleVersion error")
        } catch let error as LanguageServiceError {
            guard case .staleVersion = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func selectorFiltersProviders() async throws {
        let registry = LanguageServiceRegistry()
        await registry.register(
            MockLanguageSuite(
                id: "swift.only",
                selector: .languages("swift"),
                completionItems: [CompletionItem(label: "swiftItem")]
            ) as any CompletionProvider)
        await registry.register(
            MockLanguageSuite(
                id: "json.only",
                selector: .languages("json"),
                completionItems: [CompletionItem(label: "jsonItem")]
            ) as any CompletionProvider)
        let host = LanguageServiceHost(registry: registry)
        let list = try await host.completions(
            for: CompletionRequest(
                document: snapshot(),
                position: TextPosition(utf16Offset: 0),
                context: LanguageServiceContext(languageID: "swift")
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.map(\.label) == ["swiftItem"])
    }

    @Test func unregisterRemovesProvider() async throws {
        let registry = LanguageServiceRegistry()
        let mock = MockLanguageSuite.sample(priority: 1)
        await mock.register(in: registry)
        await registry.unregister(id: mock.id)
        let host = LanguageServiceHost(registry: registry)
        let list = try await host.completions(
            for: CompletionRequest(
                document: snapshot(),
                position: TextPosition(utf16Offset: 0)
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.isEmpty)
    }
}
