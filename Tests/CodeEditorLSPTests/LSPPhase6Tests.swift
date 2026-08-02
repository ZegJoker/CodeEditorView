import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorLSP

@Suite("LSP framing fuzz")
struct LSPFramingFuzzTests {
    @Test func splitHeadersAndMultipleMessages() {
        let a = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let b = Data(#"{"jsonrpc":"2.0","method":"x"}"#.utf8)
        var payload = LSPMessageFraming.encode(a)
        payload.append(LSPMessageFraming.encode(b))
        let decoder = LSPMessageFraming.Decoder()
        // Feed one byte at a time
        var out: [Data] = []
        for byte in payload {
            out.append(contentsOf: decoder.append(Data([byte])))
        }
        #expect(out.count == 2)
        #expect(out[0] == a)
        #expect(out[1] == b)
    }

    @Test func bodyTooLargeRejected() {
        let decoder = LSPMessageFraming.Decoder(maxBodyBytes: 8)
        let header = Data("Content-Length: 100\r\n\r\n".utf8)
        let body = Data(repeating: 0x61, count: 100)
        var data = header
        data.append(body)
        let messages = decoder.append(data)
        #expect(messages.isEmpty)
        #expect(decoder.lastError == .bodyTooLarge(100))
    }

    @Test func invalidLengthHeader() {
        let decoder = LSPMessageFraming.Decoder()
        let bad = Data("Content-Length: nope\r\n\r\n{}".utf8)
        _ = decoder.append(bad)
        #expect(decoder.lastError == .invalidHeader)
    }

    @Test func hugeHeaderBufferOverflow() {
        let decoder = LSPMessageFraming.Decoder(maxBodyBytes: 16, maxBufferBytes: 64)
        let huge = Data(repeating: 0x41, count: 200)
        _ = decoder.append(huge)
        #expect(decoder.lastError == .bufferOverflow(200))
    }
}

@Suite("LSP position map")
struct LSPPositionMapTests {
    @Test func lineIndexRoundTrip() {
        let text = "ab\ncde\n\nfg"
        let map = LSPPositionMap(version: DocumentVersion(rawValue: 1), text: text)
        #expect(map.lineStarts.count == 4)
        let p = map.position(utf16Offset: 5)  // 'e'
        #expect(p.line == 1)
        #expect(p.character == 2)
        #expect(map.utf16Offset(line: 1, character: 2) == 5)
        #expect(map.utf16Offset(line: 3, character: 1) == 9)
    }

    @Test func cacheInvalidatesOnVersion() async {
        let cache = LSPPositionMapCache()
        let uri = DocumentURI(rawValue: "inmemory:t")
        let m1 = await cache.map(for: uri, version: DocumentVersion(rawValue: 1), text: "a\nb")
        let m1b = await cache.map(for: uri, version: DocumentVersion(rawValue: 1), text: "a\nb")
        #expect(m1.lineStarts == m1b.lineStarts)
        let m2 = await cache.map(for: uri, version: DocumentVersion(rawValue: 2), text: "a\nb\nc")
        #expect(m2.lineStarts.count == 3)
    }
}

@Suite("LSP bidirectional RPC")
struct LSPBidirectionalTests {
    private func makePair() async throws -> (
        session: LanguageServerSession,
        mock: MockLanguageServer
    ) {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "mock",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "mock")
            ),
            budgets: LSPServerBudgets(
                requestTimeout: .seconds(2),
                restartMaxAttempts: 3,
                restartInitialBackoff: .milliseconds(1),
                restartMaxBackoff: .milliseconds(5)
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        return (session, mock)
    }

