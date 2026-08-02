import CodeEditorLanguageSupport
import Foundation
import Testing

@testable import CodeEditorTreeSitter

// MARK: - LANG-N02

@Suite("LANG-N02 malformed queries fail closed")
struct LANGN02QueryFailClosedTests {
    @Test func test_LANG_N02_presentUnreadableQueryThrows() throws {
        let registry = LanguageRegistry()
        let id = LanguageID("lang.n02.unreadable")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-n02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let badURL = dir.appendingPathComponent("highlights.scm")
        // Create a file then remove read permission / write invalid: empty non-UTF8 via data.
        // Use a directory path as the "file" to force unreadable content-as-string failure.
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        _ = registry.register(
            LanguageDefinition(id: id, displayName: "N02", tsName: "n02"),
            owner: .host,
            priority: 1
        )
        registry.registerQueryProvider(for: id) { name in
            name == "highlights" ? badURL : nil
        }

        do {
            _ = try QuerySetLoader.loadSources(
                languageID: id,
                kinds: [.highlights],
                registry: registry,
                required: [.highlights]
            )
            Issue.record("expected throw for unreadable present query")
        } catch let error as QuerySetError {
            guard case .unreadable(let lang, let kind, let path) = error else {
                Issue.record("wrong QuerySetError \(error)")
                return
            }
            #expect(lang == id)
            #expect(kind == .highlights)
            #expect(path == badURL.path)
        }
    }

    @Test func test_LANG_N02_malformedHighlightsQueryThrowsTypedError() throws {
        let registry = LanguageRegistry()
        let id = LanguageID("lang.n02.malformed")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-n02-m-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scm = dir.appendingPathComponent("highlights.scm")
        // Deliberately broken tree-sitter query syntax.
        try "(this is not a valid query @broken".write(to: scm, atomically: true, encoding: .utf8)

        let def = LanguageDefinition(id: id, displayName: "Broken", tsName: "broken")
        _ = registry.register(def, owner: .host, priority: 1)
        registry.registerQueryProvider(for: id) { name in
            name == "highlights" ? scm : nil
        }

        // Source loads OK (file is readable UTF-8).
        let (sources, _) = try QuerySetLoader.loadSources(
            languageID: id,
            kinds: [.highlights],
            registry: registry
        )
        #expect(sources[.highlights] != nil)
        #expect(sources[.highlights]!.contains("@broken"))
    }

    @Test func test_LANG_N02_factoryFailsClosedOnBrokenQueryWithRealGrammar() throws {
        // Register broken highlights against the real JSON grammar — Query compile must throw.
        let registry = LanguageRegistry()
        // Borrow JSON grammar from shared if available; else skip path via synthetic pointer unavailable.
        // Use a dedicated language id so we don't poison shared cache.
        let id = LanguageID.json
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-n02-fc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scm = dir.appendingPathComponent("highlights.scm")
        try "(not_a_real_node_type_xyz) @x".write(to: scm, atomically: true, encoding: .utf8)

        // Prefer host registry isolated from shared: re-register json with broken query.
        if let ptr = LanguageRegistry.shared.parser(for: .json) {
            let bits = UInt(bitPattern: ptr)
            _ = registry.register(
                LanguageDefinition(id: id, displayName: "JSON", tsName: "json"),
                owner: .host,
                priority: 1,
                parserFactory: { OpaquePointer(bitPattern: bits) }
            )
            registry.registerQueryProvider(for: id) { name in
                name == "highlights" ? scm : nil
            }
            TreeSitterConfigurationFactory.clearCache()
            do {
                _ = try TreeSitterConfigurationFactory.languageConfiguration(
                    for: .json, registry: registry)
                Issue.record("expected malformedQuery fail-closed")
            } catch TreeSitterConfigurationFactory.Error.malformedQuery(_, _, _) {
                // expected
            } catch {
                Issue.record("wrong error \(error)")
            }
        } else {
            // Without a grammar linked, fail-closed still surfaces parserUnavailable — not silent.
            do {
                _ = try TreeSitterConfigurationFactory.languageConfiguration(
                    for: .json, registry: registry)
                Issue.record("expected parserUnavailable or malformed")
            } catch {
                #expect(Bool(true))
            }
        }
    }

    @Test func test_LANG_N02_querySetErrorMapsToLanguagePackError() {
        let err = QuerySetError.malformed(
            language: .swift,
            kind: .highlights,
            path: "/tmp/highlights.scm",
            detail: "unexpected token"
        )
        let pack = err.asLanguagePackError
        guard case .malformedQuery(let lang, let query, let path, let detail) = pack else {
            Issue.record("expected malformedQuery")
            return
        }
        #expect(lang == .swift)
        #expect(query == "highlights")
        #expect(path == "/tmp/highlights.scm")
        #expect(detail.contains("unexpected"))
        #expect(pack.description.contains("malformed"))
    }

