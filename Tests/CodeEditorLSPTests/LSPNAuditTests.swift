import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorLSP

// MARK: - Helpers

private func makeMockSession(
    id: String = "mock-lspn"
) async throws -> (LanguageServerSession, MockLanguageServer, LSPTestTransport, LSPTestTransport) {
    let pair = LSPTestTransport.makePair()
    let mock = MockLanguageServer(transport: pair.server)
    await mock.start()
    let session = LanguageServerSession(
        definition: LanguageServerDefinition(
            id: LanguageServerID(rawValue: id),
            displayName: "Mock",
            languages: ["swift"],
            launch: .test(factoryID: id)
        ),
        budgets: LSPServerBudgets(requestTimeout: .seconds(2)),
        transportFactory: { pair.client }
    )
    try await session.start()
    return (session, mock, pair.client, pair.server)
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
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

// MARK: - LSP-N01

@Suite("LSP-N01 request registration")
struct LSPN01RequestRegistrationTests {
    @Test func test_LSP_N01_pendingRegisteredBeforeTimeoutWithoutUnstructuredTask() async throws {
        let pair = LSPTestTransport.makePair()
        // Never responds — client must time out cleanly without orphaning registration.
        let conn = LSPJSONRPCConnection(
            transport: pair.client,
            requestTimeout: .milliseconds(30)
        )
        await conn.start()
        var timedOut = false
        do {
            _ = try await conn.requestDictionary("slow/method", params: nil as LSPJSONObject?)
            Issue.record("expected timeout")
        } catch let error as LSPError {
            if case .timeout = error { timedOut = true }
        }
        #expect(timedOut)
        // Late response must be discarded, not retained for reuse.
        let late: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["ok": true]]
        let body = try JSONSerialization.data(withJSONObject: late)
        try await pair.server.send(LSPMessageFraming.encode(body))
        try await Task.sleep(nanoseconds: 30_000_000)
        let lateCount = await conn.lateResponseCount
        #expect(lateCount >= 1)
        let early = await conn.earlyResponseCount
        #expect(early == 0)
        // Connection remains usable for next request after late discard.
        let echoServer = Task {
            for await chunk in pair.server.inbound {
                let messages = LSPMessageFraming.Decoder().append(chunk)
                for msg in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any],
                        let id = obj["id"]
                    else { continue }
                    let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["v": 1]]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(LSPMessageFraming.encode(data))
                }
            }
        }
        let result = try await conn.requestDictionary("echo", params: LSPJSONObject([:]))
        #expect(result.dictionary["v"] as? Int == 1)
        echoServer.cancel()
        await conn.close()
    }

    @Test func test_LSP_N01_responseBeforeWaitCompletesWithoutEarlyMap() async throws {
        let pair = LSPTestTransport.makePair()
        let serverTask = Task {
            for await chunk in pair.server.inbound {
                let messages = LSPMessageFraming.Decoder().append(chunk)
                for body in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let id = obj["id"]
                    else { continue }
                    let response: [String: Any] = [
                        "jsonrpc": "2.0", "id": id, "result": ["instant": true],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(LSPMessageFraming.encode(data))
                }
            }
        }
        let conn = LSPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(2))
        await conn.start()
        for i in 0..<40 {
            let r = try await conn.requestDictionary("ping", params: LSPJSONObject(["i": i]))
            #expect(r.dictionary["instant"] as? Bool == true)
        }
        #expect(await conn.earlyResponseCount == 0)
        #expect(await conn.lateResponseCount == 0)
        serverTask.cancel()
        await conn.close()
    }

    @Test func test_LSP_N01_usesOneShotPromiseNotUnstructuredRegistrationTask() async throws {
        // Source contract: no nested registration Task pattern.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorLSP/Transport/LSPJSONRPCConnection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("OneShotPromise"))
        #expect(!source.contains("registerThenSend"))
        #expect(!source.contains("earlyResponses"))
        #expect(!source.contains("executeRegisteredRequest"))
    }
}

// MARK: - LSP-N02

