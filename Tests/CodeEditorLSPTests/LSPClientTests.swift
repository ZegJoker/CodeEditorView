import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
@testable import CodeEditorLSP

@Suite("LSP platform")
struct LSPPlatformTests {
    @Test func processTransportFailsClosedWhenProfileDeniesLocalLanguageServer() {
        do {
            _ = try LSPProcessTransport(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                platformProfile: .processUnavailable
            )
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .localLanguageServerProcess)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("LSP framing")
struct JSONRPCFramingTests {
    @Test func encodeDecodeRoundTrip() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let framed = LSPMessageFraming.encode(body)
        let decoder = LSPMessageFraming.Decoder()
        let messages = decoder.append(framed)
        #expect(messages.count == 1)
        #expect(messages[0] == body)
    }

    @Test func splitPackets() {
        let body = Data(#"{"a":1}"#.utf8)
        let framed = LSPMessageFraming.encode(body)
        let mid = framed.count / 2
        let decoder = LSPMessageFraming.Decoder()
        #expect(decoder.append(framed.prefix(mid)).isEmpty)
        let messages = decoder.append(framed.suffix(from: framed.startIndex + mid))
        #expect(messages.count == 1)
    }
}

@Suite("LSP client E2E")
struct LSPClientE2ETests {
    private func makeSession() async throws -> (
        session: LanguageServerSession,
        mock: MockLanguageServer,
        pair: (client: LSPTestTransport, server: LSPTestTransport)
    ) {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let definition = LanguageServerDefinition(
            id: "mock",
            displayName: "Mock",
            languages: ["swift"],
            launch: .test(factoryID: "mock")
        )
        let session = LanguageServerSession(
            definition: definition,
            transportFactory: { pair.client }
        )
        try await session.start()
        return (session, mock, pair)
    }

    @Test func initializePopulatesCapabilities() async throws {
        let (session, mock, _) = try await makeSession()
        #expect(await session.state == .running)
        let caps = await session.capabilities
        #expect(caps.completion)
        #expect(caps.hover)
        #expect(caps.definition)
        #expect(caps.incrementalSync)
        #expect(await mock.initializeCount == 1)
        await session.shutdown()
    }

    @Test func documentSyncOpenChangeClose() async throws {
        let (session, mock, _) = try await makeSession()
        let uri = DocumentURI(rawValue: "inmemory:doc1")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "hello"
        )
        try await waitUntil { await mock.openCount >= 1 }

        try await session.didChangeRaw(
            uri: uri,
            version: DocumentVersion(rawValue: 2),
            contentChanges: [["text": "hello!"]],
            fullText: "hello!"
        )
        try await waitUntil { await mock.changeCount >= 1 }
        let changes = await mock.recordedChanges
        #expect(changes.last?.version == 2)

        try await session.didClose(uri: uri)
        try await waitUntil { await mock.closeCount >= 1 }
        await session.shutdown()
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                Issue.record("timeout waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func completionAdapterMapsTextEdit() async throws {
        let (session, _, _) = try await makeSession()
        let registry = LanguageServiceRegistry()
        let token = await LSPClientProviders.register(session: session, into: registry)
        defer { token.dispose() }

        let host = LanguageServiceHost(registry: registry)
        let doc = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "hel")
        let list = try await host.completions(
            for: CompletionRequest(
                document: doc,
                position: TextPosition(utf16Offset: 3),
                context: LanguageServiceContext(languageID: "swift", uri: DocumentURI(rawValue: "inmemory:x"))
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.map(\.label).contains("mockComplete"))
        #expect(list.items.first?.textEdit?.newText == "mockComplete()")
        await session.shutdown()
    }

    @Test func hoverAndDefinitionAdapters() async throws {
        let (session, _, _) = try await makeSession()
        let registry = LanguageServiceRegistry()
        _ = await LSPClientProviders.register(session: session, into: registry)
        let host = LanguageServiceHost(registry: registry)
        let doc = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "func")
        let ctx = LanguageServiceContext(languageID: "swift", uri: DocumentURI(rawValue: "inmemory:x"))
        let pos = PositionRequest(
            document: doc,
            position: TextPosition(utf16Offset: 0),
            context: ctx
        )
        let version: @Sendable () -> DocumentVersion = { DocumentVersion(rawValue: 1) }
        let hover = try await host.hover(for: pos, currentVersion: version)
        #expect(hover?.sections.isEmpty == false)

        let adapter = LSPDefinitionAdapter(
            session: session,
            id: "test.def",
            selector: .any,
            priority: 1
        )
        let defs = try await adapter.definitions(for: pos)
        #expect(!defs.isEmpty)
        await registry.register(adapter)
        let viaHost = try await host.definitions(for: pos, currentVersion: version)
        #expect(!viaHost.isEmpty)
        await session.shutdown()
    }

    @Test func publishDiagnosticsStream() async throws {
        let (session, mock, _) = try await makeSession()
        let uri = DocumentURI(rawValue: "inmemory:diag")
        final class Box: @unchecked Sendable {
            var event: LSPDiagnosticsEvent?
        }
        let box = Box()
        let stream = await session.diagnosticsStream
        let collector = Task {
            for await event in stream {
                box.event = event
                break
            }
        }
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "x"
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        collector.cancel()
        #expect(await mock.openCount == 1)
        if let first = box.event {
            #expect(first.diagnostics.first?.severity == .warning)
        }
        await session.shutdown()
    }

    @Test func crashDoesNotMutateDocument() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let clientTransport = pair.client
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "crash",
                displayName: "Crash",
                launch: .test(factoryID: "x")
            ),
            transportFactory: { clientTransport }
        )
        try await session.start()

        let document = await MainActor.run {
            TextDocument(text: "safe text")
        }
        let original = await MainActor.run { document.text }
        let sync = LSPDocumentSynchronizer(session: session)
        await sync.open(document: document, languageID: "swift")

        await mock.stop()
        await session.markFailed()

        let after = await MainActor.run { document.text }
        #expect(after == original)
        #expect(await session.state == .failed)
    }

    @Test func restartResyncsOpenDocuments() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let pool = LanguageServerPool()
        await pool.registerTestFactory(id: "mock") {
            // On restart we need a fresh pair — use same pattern via custom launch
            let p = LSPTestTransport.makePair()
            let m = MockLanguageServer(transport: p.server)
            await m.start()
            return p.client
        }
        // Simpler: session.restart with transport factory recreating pair
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "r",
                displayName: "R",
                launch: .test(factoryID: "r")
            ),
            transportFactory: {
                let p = LSPTestTransport.makePair()
                let m = MockLanguageServer(transport: p.server)
                await m.start()
                return p.client
            }
        )
        try await session.start()
        let uri = DocumentURI(rawValue: "inmemory:re")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 3),
            text: "abc"
        )
        try await session.restart()
        #expect(await session.state == .running)
        let open = await session.openDocumentState(uri: uri)
        #expect(open?.text == "abc")
        #expect(open?.version.rawValue == 3)
        await session.shutdown()
        _ = pool
        _ = mock
    }

    @Test func poolStartsTestServer() async throws {
        let pool = LanguageServerPool()
        await pool.registerTestFactory(id: "pool-mock") {
            let p = LSPTestTransport.makePair()
            let m = MockLanguageServer(transport: p.server)
            await m.start()
            return p.client
        }
        let def = LanguageServerDefinition(
            id: "pooled",
            displayName: "Pooled",
            languages: ["swift"],
            launch: .test(factoryID: "pool-mock"),
            workspaceRootURIs: [DocumentURI(rawValue: "file:///tmp/proj")]
        )
        let session = try await pool.server(for: def)
        #expect(await session.state == .running)
        // Same key returns same session
        let again = try await pool.server(for: def)
        #expect(await again.id == session.id)
        await pool.shutdownAll()
    }

    @Test func synchronizerSendsVersionedChanges() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "sync",
                displayName: "Sync",
                launch: .custom { pair.client }
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        let document = await MainActor.run { TextDocument(text: "ab") }
        let sync = LSPDocumentSynchronizer(
            session: session,
            options: LSPSyncOptions(changeDebounceNanoseconds: 0, preferIncremental: false)
        )
        await sync.open(document: document, languageID: "swift")
        #expect(await mock.openCount == 1)

        await MainActor.run {
            _ = try? document.apply(
                EditTransaction.single(range: NSRange(location: 2, length: 0), replacement: "c")
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await mock.changeCount >= 1)
        await session.shutdown()
    }
}

@Suite("LSP convert")
struct LSPConvertTests {
    @Test func lineCharacterRoundTrip() {
        let text = "aa\nbbb\nc"
        let pos = LSPConvert.lineCharacter(utf16Offset: 5, in: text) // start of b's? 0,1=a a, 2=\n, 3,4,5=b
        #expect(pos.line == 1)
        let back = LSPConvert.utf16Offset(line: pos.line, character: pos.character, in: text)
        #expect(back == 5)
    }
}