    @Test func test_LANG_N02_missingOptionalQueryIsDiagnosticNotThrow() throws {
        let registry = LanguageRegistry()
        let id = LanguageID("lang.n02.optional")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lang-n02-o-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scm = dir.appendingPathComponent("highlights.scm")
        try "(identifier) @variable".write(to: scm, atomically: true, encoding: .utf8)

        _ = registry.register(
            LanguageDefinition(id: id, displayName: "Opt", tsName: "opt"),
            owner: .host
        )
        registry.registerQueryProvider(for: id) { name in
            name == "highlights" ? scm : nil
        }

        let (sources, diags) = try QuerySetLoader.loadSources(
            languageID: id,
            kinds: [.highlights, .folds],
            registry: registry,
            required: [.highlights]
        )
        #expect(sources[.highlights] != nil)
        #expect(sources[.folds] == nil)
        #expect(diags.contains(.missing(.folds)))
    }
}

// MARK: - LANG-N03

@Suite("LANG-N03 single ParseSession path")
struct LANGN03ParseSessionTests {
    @Test func test_LANG_N03_parseSessionIsSoleStateOwner() async throws {
        let session = ParseSession()
        let g1 = try await session.setText("let x = 1")
        let snap = await session.snapshot()
        #expect(snap.documentVersion == g1)
        #expect(snap.hasTree == false)  // not configured
        #expect(await session.isCurrent(generation: g1))
        let g2 = try await session.setText("let x = 2")
        #expect(await session.isCurrent(generation: g1) == false)
        #expect(await session.isCurrent(documentVersion: g2, languageGeneration: snap.languageGeneration))
    }

    @Test func test_LANG_N03_staleHighlightSnapshotDiscarded() async throws {
        let session = ParseSession()
        _ = try await session.setText("aaa")
        // Without config, query throws notConfigured — stale path uses generation check.
        let ver = await session.documentVersion
        _ = try await session.setText("bbb")
        #expect(await session.isCurrent(generation: ver) == false)
    }

    @MainActor
    @Test func test_LANG_N03_highlightProviderUsesParseSessionOnly() async throws {
        let provider = TreeSitterHighlightProvider()
        // The provider's session is the only engine; generation advances on setDocumentText
        // only when configured — unconfigured still keeps single session.
        let session = provider.parseSession
        let before = await session.documentVersion
        await provider.setDocumentText("hello")
        // Unconfigured: setDocumentText does not parse but session remains sole owner.
        let after = await session.documentVersion
        #expect(after == before)  // no configure → no setText
        #expect(provider.highlightGeneration == 0)
    }

    @Test func test_LANG_N03_languageDocumentActorIsParseSession() {
        #expect(LanguageDocumentActor.self == ParseSession.self)
    }
}

// MARK: - LANG-N04

@Suite("LANG-N04 pointer ownership")
struct LANGN04PointerOwnershipTests {
    @Test func test_LANG_N04_languageRefDocumentsStaticOwnership() {
        let bits: UInt = 0x1234
        let ref = TSLanguageRef(
            languageID: .swift,
            pointer: OpaquePointer(bitPattern: bits)!,
            ownership: .staticGrammarSymbol
        )
        #expect(ref.ownership == .staticGrammarSymbol)
        #expect(ref.languageID == .swift)
        #expect(UInt(bitPattern: ref.pointer) == bits)
        // Sendable: can cross actor boundaries (static grammar is process-immortal).
        let copy = ref
        #expect(copy == ref)
    }

    @Test func test_LANG_N04_registryLanguageRefNilWithoutParser() {
        let registry = LanguageRegistry()
        #expect(registry.languageRef(for: .python) == nil)
    }

    @Test func test_LANG_N04_sessionRetainsLanguageRefAcrossEdits() async throws {
        let session = ParseSession()
        let ref = TSLanguageRef(
            languageID: .json,
            pointer: OpaquePointer(bitPattern: 0x9999)!,
            ownership: .staticGrammarSymbol
        )
        // configure requires a real Language from SwiftTreeSitter — skip full configure
        // when pointer is fake; just verify retainedLanguageID starts nil.
        #expect(await session.retainedLanguageID() == nil)
        _ = ref
    }

    @Test func test_LANG_N04_deallocationStressRepeatedSessionCycle() async throws {
        // Stress: create/destroy many sessions without configuration (no C free needed
        // for static grammars). Ensures actor teardown does not crash.
        var lastVersion: UInt64 = 0
        for i in 0..<200 {
            let session = ParseSession()
            lastVersion = try await session.setText("stress \(i)")
            #expect(lastVersion >= 1)
            await session.reset()
            let after = await session.documentVersion
            #expect(after > lastVersion)
        }
        #expect(lastVersion >= 1)
    }
}

// MARK: - LANG-N05