@Suite("LSP-N02 message lanes")
struct LSPN02MessageLaneTests {
    @Test func test_LSP_N02_slowNotificationDoesNotStallResponse() async throws {
        let pair = LSPTestTransport.makePair()
        let conn = LSPJSONRPCConnection(transport: pair.client, requestTimeout: .seconds(3))
        await conn.start()

        final class Box: @unchecked Sendable {
            var notificationStarted = false
            var notificationFinished = false
        }
        let box = Box()

        await conn.setNotificationHandler { method, _ in
            if method == "slow/note" {
                box.notificationStarted = true
                try? await Task.sleep(nanoseconds: 200_000_000)
                box.notificationFinished = true
            }
        }

        // Server: send slow notification first, then reply to request quickly.
        let server = Task {
            // Wait for request
            let decoder = LSPMessageFraming.Decoder()
            for await chunk in pair.server.inbound {
                let messages = decoder.append(chunk)
                for body in messages {
                    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                        let id = obj["id"]
                    else { continue }
                    // Push slow notification BEFORE response arrives on client path
                    let note: [String: Any] = ["jsonrpc": "2.0", "method": "slow/note"]
                    let noteData = try! JSONSerialization.data(withJSONObject: note)
                    try? await pair.server.send(LSPMessageFraming.encode(noteData))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    let response: [String: Any] = [
                        "jsonrpc": "2.0", "id": id, "result": ["done": true],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: response)
                    try? await pair.server.send(LSPMessageFraming.encode(data))
                }
            }
        }

        let start = ContinuousClock.now
        let result = try await conn.requestDictionary("fast", params: nil as LSPJSONObject?)
        let elapsed = ContinuousClock.now - start
        #expect(result.dictionary["done"] as? Bool == true)
        // Response must complete well before the 200ms notification finishes.
        #expect(elapsed < .milliseconds(150))
        let noteFinished = box.notificationFinished
        // Notification may still be running when response returns.
        #expect(noteFinished == false || elapsed < .milliseconds(150))
        try await Task.sleep(nanoseconds: 250_000_000)
        server.cancel()
        await conn.close()
    }

    @Test func test_LSP_N02_stateOrderedNotificationsPreserveOrder() async throws {
        let pair = LSPTestTransport.makePair()
        let conn = LSPJSONRPCConnection(transport: pair.client)
        await conn.start()
        final class Box: @unchecked Sendable {
            var methods: [String] = []
        }
        let box = Box()
        await conn.setNotificationHandler { method, _ in
            if method.hasPrefix("textDocument/publishDiagnostics") || method.hasPrefix("ordered/") {
                try? await Task.sleep(nanoseconds: 5_000_000)
                box.methods.append(method)
            }
        }
        for name in ["ordered/a", "ordered/b", "ordered/c"] {
            let note: [String: Any] = ["jsonrpc": "2.0", "method": name]
            let data = try JSONSerialization.data(withJSONObject: note)
            try await pair.server.send(LSPMessageFraming.encode(data))
        }
        try await waitUntil {
            box.methods.count >= 3
        }
        let methods = box.methods
        #expect(methods == ["ordered/a", "ordered/b", "ordered/c"])
        await conn.close()
    }
}

// MARK: - LSP-N03 / N04