    @Test func fullCapabilityAdaptersMatrix() async throws {
        let (session, _) = try await makePair()
        let caps = await session.capabilities
        #expect(caps.completion)
        #expect(caps.declaration)
        #expect(caps.implementation)
        #expect(caps.references)
        #expect(caps.pullDiagnostics)
        #expect(caps.inlayHint)
        #expect(caps.executeCommand)
        #expect(caps.semanticTokensRange)

        let registry = LanguageServiceRegistry()
        let registration = await LSPClientProviders.register(session: session, into: registry)
        let host = LanguageServiceHost(registry: registry)
        let uri = DocumentURI(rawValue: "inmemory:doc")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "func hello() {}"
        )
        let doc = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "func hello() {}")
        let ctx = LanguageServiceContext(languageID: "swift", uri: uri)
        let pos = PositionRequest(document: doc, position: TextPosition(utf16Offset: 5), context: ctx)
        let full = DocumentRequest(document: doc, context: ctx)
        let range = RangeRequest(
            document: doc,
            range: CodeEditorCore.TextRange(location: 0, length: 4),
            context: ctx
        )
        let v: @Sendable () -> DocumentVersion = { DocumentVersion(rawValue: 1) }

        #expect(
            !(try await host.completions(
                for: CompletionRequest(document: doc, position: TextPosition(utf16Offset: 5), context: ctx),
                currentVersion: v
            )).items.isEmpty)
        #expect(try await host.hover(for: pos, currentVersion: v) != nil)
        #expect(!(try await host.definitions(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.declarations(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.implementations(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.references(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.format(full, currentVersion: v)).isEmpty)
        #expect(!(try await host.formatRange(range, currentVersion: v)).isEmpty)
        #expect(!(try await host.rename(pos, newName: "x", currentVersion: v)).documentEdits.isEmpty)
        #expect(!(try await host.documentSymbols(for: full, currentVersion: v)).isEmpty)
        #expect(!(try await host.workspaceSymbols(query: "m", context: ctx)).isEmpty)
        #expect(!(try await host.semanticTokens(for: full, currentVersion: v)).isEmpty)
        #expect(!(try await host.codeActions(for: range, currentVersion: v)).isEmpty)
        #expect(try await host.signatureHelp(for: pos, currentVersion: v) != nil)
        #expect(!(try await host.inlayHints(for: range, currentVersion: v)).isEmpty)
        #expect(!(try await host.foldingRanges(for: full, currentVersion: v)).isEmpty)
        #expect(!(try await host.documentLinks(for: full, currentVersion: v)).isEmpty)
        #expect(!(try await host.documentColors(for: full, currentVersion: v)).isEmpty)
        #expect(!(try await host.documentHighlights(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.prepareTypeHierarchy(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.prepareCallHierarchy(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.pullDiagnostics(for: full, currentVersion: v)).items.isEmpty)
        let cmd = try await host.executeCommand(
            ExecuteCommandRequest(command: "mock.cmd", context: ctx)
        )
        #expect(cmd.message == "executed")

        registration.dispose()
        await session.shutdown()
    }

    @Test func serverApplyEditRequest() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.setRequestApplyEditAfterInit(true)
        await mock.start()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "mock",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "mock")
            ),
            transportFactory: { pair.client }
        )
        final class Box: @unchecked Sendable {
            var applied = false
        }
        let box = Box()
        await session.setApplyEditHandler { _ in
            box.applied = true
            return true
        }
        try await session.start()
        // Give mock time to send server request after initialized
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.applied)
        await session.shutdown()
    }

    @Test func progressStreamReceivesEvents() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.setSendProgressAfterInit(true)
        await mock.start()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "mock",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "mock")
            ),
            transportFactory: { pair.client }
        )
        final class Flag: @unchecked Sendable {
            var sawBegin = false
        }
        let flag = Flag()
        // Subscribe before start so begin is not missed.
        let stream = await session.progressStream
        let collect = Task {
            for await event in stream {
                if event.kind == "begin" {
                    flag.sawBegin = true
                    break
                }
            }
        }
        try await session.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        collect.cancel()
        #expect(flag.sawBegin)
        await session.shutdown()
    }

    @Test func restartResyncsOpenDocuments() async throws {
        // Fresh client/server pair per start so shutdown can close transports.
        final class Factory: @unchecked Sendable {
            var lastMock: MockLanguageServer?
            func make() async throws -> any LSPTransport {
                let pair = LSPTestTransport.makePair()
                let mock = MockLanguageServer(transport: pair.server)
                await mock.start()
                lastMock = mock
                return pair.client
            }
        }
        let factory = Factory()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "mock",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "mock")
            ),
            budgets: LSPServerBudgets(
                restartMaxAttempts: 3,
                restartInitialBackoff: .milliseconds(1),
                restartMaxBackoff: .milliseconds(5)
            ),
            transportFactory: { try await factory.make() }
        )
        try await session.start()
        let uri = DocumentURI(rawValue: "inmemory:rs")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "hello"
        )
        try await Phase6Wait.until { await factory.lastMock?.openCount ?? 0 >= 1 }
        try await session.restart()
        try await Phase6Wait.until { await factory.lastMock?.initializeCount ?? 0 >= 1 }
        try await Phase6Wait.until { await factory.lastMock?.openCount ?? 0 >= 1 }
        await session.shutdown()
    }

    @Test func dynamicRegistrationHandled() async throws {
        let (session, mock) = try await makePair()
        // Server-side request for client/registerCapability
        await mock.request(
            id: 99,
            method: "client/registerCapability",
            params: [
                "registrations": [
                    [
                        "id": "reg-1",
                        "method": "textDocument/completion",
                        "registerOptions": [:] as [String: Any],
                    ] as [String: Any]
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        let ids = await session.dynamicRegistrationIDs()
        #expect(ids.contains("reg-1"))
        await session.shutdown()
    }
}

// MockLanguageServer actor setters
extension MockLanguageServer {
    func setRequestApplyEditAfterInit(_ value: Bool) {
        requestApplyEditAfterInit = value
    }

    func setSendProgressAfterInit(_ value: Bool) {
        sendProgressAfterInit = value
    }
}

// LanguageServerSession applyEdit handler setter (actor)
extension LanguageServerSession {
    func setApplyEditHandler(_ handler: @escaping @Sendable (WorkspaceEditPlan) async -> Bool) {
        applyEditHandler = handler
    }
}

private enum Phase6Wait {
    static func until(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                throw LSPError.timeout(method: "waitUntil")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