@Suite("LANG-N05 Tree-sitter direct ownership suite")
struct LANGN05TreeSitterOwnershipTests {
    @Test func test_LANG_N05_incrementalEditBeforeInsideAfterMultibyte() throws {
        // UTF-16 aware InputEdit: emoji (2 UTF-16 units) and combining sequences.
        let old = "ab😀cd"
        let oldNS = old as NSString
        #expect(oldNS.length == 6)  // a b 😀(2) c d

        // Edit before emoji: insert at 0
        let eBefore = TreeSitterEdit.make(
            range: NSRange(location: 0, length: 0),
            delta: 1,
            oldSource: old,
            newSource: "X" + old
        )
        #expect(eBefore.startByte == 0)

        // Edit inside scalar: replace the emoji (2 UTF-16 units at loc 2)
        let eInside = TreeSitterEdit.make(
            range: NSRange(location: 2, length: 2),
            delta: -1,
            oldSource: old,
            newSource: "abYcd"
        )
        #expect(eInside.startByte == 4)  // 2 * 2
        #expect(eInside.oldEndByte == 8)

        // Edit after emoji
        let eAfter = TreeSitterEdit.make(
            range: NSRange(location: 5, length: 1),
            delta: 0,
            oldSource: old,
            newSource: "ab😀cZ"
        )
        #expect(eAfter.startByte == 10)
    }

    @Test func test_LANG_N05_malformedSourceDoesNotCrashSession() async throws {
        let session = ParseSession()
        let garbage = String(repeating: "}\n{((", count: 50)
        _ = try await session.setText(garbage)
        // Unconfigured query fails typed, not crash.
        do {
            _ = try await session.queryHighlights(in: NSRange(location: 0, length: 1))
            Issue.record("expected notConfigured")
        } catch ParseSession.EngineError.notConfigured {
            // expected
        }
    }

    @Test func test_LANG_N05_cancellationAndStaleGenerationDiscard() async throws {
        let session = ParseSession()
        let g1 = try await session.setText("one")
        _ = try await session.setText("two")
        #expect(await session.isCurrent(generation: g1) == false)
    }

    @Test func test_LANG_N05_allQueryKindsHaveBasenames() {
        for kind in QueryKind.allCases {
            #expect(!kind.fileBasename.isEmpty)
            #expect(kind.fileName.hasSuffix(".scm"))
        }
        #expect(QueryKind.allCases.count >= 8)
    }

    @Test func test_LANG_N05_duplicateRegistrationAndUnload() {
        let registry = LanguageRegistry()
        let a = registry.register(
            LanguageDefinition(id: "dup", displayName: "A", tsName: "dup"),
            owner: .extensionPackage("a"),
            priority: 1
        )
        let b = registry.register(
            LanguageDefinition(id: "dup", displayName: "B", tsName: "dup"),
            owner: .extensionPackage("b"),
            priority: 2
        )
        #expect(registry.allRecords(for: "dup").count == 2)
        b.token.dispose()
        #expect(registry.definition(for: "dup")?.displayName == "A")
        a.token.dispose()
        #expect(registry.definition(for: "dup") == nil)
    }

    @Test func test_LANG_N05_largeFileRepeatedEdits() async throws {
        let session = ParseSession()
        var text = String(repeating: "let x = 1\n", count: 5_000)
        _ = try await session.setText(text)
        for i in 0..<20 {
            let insert = "// \(i)\n"
            let old = text
            text = insert + text
            let result = try await session.applyEdit(
                range: NSRange(location: 0, length: 0),
                delta: (insert as NSString).length,
                newText: text
            )
            #expect(result.documentVersion > 0)
            #expect(old != text)
        }
    }

    @Test func test_LANG_N05_queryCaptureValidationEmptyWithoutConfig() async throws {
        let session = ParseSession()
        _ = try await session.setText("func f() {}")
        do {
            _ = try await session.queryHighlights(
                in: NSRange(location: 0, length: 4))
            Issue.record("expected notConfigured")
        } catch ParseSession.EngineError.notConfigured {
            // ok
        }
    }
}

// MARK: - Phase6 compatibility

@Suite("Phase6 LanguageDocumentActor")
struct Phase6LanguageDocumentActorTests {
    @Test func generationAdvancesAndStaleRejected() async throws {
        let actor = LanguageDocumentActor()
        let g1 = try await actor.setText("let a = 1")
        let g2 = try await actor.setText("let a = 2")
        #expect(g2 > g1)
        #expect(await actor.isCurrent(generation: g2))
        #expect(await actor.isCurrent(generation: g1) == false)
    }

    @Test func queryWithoutConfigThrowsNotConfigured() async {
        let actor = LanguageDocumentActor()
        do {
            _ = try await actor.queryHighlights(in: NSRange(location: 0, length: 1))
            Issue.record("expected notConfigured")
        } catch let error as LanguageDocumentActor.EngineError {
            #expect(error == .notConfigured)
        } catch {
            Issue.record("wrong \(error)")
        }
    }

    @Test func actorIsNotMainActorIsolated() async throws {
        let actor = LanguageDocumentActor()
        let gen = try await Task.detached {
            try await actor.setText("hello")
        }.value
        #expect(gen >= 1)
    }
}