@Suite("LSP-N03/N04 synchronize API")
struct LSPN03N04SynchronizeTests {
    @Test @MainActor func test_LSP_N03_synchronizeRequiresBaseAndTransaction() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n03")
        let uri = DocumentURI(rawValue: "file:///n03.swift")
        let doc = TextDocument(uri: uri, text: "hello")
        let old = doc.snapshot()
        try await session.didOpen(uri: uri, languageID: "swift", version: old.version, text: old.text)
        let applied = try doc.apply(.single(range: NSRange(location: 5, length: 0), replacement: "!"))
        let new = doc.snapshot()
        try await session.synchronize(
            document: doc.id,
            uri: uri,
            from: old,
            applying: applied,
            to: new
        )
        try await waitUntil { await mock.changeCount >= 1 }
        let text = await mock.currentOpenText(uri: uri.rawValue)
        #expect(text == "hello!")
        // Public didChange must not invent {0,0} ranges — source contract.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorLSP/LanguageServerSession.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("\"character\": 0],\n                                \"end\": [\"line\": 0"))
        #expect(source.contains("func synchronize("))
        await session.shutdown()
    }

    @Test @MainActor func test_LSP_N04_capabilityAndPolicyDriveIncrementalVsFull() async throws {
        // preferIncremental + server incremental capability → incremental didChange (not full text).
        let (session, mock, _, _) = try await makeMockSession(id: "n04")
        let uri = DocumentURI(rawValue: "file:///n04.swift")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "abc"
        )
        #expect(await session.capabilities.textDocumentSyncKind == .incremental)
        #expect(await session.capabilities.incrementalSync == true)
        let old = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "abc")
        let applied = AppliedEditTransaction(
            transaction: .single(range: NSRange(location: 3, length: 0), replacement: "d"),
            oldVersion: DocumentVersion(rawValue: 1),
            newVersion: DocumentVersion(rawValue: 2),
            beforeState: DocumentContentStateID(),
            afterState: DocumentContentStateID(),
            inverse: .single(range: NSRange(location: 3, length: 1), replacement: ""),
            textEdits: []
        )
        let new = DocumentSnapshot(version: DocumentVersion(rawValue: 2), text: "abcd")
        try await session.synchronize(
            document: DocumentID(),
            uri: uri,
            from: old,
            applying: applied,
            to: new
        )
        try await waitUntil { await mock.changeCount >= 1 }
        #expect(await mock.currentOpenText(uri: uri.rawValue) == "abcd")
        #expect(await mock.lastChangeWasFullText == false)
        await session.shutdown()

        // forceFull host policy on a dedicated session — must send full-text didChange.
        let (session2, mock2, _, _) = try await makeMockSession(id: "n04full")
        let uri2 = DocumentURI(rawValue: "file:///n04full.swift")
        let syncFull = LSPDocumentSynchronizer(
            session: session2,
            options: LSPSyncOptions(changeDebounceNanoseconds: 0, syncPolicy: .forceFull)
        )
        let doc = TextDocument(uri: uri2, text: "abcd")
        await syncFull.open(document: doc, languageID: "swift")
        try await waitUntil { await mock2.openCount >= 1 }
        let old2 = doc.snapshot()
        let applied2 = try doc.apply(.single(range: NSRange(location: 4, length: 0), replacement: "e"))
        let new2 = doc.snapshot()
        // Explicit synchronize after observation settles so the asserted change is policy-driven.
        try await waitUntil { await mock2.changeCount >= 1 }
        try await syncFull.synchronize(document: doc, from: old2, applying: applied2, to: new2)
        try await waitUntil {
            await mock2.currentOpenText(uri: uri2.rawValue) == "abcde"
        }
        #expect(await mock2.lastChangeWasFullText == true)
        #expect(await mock2.currentOpenText(uri: uri2.rawValue) == "abcde")
        #expect(new2.text == "abcde")
        _ = applied2
        await session2.shutdown()
    }

    @Test @MainActor func test_LSP_N04_versionGapForcesFullResync() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n04gap")
        let uri = DocumentURI(rawValue: "file:///n04gap.swift")
        let doc = TextDocument(uri: uri, text: "v1")
        let sync = LSPDocumentSynchronizer(
            session: session,
            options: LSPSyncOptions(changeDebounceNanoseconds: 50_000_000, syncPolicy: .preferIncremental)
        )
        await sync.open(document: doc, languageID: "swift")
        try await waitUntil { await mock.openCount >= 1 }
        let opensBefore = await mock.openCount
        // Local edits without waiting for debounce — then force gap recovery full resync.
        _ = try doc.apply(.single(range: NSRange(location: 2, length: 0), replacement: "a"))
        _ = try doc.apply(.single(range: NSRange(location: 3, length: 0), replacement: "b"))
        let expected = doc.text
        #expect(expected == "v1ab")
        try await sync.handleSequenceGap(document: doc, languageID: "swift")
        // Gap recovery reopens (close+didOpen) with full current text.
        try await waitUntil { await mock.openCount > opensBefore }
        let serverText = await mock.currentOpenText(uri: uri.rawValue)
        #expect(serverText == expected)
        #expect(await mock.openCount >= opensBefore + 1)
        await session.shutdown()
    }
}

// MARK: - LSP-N05

@Suite("LSP-N05 gap recovery")
struct LSPN05GapRecoveryTests {
    @Test @MainActor func test_LSP_N05_streamGapTriggersFullResync() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n05")
        let uri = DocumentURI(rawValue: "file:///n05.swift")
        let doc = TextDocument(uri: uri, text: "base")
        let sync = LSPDocumentSynchronizer(
            session: session,
            options: LSPSyncOptions(changeDebounceNanoseconds: 0, syncPolicy: .preferIncremental)
        )
        await sync.open(document: doc, languageID: "swift")
        try await waitUntil { await mock.openCount >= 1 }
        let before = await mock.changeCount
        // Inject gap recovery path.
        try await sync.handleSequenceGap(document: doc, languageID: "swift")
        try await waitUntil {
            let changes = await mock.changeCount
            let opens = await mock.openCount
            return changes > before || opens > 1
        }
        let serverText = await mock.currentOpenText(uri: uri.rawValue)
        #expect(serverText == doc.text)
        await session.shutdown()
    }
}

// MARK: - LSP-N06

@Suite("LSP-N06 document lane")
struct LSPN06DocumentLaneTests {
    @Test @MainActor func test_LSP_N06_saveFlushesPendingChangeBeforeDidSave() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n06")
        let uri = DocumentURI(rawValue: "file:///n06.swift")
        let doc = TextDocument(uri: uri, text: "x")
        let sync = LSPDocumentSynchronizer(
            session: session,
            options: LSPSyncOptions(changeDebounceNanoseconds: 200_000_000, syncPolicy: .forceFull)
        )
        await sync.open(document: doc, languageID: "swift")
        try await waitUntil { await mock.openCount >= 1 }
        _ = try doc.apply(.single(range: NSRange(location: 1, length: 0), replacement: "y"))
        // Save must flush pending debounced change first, then didSave (hard barrier).
        await sync.noteSaved(uri: uri, text: doc.text)
        try await waitUntil {
            let methods = await mock.receivedMethods
            return methods.contains("textDocument/didChange")
                && methods.contains("textDocument/didSave")
        }
        let methods = await mock.receivedMethods
        let changeIdx = methods.lastIndex(of: "textDocument/didChange")
        let saveIdx = methods.lastIndex(of: "textDocument/didSave")
        #expect(changeIdx != nil, "didChange required before save; methods=\(methods)")
        #expect(saveIdx != nil, "didSave required; methods=\(methods)")
        #expect(
            changeIdx! < saveIdx!,
            "didChange index \(changeIdx!) must be before didSave \(saveIdx!); methods=\(methods)"
        )
        #expect(await mock.currentOpenText(uri: uri.rawValue) == "xy")
        await session.shutdown()
    }

    @Test @MainActor func test_LSP_N06_closeCancelsDebounceAndSendsClose() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n06close")
        let uri = DocumentURI(rawValue: "file:///n06c.swift")
        let doc = TextDocument(uri: uri, text: "a")
        let sync = LSPDocumentSynchronizer(
            session: session,
            options: LSPSyncOptions(changeDebounceNanoseconds: 500_000_000, syncPolicy: .forceFull)
        )
        await sync.open(document: doc, languageID: "swift")
        _ = try doc.apply(.single(range: NSRange(location: 1, length: 0), replacement: "b"))
        await sync.close(uri: uri)
        try await waitUntil { await mock.closeCount >= 1 }
        #expect(await mock.closeCount >= 1)
        await session.shutdown()
    }
}

// MARK: - LSP-N07

@Suite("LSP-N07 open commit after send")
struct LSPN07OpenStateTests {
    @Test func test_LSP_N07_openStateNotCommittedWhenNotifyFails() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let session = LanguageServerSession(
            definition: LanguageServerDefinition(
                id: "n07",
                displayName: "Mock",
                languages: ["swift"],
                launch: .test(factoryID: "n07")
            ),
            transportFactory: { pair.client }
        )
        try await session.start()
        // Close transport so next notify fails.
        await pair.client.close()
        let uri = DocumentURI(rawValue: "file:///n07.swift")
        var failed = false
        do {
            try await session.didOpen(
                uri: uri,
                languageID: "swift",
                version: DocumentVersion(rawValue: 1),
                text: "x"
            )
        } catch {
            failed = true
        }
        #expect(failed)
        let state = await session.openDocumentState(uri: uri)
        #expect(state == nil)
        let laneState = await session.documentOpenPhase(uri: uri)
        #expect(laneState == .closed || laneState == .failed)
        await session.shutdown()
    }

    @Test func test_LSP_N07_openStateCommittedAfterSuccessfulSend() async throws {
        let (session, _, _, _) = try await makeMockSession(id: "n07ok")
        let uri = DocumentURI(rawValue: "file:///n07ok.swift")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "ok"
        )
        #expect(await session.openDocumentState(uri: uri) != nil)
        #expect(await session.documentOpenPhase(uri: uri) == .open)
        await session.shutdown()
    }
}

// MARK: - LSP-N08

@Suite("LSP-N08 WorkspaceEdit decoding")
struct LSPN08WorkspaceEditTests {
    @Test func test_LSP_N08_decodesChangesDocumentChangesAndResourceOps() async throws {
        let (session, _, _, _) = try await makeMockSession(id: "n08")
        let edit: [String: Any] = [
            "changes": [
                "file:///a.swift": [
                    [
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 1],
                        ],
                        "newText": "Z",
                    ]
                ]
            ],
            "documentChanges": [
                [
                    "textDocument": [
                        "uri": "file:///b.swift",
                        "version": 3,
                    ],
                    "edits": [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 0],
                            ],
                            "newText": "prefix",
                        ]
                    ],
                ] as [String: Any],
                [
                    "kind": "create",
                    "uri": "file:///new.swift",
                ] as [String: Any],
                [
                    "kind": "rename",
                    "oldUri": "file:///old.swift",
                    "newUri": "file:///renamed.swift",
                ] as [String: Any],
                [
                    "kind": "delete",
                    "uri": "file:///gone.swift",
                ] as [String: Any],
            ],
            "changeAnnotations": [
                "ann1": [
                    "label": "Rename",
                    "needsConfirmation": true,
                ]
            ],
        ]
        // Seed open text for range conversion.
        try await session.didOpen(
            uri: DocumentURI(rawValue: "file:///a.swift"),
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "AB"
        )
        try await session.didOpen(
            uri: DocumentURI(rawValue: "file:///b.swift"),
            languageID: "swift",
            version: DocumentVersion(rawValue: 3),
            text: ""
        )
        let plan = try await session.decodeWorkspaceEdit(edit)
        #expect(plan.documentEdits.count >= 1)
        #expect(plan.versionedDocumentEdits.contains { $0.uri.rawValue == "file:///b.swift" && $0.version == 3 })
        #expect(plan.resourceOperations.contains { if case .create = $0 { return true }; return false })
        #expect(plan.resourceOperations.contains { if case .rename = $0 { return true }; return false })
        #expect(plan.resourceOperations.contains { if case .delete = $0 { return true }; return false })
        #expect(plan.changeAnnotations["ann1"]?.needsConfirmation == true)
        let workspaceEdit = try await session.workspaceEdit(from: plan)
        #expect(!workspaceEdit.documentChanges.isEmpty || !workspaceEdit.fileOperations.isEmpty)
        await session.shutdown()
    }
}

// MARK: - LSP-N09

@Suite("LSP-N09 snapshot fail-closed")
struct LSPN09SnapshotTests {
    @Test func test_LSP_N09_missingSnapshotThrowsNotEmptyText() async throws {
        let resolver = DefaultWorkspaceSnapshotResolver(openDocumentText: { _ in nil })
        let missing = DocumentURI(rawValue: "inmemory:does-not-exist")
        var threw = false
        do {
            _ = try await resolver.snapshot(for: missing)
            Issue.record("expected unavailable")
        } catch let error as LSPError {
            threw = true
            if case .snapshotUnavailable = error {
                // ok
            } else if case .decode = error {
                // also accept typed decode/unavailable
            } else {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(threw)

        let (session, _, _, _) = try await makeMockSession(id: "n09")
        do {
            _ = try await session.requireText(for: DocumentURI(rawValue: "file:///nope-missing.swift"))
            Issue.record("expected throw")
        } catch {
            // fail closed
        }
        // Soft empty text helper must not exist on production session (LSP-N09 P0).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolverSource = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorLSP/WorkspaceSnapshotResolver.swift"),
            encoding: .utf8
        )
        #expect(!resolverSource.contains("empty text so line/character"))
        #expect(resolverSource.contains("snapshotUnavailable") || resolverSource.contains("throw"))
        let sessionSource = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorLSP/LanguageServerSession.swift"),
            encoding: .utf8
        )
        // Fail closed: no soft empty-string helper that masks snapshot miss.
        #expect(!sessionSource.contains("func text(for"))
        #expect(!sessionSource.contains("(try? await requireText"))
        #expect(!sessionSource.contains("prefer ``requireText"))
        #expect(!sessionSource.contains("Soft helper for display-only"))
        #expect(sessionSource.contains("func requireText(for"))
        #expect(sessionSource.contains("never fabricates empty text") || sessionSource.contains("snapshotUnavailable"))
        await session.shutdown()
    }

    /// Navigation adapters must fail closed when the target URI has no snapshot.
    /// Soft `text(for:) → ""` would invent incorrect cross-file ranges (LSP-N09 P0).
    @Test func test_LSP_N09_navigationMissingTargetThrowsNotEmptyRange() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n09nav")
        let missingURI = "file:///definitely-missing-target.swift"
        await mock.setNavigationTargetURIOverride(missingURI)

        let openURI = DocumentURI(rawValue: "file:///n09nav-source.swift")
        try await session.didOpen(
            uri: openURI,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "func source() {}"
        )
        let doc = DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "func source() {}")
        let ctx = LanguageServiceContext(languageID: "swift", uri: openURI)
        let pos = PositionRequest(
            document: doc,
            position: TextPosition(utf16Offset: 5),
            context: ctx
        )

        let definition = LSPDefinitionAdapter(
            session: session,
            id: "n09-def",
            selector: DocumentSelector.languages("swift"),
            priority: 0
        )
        var defThrew = false
        do {
            let links = try await definition.definitions(for: pos)
            // Must not soft-succeed with empty-text ranges at (0,0) for a missing file.
            Issue.record("definition should throw for missing target; got \(links)")
        } catch let error as LSPError {
            defThrew = true
            if case .snapshotUnavailable = error {
                // expected fail-closed
            } else {
                // Other typed errors still fail closed (no empty-range success).
            }
        } catch {
            defThrew = true
        }
        #expect(defThrew)

        let declaration = LSPDeclarationAdapter(
            session: session,
            id: "n09-decl",
            selector: DocumentSelector.languages("swift"),
            priority: 0
        )
        var declThrew = false
        do {
            _ = try await declaration.declarations(for: pos)
            Issue.record("declaration should throw for missing target")
        } catch {
            declThrew = true
        }
        #expect(declThrew)

        let implementation = LSPImplementationAdapter(
            session: session,
            id: "n09-impl",
            selector: DocumentSelector.languages("swift"),
            priority: 0
        )
        var implThrew = false
        do {
            _ = try await implementation.implementations(for: pos)
            Issue.record("implementation should throw for missing target")
        } catch {
            implThrew = true
        }
        #expect(implThrew)

        let references = LSPReferencesAdapter(
            session: session,
            id: "n09-ref",
            selector: DocumentSelector.languages("swift"),
            priority: 0
        )
        var refThrew = false
        do {
            _ = try await references.references(for: pos, includeDeclaration: true)
            Issue.record("references should throw for missing target")
        } catch {
            refThrew = true
        }
        #expect(refThrew)

        let ws = LSPWorkspaceSymbolAdapter(
            session: session,
            id: "n09-ws",
            selector: DocumentSelector.languages("swift"),
            priority: 0,
            labelHook: nil
        )
        var wsThrew = false
        do {
            _ = try await ws.workspaceSymbols(query: "x", context: ctx)
            Issue.record("workspaceSymbols should throw for missing target")
        } catch {
            wsThrew = true
        }
        #expect(wsThrew)

        // Production navigation must not call soft empty-text helper.
        let adapterSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorLSP/Adapters/LSPLanguageServiceProviders.swift")
        let adapterSource = try String(contentsOf: adapterSourceURL, encoding: .utf8)
        #expect(!adapterSource.contains("session.text(for:"))
        #expect(adapterSource.contains("requireText(for:"))

        await session.shutdown()
    }
}

// MARK: - LSP-N10

@Suite("LSP-N10 dynamic registration")
struct LSPN10RegistrationTests {
    @Test func test_LSP_N10_unregisterExactRegistrationIDNotMethodCount() async throws {
        let (session, _, _, _) = try await makeMockSession(id: "n10")
        // Simulate two registrations for same method with different IDs.
        try await session.applyDynamicRegistrations([
            ["id": "reg-1", "method": "textDocument/onTypeFormatting", "registerOptions": ["x": 1]],
            ["id": "reg-2", "method": "textDocument/onTypeFormatting", "registerOptions": ["x": 2]],
        ])
        #expect(await session.isDynamicallyEnabled("textDocument/onTypeFormatting"))
        #expect(await session.dynamicRegistrationIDs().count == 2)
        let rec = await session.dynamicRegistration(id: "reg-1")
        #expect(rec?.method == "textDocument/onTypeFormatting")
        #expect(rec?.registerOptions != nil)

        try await session.applyDynamicUnregistrations([["id": "reg-1"]])
        #expect(await session.dynamicRegistration(id: "reg-1") == nil)
        #expect(await session.dynamicRegistration(id: "reg-2") != nil)
        // Method still enabled via reg-2.
        #expect(await session.isDynamicallyEnabled("textDocument/onTypeFormatting"))
        try await session.applyDynamicUnregistrations([["id": "reg-2"]])
        #expect(await session.isDynamicallyEnabled("textDocument/onTypeFormatting") == false)
        await session.shutdown()
    }
}

// MARK: - LSP-N11

@Suite("LSP-N11 JSONValue")
struct LSPN11JSONValueTests {
    @Test func test_LSP_N11_jsonValuePreservesScalarsArraysObjectsNull() throws {
        let samples: [(Any, JSONValue)] = [
            (NSNull(), .null),
            (true, .bool(true)),
            (false, .bool(false)),
            (42, .number(42)),
            ("hi", .string("hi")),
            ([1, "a"] as [Any], .array([.number(1), .string("a")])),
            (["k": 1] as [String: Any], .object(["k": .number(1)])),
        ]
        for (raw, expected) in samples {
            let value = try JSONValue(jsonObject: raw)
            #expect(value == expected)
        }
        // Round-trip through LSPAnyJSON / request path model.
        let null = JSONValue.null
        #expect(null.isNull)
        let arr = JSONValue.array([.bool(true), .null, .string("x")])
        #expect(arr.arrayValue?.count == 3)
        let data = try JSONSerialization.data(withJSONObject: arr.jsonObject as Any, options: [.fragmentsAllowed])
        let back = try JSONValue(data: data)
        #expect(back == arr)
    }
}

// MARK: - LSP-N12

@Suite("LSP-N12 versioned diagnostics")
struct LSPN12DiagnosticsTests {
    @Test func test_LSP_N12_diagnosticsCarryVersionGenerationSequenceAndBound() async throws {
        let store = LSPDiagnosticStore()
        let uri = DocumentURI(rawValue: "file:///diag.swift")
        await store.publish(
            serverID: "s1",
            serverGeneration: 1,
            uri: uri,
            version: 2,
            items: [LSPStoredDiagnostic(message: "e", line: 0, character: 0)]
        )
        let pub = await store.latestPublication(serverID: "s1", uri: uri)
        #expect(pub?.documentVersion == 2)
        #expect(pub?.serverGeneration == 1)
        #expect(pub?.sequence ?? 0 >= 1)
        #expect(pub?.source == "s1" || pub?.serverID == "s1")
        let firstSequence = pub!.sequence

        // Stale version discarded.
        await store.publish(
            serverID: "s1",
            serverGeneration: 1,
            uri: uri,
            version: 1,
            items: [LSPStoredDiagnostic(message: "stale", line: 0, character: 0)]
        )
        #expect(await store.diagnostics(serverID: "s1", uri: uri).first?.message == "e")

        // Generation change clears stale.
        await store.bumpServerGeneration("s1")
        await store.publish(
            serverID: "s1",
            serverGeneration: 2,
            uri: uri,
            version: 1,
            items: [LSPStoredDiagnostic(message: "newgen", line: 1, character: 0)]
        )
        #expect(await store.diagnostics(serverID: "s1", uri: uri).first?.message == "newgen")

        // Bounded stream via hub — subscribe first, then publish; hard-require stream delivery
        // (must not soft-OR on latestPublication alone; LSP-N12).
        let stream = await store.events()
        await store.publish(
            serverID: "s1",
            serverGeneration: 2,
            uri: uri,
            version: 3,
            items: [LSPStoredDiagnostic(message: "streamed", line: 0, character: 0)]
        )
        var sawVersion3FromStream = false
        var streamHubSequence: UInt64 = 0
        var streamMessage: String?
        var streamPubSequence: UInt64 = 0
        let deadline = ContinuousClock.now + .seconds(2)
        for await item in stream {
            if case .value(let env) = item {
                if env.event.documentVersion == 3,
                    env.event.items.first?.message == "streamed"
                {
                    sawVersion3FromStream = true
                    streamHubSequence = env.sequence
                    streamPubSequence = env.event.sequence
                    streamMessage = env.event.items.first?.message
                    break
                }
            }
            if ContinuousClock.now >= deadline { break }
        }
        #expect(
            sawVersion3FromStream,
            "diagnostics stream must deliver version=3 publication (not latestPublication soft-OR)"
        )
        #expect(streamMessage == "streamed")
        #expect(streamHubSequence >= 1)
        #expect(streamPubSequence >= 1)
        let latest = await store.latestPublication(serverID: "s1", uri: uri)
        #expect(latest?.documentVersion == 3)
        #expect(latest?.sequence ?? 0 > firstSequence)
        #expect(latest?.sequence == streamPubSequence)
        #expect(latest?.items.first?.message == "streamed")
    }
}

// MARK: - LSP-N13

@Suite("LSP-N13 real LSP gate")
struct LSPN13RealLSPGateTests {
    @Test func test_LSP_N13_checkRealLspIsIntegrationFixtureNotProbeOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/check-real-lsp.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("sourcekit-lsp"))
        #expect(text.contains("clangd"))
        #expect(text.contains("textDocument/hover") || text.contains("hover"))
        #expect(text.contains("textDocument/definition") || text.contains("definition"))
        #expect(text.contains("textDocument/documentSymbol") || text.contains("documentSymbol"))
        #expect(text.contains("publishDiagnostics") || text.contains("diagnostics"))
        #expect(text.contains("shutdown"))
        #expect(text.contains("REQUIRE_REAL_LSP"))
        // Must assert clean teardown / no soft-only success without session steps.
        #expect(text.contains("didOpen") || text.contains("textDocument/didOpen"))
        #expect(text.contains("didChange") || text.contains("textDocument/didChange"))
        #expect(text.contains("completion"))
        // Fixture package layout for Swift.
        #expect(text.contains("Package.swift") || text.contains("mktemp"))
        // Full session steps must be present (not a --version probe).
        #expect(text.contains("initialize"))
        #expect(text.contains("rpc_session") || text.contains("full session"))
    }

    @Test func test_LSP_N13_fixtureFilesPresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let swiftFixture = root.appendingPathComponent("Tests/Fixtures/LSP/swift-package")
        let cFixture = root.appendingPathComponent("Tests/Fixtures/LSP/clangd-project")
        #expect(FileManager.default.fileExists(atPath: swiftFixture.path))
        #expect(FileManager.default.fileExists(atPath: cFixture.path))
        #expect(FileManager.default.fileExists(atPath: swiftFixture.appendingPathComponent("Package.swift").path))
        #expect(FileManager.default.fileExists(atPath: cFixture.appendingPathComponent("main.c").path))
        let mainSwift = swiftFixture.appendingPathComponent("Sources/App/main.swift")
        #expect(FileManager.default.fileExists(atPath: mainSwift.path))
        let mainText = try String(contentsOf: mainSwift, encoding: .utf8)
        #expect(!mainText.isEmpty)
    }

    /// Executes the real integration gate (not string-scan only). When sourcekit-lsp/clangd
    /// are installed the script runs a full initialize→open→change→features→shutdown session;
    /// when absent and REQUIRE_REAL_LSP≠1 it still validates fixtures and exits 0.
    @Test func test_LSP_N13_executesIntegrationSessionScript() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/check-real-lsp.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path)
            || FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        // Do not force REQUIRE_REAL_LSP here — CI hard-gates separately; this proves the
        // script path executes (session when tools present, fixture gate otherwise).
        env["REQUIRE_REAL_LSP"] = env["REQUIRE_REAL_LSP"] ?? "0"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = stdout + stderr
        #expect(
            process.terminationStatus == 0,
            "check-real-lsp.sh failed status=\(process.terminationStatus) out=\(combined)"
        )
        // Hard gate (LSP-N13): success must be a real full session line, not merely the
        // binary name ("found sourcekit-lsp") or a generic "OK:" prefix.
        let hasFullSession =
            combined.contains("full session")
            && (
                combined.contains("initialize/open/change")
                    || combined.contains("completion/hover/definition")
            )
        let hasSoftNoBinaries =
            combined.contains("no real LSP binaries")
            && combined.contains("fixtures present")
        #expect(
            hasFullSession || hasSoftNoBinaries,
            "expected 'full session' success or soft no-binaries fixture OK; got: \(combined)"
        )
        // Binary-name-only "OK: found sourcekit-lsp" is not a session proof.
        if combined.contains("found sourcekit-lsp") || combined.contains("found clangd") {
            #expect(
                hasFullSession,
                "binary present but full session line missing: \(combined)"
            )
        }
    }

    /// In-process mock walks the same integration session steps the gate requires
    /// (initialize already done by makeMockSession; open→change→features→shutdown).
    @Test func test_LSP_N13_inProcessIntegrationSessionSteps() async throws {
        let (session, mock, _, _) = try await makeMockSession(id: "n13session")
        let uri = DocumentURI(rawValue: "file:///n13/main.swift")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "func hello() {}\n"
        )
        try await session.synchronize(
            document: DocumentID(),
            uri: uri,
            from: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "func hello() {}\n"),
            applying: AppliedEditTransaction(
                transaction: .single(range: NSRange(location: 14, length: 0), replacement: "// touch\n"),
                oldVersion: DocumentVersion(rawValue: 1),
                newVersion: DocumentVersion(rawValue: 2),
                beforeState: DocumentContentStateID(),
                afterState: DocumentContentStateID(),
                inverse: .single(range: NSRange(location: 14, length: 8), replacement: ""),
                textEdits: []
            ),
            to: DocumentSnapshot(
                version: DocumentVersion(rawValue: 2),
                text: "func hello() {}\n// touch\n"
            )
        )
        try await waitUntil { await mock.changeCount >= 1 }

        let registry = LanguageServiceRegistry()
        let registration = await LSPClientProviders.register(session: session, into: registry)
        let host = LanguageServiceHost(registry: registry)
        let doc = DocumentSnapshot(
            version: DocumentVersion(rawValue: 2),
            text: "func hello() {}\n// touch\n"
        )
        let ctx = LanguageServiceContext(languageID: "swift", uri: uri)
        let pos = PositionRequest(document: doc, position: TextPosition(utf16Offset: 5), context: ctx)
        let full = DocumentRequest(document: doc, context: ctx)
        let v: @Sendable () -> DocumentVersion = { DocumentVersion(rawValue: 2) }

        #expect(!(try await host.completions(
            for: CompletionRequest(document: doc, position: TextPosition(utf16Offset: 5), context: ctx),
            currentVersion: v
        )).items.isEmpty)
        #expect(try await host.hover(for: pos, currentVersion: v) != nil)
        #expect(!(try await host.definitions(for: pos, currentVersion: v)).isEmpty)
        #expect(!(try await host.documentSymbols(for: full, currentVersion: v)).isEmpty)

        // Diagnostics may arrive via publish; store should accept versioned publish.
        await session.shutdown()
        registration.dispose()
        #expect(await mock.openCount >= 1)
        #expect(await mock.changeCount >= 1)
        let methods = await mock.receivedMethods
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/didChange"))
        #expect(methods.contains("textDocument/completion") || methods.contains("textDocument/hover"))
    }
}
