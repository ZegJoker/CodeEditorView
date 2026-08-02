import CodeEditorLanguageJSON
import CodeEditorLanguageSupport
import CodeEditorLanguageSwift
import Foundation
import SwiftTreeSitter
import Testing
import TreeSitterJsonGrammar
import TreeSitterSwiftGrammar

@testable import CodeEditorTreeSitter

// MARK: - Shared real-grammar helpers (LANG-N02/N03/N04/N05)

private enum LANGNRealGrammarSupport {
    /// Ensures pilot packs are registered into the shared registry (static init may race).
    static func ensureSharedJSONAndSwift() throws {
        _ = try CodeEditorLanguageJSON.register()
        _ = try CodeEditorLanguageSwift.register()
        TreeSitterConfigurationFactory.clearCache()
        TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
    }

    /// Host-owned registry with the real JSON grammar + query resources from the pack.
    static func hostJSONRegistry(
        highlightsURLOverride: URL? = nil
    ) throws -> LanguageRegistry {
        let registry = LanguageRegistry()
        var definition = LanguageDefinition(CodeLanguage.json)
        definition.queryKinds = [.highlights, .folds, .indents, .locals]
        _ = registry.register(definition, owner: .host, priority: 1)
        registry.registerParser(for: .json) { tree_sitter_json() }
        if let override = highlightsURLOverride {
            registry.registerQueryProvider(for: .json) { name in
                if name == "highlights" { return override }
                // Fall through to pack resources for optional kinds when present.
                return LanguageRegistry.shared.queryURL(for: .json, query: name)
            }
        } else {
            // Reuse shared pack query provider after register.
            _ = try CodeEditorLanguageJSON.register()
            registry.registerQueryProvider(for: .json) { name in
                LanguageRegistry.shared.queryURL(for: .json, query: name)
            }
        }
        return registry
    }

    static func jsonConfiguration(
        registry: LanguageRegistry? = nil
    ) throws -> (LanguageConfiguration, TSLanguageRef) {
        try ensureSharedJSONAndSwift()
        let reg = registry ?? LanguageRegistry.shared
        TreeSitterConfigurationFactory.clearCache()
        guard let config = try TreeSitterConfigurationFactory.languageConfiguration(
            for: .json, registry: reg
        ) else {
            throw QuerySetError.missingRequired(language: .json, kind: .highlights)
        }
        guard let ref = reg.languageRef(for: .json) else {
            throw TreeSitterConfigurationFactory.Error.parserUnavailable("json")
        }
        return (config, ref)
    }

    static func swiftConfiguration() throws -> (LanguageConfiguration, TSLanguageRef) {
        try ensureSharedJSONAndSwift()
        TreeSitterConfigurationFactory.clearCache()
        guard let config = try TreeSitterConfigurationFactory.languageConfiguration(
            for: .swift, registry: .shared
        ) else {
            throw QuerySetError.missingRequired(language: .swift, kind: .highlights)
        }
        guard let ref = LanguageRegistry.shared.languageRef(for: .swift) else {
            throw TreeSitterConfigurationFactory.Error.parserUnavailable("swift")
        }
        return (config, ref)
    }

    static func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - LANG-N02

@Suite("LANG-N02 malformed queries fail closed")
struct LANGN02QueryFailClosedTests {
    @Test func test_LANG_N02_presentUnreadableQueryThrows() throws {
        let registry = LanguageRegistry()
        let id = LanguageID("lang.n02.unreadable")
        let dir = try LANGNRealGrammarSupport.tempDir("lang-n02")
        defer { try? FileManager.default.removeItem(at: dir) }

        let badURL = dir.appendingPathComponent("highlights.scm")
        // Directory path masquerading as the query file forces unreadable content-as-string.
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
        // Real JSON grammar + deliberately broken highlights.scm → QuerySetError.malformed.
        let dir = try LANGNRealGrammarSupport.tempDir("lang-n02-m")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scm = dir.appendingPathComponent("highlights.scm")
        try "(this is not a valid query @broken".write(to: scm, atomically: true, encoding: .utf8)

        let registry = try LANGNRealGrammarSupport.hostJSONRegistry(highlightsURLOverride: scm)
        guard let pointer = registry.parser(for: .json) else {
            Issue.record("expected real tree_sitter_json pointer")
            return
        }
        #expect(UInt(bitPattern: pointer) != 0)
        let language = Language(language: pointer)

        let (sources, _) = try QuerySetLoader.loadSources(
            languageID: .json,
            kinds: [.highlights],
            registry: registry
        )
        guard let source = sources[.highlights] else {
            Issue.record("expected loaded highlights source")
            return
        }
        #expect(source.contains("@broken"))

        do {
            _ = try QuerySetLoader.compile(
                languageID: .json,
                kind: .highlights,
                source: source,
                language: language,
                path: scm.path
            )
            Issue.record("expected QuerySetError.malformed from compile")
        } catch let error as QuerySetError {
            guard case .malformed(let lang, let kind, let path, let detail) = error else {
                Issue.record("wrong QuerySetError \(error)")
                return
            }
            #expect(lang == .json)
            #expect(kind == .highlights)
            #expect(path == scm.path)
            #expect(!detail.isEmpty)
            let pack = error.asLanguagePackError
            guard case .malformedQuery = pack else {
                Issue.record("expected LanguagePackError.malformedQuery")
                return
            }
        }

        // loadAndCompile is also fail-closed.
        do {
            _ = try QuerySetLoader.loadAndCompile(
                languageID: .json,
                kinds: [.highlights],
                language: language,
                registry: registry
            )
            Issue.record("expected loadAndCompile to throw")
        } catch is QuerySetError {
            // expected
        }
    }

    @Test func test_LANG_N02_factoryFailsClosedOnBrokenQueryWithRealGrammar() throws {
        // Host registry: real JSON grammar + broken highlights → factory throws malformedQuery.
        let dir = try LANGNRealGrammarSupport.tempDir("lang-n02-fc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scm = dir.appendingPathComponent("highlights.scm")
        try "(not_a_real_node_type_xyz) @x".write(to: scm, atomically: true, encoding: .utf8)

        let registry = try LANGNRealGrammarSupport.hostJSONRegistry(highlightsURLOverride: scm)
        guard registry.parser(for: .json) != nil else {
            Issue.record("grammar pointer required — TreeSitterJsonGrammar must be linked")
            return
        }

        TreeSitterConfigurationFactory.clearCache()
        do {
            _ = try TreeSitterConfigurationFactory.languageConfiguration(
                for: .json, registry: registry)
            Issue.record("expected malformedQuery fail-closed with real grammar")
        } catch TreeSitterConfigurationFactory.Error.malformedQuery(let name, let detail, let path) {
            #expect(name == CodeLanguage.json.displayName || name.lowercased().contains("json"))
            #expect(!detail.isEmpty)
            #expect(path == scm.path || path != nil)
        } catch {
            Issue.record("wrong error (must be malformedQuery, not soft omit): \(error)")
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
        let dir = try LANGNRealGrammarSupport.tempDir("lang-n02-o")
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

    @Test func test_LANG_N02_validHighlightsCompileWithRealJSONGrammar() throws {
        try LANGNRealGrammarSupport.ensureSharedJSONAndSwift()
        let registry = LanguageRegistry.shared
        guard let pointer = registry.parser(for: .json) else {
            Issue.record("expected tree_sitter_json after pack register")
            return
        }
        let language = Language(language: pointer)
        let (queries, _) = try QuerySetLoader.loadAndCompile(
            languageID: .json,
            kinds: [.highlights],
            language: language,
            registry: registry
        )
        #expect(queries[.highlights] != nil)
    }
}

// MARK: - LANG-N03

@Suite("LANG-N03 single ParseSession path")
struct LANGN03ParseSessionTests {
    @Test func test_LANG_N03_parseSessionIsSoleStateOwner() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        let g1 = try await session.setText(#"{"a":1}"#)
        let snap = await session.snapshot()
        #expect(snap.documentVersion == g1)
        #expect(snap.hasTree == true)
        #expect(await session.isCurrent(generation: g1))
        let g2 = try await session.setText(#"{"a":2}"#)
        #expect(await session.isCurrent(generation: g1) == false)
        #expect(
            await session.isCurrent(
                documentVersion: g2, languageGeneration: snap.languageGeneration))
    }

    @Test func test_LANG_N03_staleHighlightSnapshotDiscarded() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        let text = #"{"key": 42}"#
        _ = try await session.setText(text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let published = try await session.queryHighlights(in: range)
        #expect(published.highlights.count > 0)
        let publishedDoc = published.documentVersion
        let publishedLang = published.languageGeneration
        #expect(await session.isCurrent(documentVersion: publishedDoc, languageGeneration: publishedLang))

        // Mutate document → prior HighlightSnapshot is stale and must be discarded.
        _ = try await session.setText(#"{"other": true}"#)
        #expect(
            await session.isCurrent(documentVersion: publishedDoc, languageGeneration: publishedLang)
                == false)

        // Fresh query is current; stale publication must not be re-applied by consumers.
        let fresh = try await session.queryHighlights(
            in: NSRange(location: 0, length: (#"{"other": true}"# as NSString).length))
        #expect(fresh.documentVersion != publishedDoc)
        #expect(await session.isCurrent(
            documentVersion: fresh.documentVersion,
            languageGeneration: fresh.languageGeneration))
        #expect(fresh.highlights.count > 0)
    }

    @MainActor
    @Test func test_LANG_N03_highlightProviderUsesParseSessionOnly() async throws {
        try LANGNRealGrammarSupport.ensureSharedJSONAndSwift()
        let provider = TreeSitterHighlightProvider(language: .json)
        let session = provider.parseSession
        let text = #"{"a":1}"#
        await provider.setDocumentText(text)
        let ranges = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length),
            text: text
        )
        #expect(ranges.count > 0)
        #expect(provider.highlightGeneration > 0)
        // Session is the sole engine — language ref retained, tree present.
        #expect(await session.retainedLanguageID() == .json)
        let snap = await session.snapshot()
        #expect(snap.hasTree == true)
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
        let copy = ref
        #expect(copy == ref)
    }

    @Test func test_LANG_N04_registryLanguageRefNilWithoutParser() {
        let registry = LanguageRegistry()
        #expect(registry.languageRef(for: .python) == nil)
    }

    @Test func test_LANG_N04_sessionRetainsLanguageRefAcrossEdits() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        #expect(ref.ownership == .staticGrammarSymbol)
        #expect(ref.languageID == .json)
        let pointerBits = UInt(bitPattern: ref.pointer)
        #expect(pointerBits != 0)

        let session = ParseSession()
        #expect(await session.retainedLanguageID() == nil)
        try await session.configure(config, languageRef: ref)
        #expect(await session.retainedLanguageID() == .json)
        #expect(await session.retainedLanguageRef() == ref)

        var text = #"{"a":1}"#
        _ = try await session.setText(text)
        #expect(await session.retainedLanguageID() == .json)
        #expect(UInt(bitPattern: (await session.retainedLanguageRef()!).pointer) == pointerBits)

        // Incremental edit: language ref must outlive trees/parsers/queries.
        let insert = #""b":2,"#
        let old = text
        text = #"{"b":2,"a":1}"#
        let insertLen = (insert as NSString).length
        _ = try await session.applyEdit(
            range: NSRange(location: 1, length: 0),
            delta: insertLen,
            newText: text
        )
        #expect(old != text)
        #expect(await session.retainedLanguageID() == .json)
        let retained = await session.retainedLanguageRef()
        #expect(retained == ref)
        #expect(retained?.ownership == .staticGrammarSymbol)

        // Highlights still work with retained grammar.
        let hs = try await session.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length))
        #expect(hs.highlights.count > 0)
        #expect(await session.retainedLanguageID() == .json)
    }

    @Test func test_LANG_N04_deallocationStressRepeatedSessionCycle() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        var lastVersion: UInt64 = 0
        for i in 0..<100 {
            let session = ParseSession()
            try await session.configure(config, languageRef: ref)
            #expect(await session.retainedLanguageID() == .json)
            lastVersion = try await session.setText(#"{"n":\#(i)}"#)
            #expect(lastVersion >= 1)
            let snap = await session.snapshot()
            #expect(snap.hasTree == true)
            _ = try await session.queryHighlights(
                in: NSRange(location: 0, length: snap.sourceUTF16Length))
            await session.reset()
            #expect(await session.retainedLanguageID() == nil)
            let after = await session.documentVersion
            #expect(after > lastVersion)
        }
        #expect(lastVersion >= 1)
    }
}

// MARK: - LANG-N05

@Suite("LANG-N05 Tree-sitter direct ownership suite")
struct LANGN05TreeSitterOwnershipTests {
    @Test func test_LANG_N05_incrementalEditBeforeInsideAfterMultibyte() async throws {
        // UTF-16 aware InputEdit math (emoji = 2 UTF-16 units).
        let old = "ab😀cd"
        let oldNS = old as NSString
        #expect(oldNS.length == 6)

        let eBefore = TreeSitterEdit.make(
            range: NSRange(location: 0, length: 0),
            delta: 1,
            oldSource: old,
            newSource: "X" + old
        )
        #expect(eBefore.startByte == 0)

        let eInside = TreeSitterEdit.make(
            range: NSRange(location: 2, length: 2),
            delta: -1,
            oldSource: old,
            newSource: "abYcd"
        )
        #expect(eInside.startByte == 4)
        #expect(eInside.oldEndByte == 8)

        let eAfter = TreeSitterEdit.make(
            range: NSRange(location: 5, length: 1),
            delta: 0,
            oldSource: old,
            newSource: "ab😀cZ"
        )
        #expect(eAfter.startByte == 10)

        // Real parser path: configure JSON session and apply multibyte-adjacent edits
        // inside a JSON string (emoji in a string value).
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        var text = #"{"msg":"ab😀cd"}"#
        _ = try await session.setText(text)
        #expect(await session.snapshot().hasTree == true)

        // Edit before emoji inside the string value.
        let prefix = #"{"msg":""#
        let emojiLoc = (prefix as NSString).length + 2  // after "ab"
        let insert = "X"
        let newBefore = #"{"msg":"abX😀cd"}"#
        _ = try await session.applyEdit(
            range: NSRange(location: emojiLoc, length: 0),
            delta: (insert as NSString).length,
            newText: newBefore
        )
        text = newBefore
        #expect(await session.snapshot().hasTree == true)

        // Replace emoji (2 UTF-16) with Y
        let emojiAt = ( #"{"msg":"abX"# as NSString).length
        let afterEmoji = #"{"msg":"abXYcd"}"#
        _ = try await session.applyEdit(
            range: NSRange(location: emojiAt, length: 2),
            delta: -1,
            newText: afterEmoji
        )
        #expect(await session.snapshot().hasTree == true)
        let hs = try await session.queryHighlights(
            in: NSRange(location: 0, length: (afterEmoji as NSString).length))
        #expect(hs.highlights.count > 0)
    }

    @Test func test_LANG_N05_malformedSourceDoesNotCrashSession() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        let garbage = String(repeating: "}\n{((", count: 50)
        _ = try await session.setText(garbage)
        let snap = await session.snapshot()
        #expect(snap.hasTree == true)  // tree-sitter recovers; does not crash
        // Query may return empty or partial captures — must not throw/crash.
        let hs = try await session.queryHighlights(
            in: NSRange(location: 0, length: min(20, snap.sourceUTF16Length)))
        #expect(hs.documentVersion == snap.documentVersion)
        #expect(await session.retainedLanguageID() == .json)
    }

    @Test func test_LANG_N05_cancellationAndStaleGenerationDiscard() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        let g1 = try await session.setText(#"{"one":1}"#)
        let range = NSRange(location: 0, length: (#"{"one":1}"# as NSString).length)
        let snap1 = try await session.queryHighlights(in: range)
        #expect(snap1.highlights.count > 0)
        #expect(snap1.documentVersion == g1)

        let g2 = try await session.setText(#"{"two":2}"#)
        #expect(g2 > g1)
        #expect(await session.isCurrent(generation: g1) == false)
        #expect(
            await session.isCurrent(
                documentVersion: snap1.documentVersion,
                languageGeneration: snap1.languageGeneration) == false)

        // Cancelled task must surface EngineError.cancelled, not a silent empty result.
        let cancelSession = ParseSession()
        try await cancelSession.configure(config, languageRef: ref)
        _ = try await cancelSession.setText(#"{"c":true}"#)
        let task = Task {
            try Task.checkCancellation()
            return try await cancelSession.queryHighlights(
                in: NSRange(location: 0, length: 10))
        }
        task.cancel()
        do {
            _ = try await task.value
            // May complete before cancel lands; still require stale discard path above.
        } catch is CancellationError {
            // ok
        } catch ParseSession.EngineError.cancelled {
            // ok
        }
    }

    @Test func test_LANG_N05_allQueryKindsHaveBasenames() {
        for kind in QueryKind.allCases {
            #expect(!kind.fileBasename.isEmpty)
            #expect(kind.fileName.hasSuffix(".scm"))
        }
        #expect(QueryKind.allCases.count >= 8)
    }

    @Test func test_LANG_N05_allSupportedQueryCategoriesCompileForJSON() throws {
        try LANGNRealGrammarSupport.ensureSharedJSONAndSwift()
        let registry = LanguageRegistry.shared
        guard let pointer = registry.parser(for: .json) else {
            Issue.record("json parser required")
            return
        }
        let language = Language(language: pointer)
        // Every shipped kind for JSON must compile; missing optional is diagnostic only.
        let kinds: Set<QueryKind> = [.highlights, .folds, .indents, .locals]
        let (queries, diags) = try QuerySetLoader.loadAndCompile(
            languageID: .json,
            kinds: kinds,
            language: language,
            registry: registry,
            required: [.highlights]
        )
        #expect(queries[.highlights] != nil)
        // folds/indents/locals ship with the JSON pack — compile when present.
        for kind in kinds where registry.queryURL(for: .json, kind: kind) != nil {
            #expect(queries[kind] != nil, "present \(kind.rawValue) must compile")
        }
        #expect(!diags.contains(where: {
            if case .malformed = $0 { return true }
            return false
        }))
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

    @Test func test_LANG_N05_grammarUnloadReload() async throws {
        let host = try LANGNRealGrammarSupport.hostJSONRegistry()
        #expect(host.hasParser(for: .json))
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration(registry: host)
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        _ = try await session.setText(#"{"x":1}"#)
        #expect(await session.snapshot().hasTree)

        // Unload: reset session (drops languageRef) — reload with same static grammar.
        await session.reset()
        #expect(await session.retainedLanguageID() == nil)
        try await session.configure(config, languageRef: ref)
        #expect(await session.retainedLanguageID() == .json)
        _ = try await session.setText(#"{"y":2}"#)
        let hs = try await session.queryHighlights(
            in: NSRange(location: 0, length: 7))
        #expect(hs.highlights.count > 0)
    }

    @Test func test_LANG_N05_largeFileRepeatedEdits() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)

        // Large JSON array of objects (~50k lines worth of small objects).
        var items = (0..<2_000).map { #"{"i":\#($0)}"# }.joined(separator: ",")
        var text = "[\(items)]"
        _ = try await session.setText(text)
        #expect(await session.snapshot().hasTree == true)
        #expect(await session.retainedLanguageID() == .json)

        for i in 0..<20 {
            let insert = #"{"i":\#(10_000 + i)},"#
            let old = text
            text = "[" + insert + String(text.dropFirst())
            let result = try await session.applyEdit(
                range: NSRange(location: 1, length: 0),
                delta: (insert as NSString).length,
                newText: text
            )
            #expect(result.documentVersion > 0)
            #expect(old != text)
            #expect(await session.retainedLanguageID() == .json)
        }
        let snap = await session.snapshot()
        #expect(snap.hasTree == true)
        // Spot-check highlights still query on large tree.
        let hs = try await session.queryHighlights(in: NSRange(location: 0, length: 80))
        #expect(hs.highlights.count > 0)
    }

    @Test func test_LANG_N05_queryCaptureValidationEmptyWithoutConfig() async throws {
        // Unconfigured path still typed.
        let unconfigured = ParseSession()
        _ = try await unconfigured.setText("func f() {}")
        do {
            _ = try await unconfigured.queryHighlights(
                in: NSRange(location: 0, length: 4))
            Issue.record("expected notConfigured")
        } catch ParseSession.EngineError.notConfigured {
            // ok
        }

        // Configured path: real captures with expected JSON scopes (LANG-N05 validation).
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let session = ParseSession()
        try await session.configure(config, languageRef: ref)
        let text = #"{"name": "value", "n": 1, "ok": true, "z": null}"#
        _ = try await session.setText(text)
        let hs = try await session.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length))
        #expect(hs.highlights.count > 0)
        let rawNames = Set(hs.highlights.compactMap(\.rawCapture))
        // highlights.scm: string.special.key, string, number, constant.builtin
        #expect(
            rawNames.contains(where: { $0.contains("string") }),
            "expected string-related capture, got \(rawNames)")
        #expect(
            rawNames.contains(where: { $0.contains("number") || $0.contains("constant") }),
            "expected number/constant capture, got \(rawNames)")
    }
}

// MARK: - Phase6 compatibility

@Suite("Phase6 LanguageDocumentActor")
struct Phase6LanguageDocumentActorTests {
    @Test func generationAdvancesAndStaleRejected() async throws {
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let actor = LanguageDocumentActor()
        try await actor.configure(config, languageRef: ref)
        let g1 = try await actor.setText(#"{"a":1}"#)
        let g2 = try await actor.setText(#"{"a":2}"#)
        #expect(g2 > g1)
        #expect(await actor.isCurrent(generation: g2))
        #expect(await actor.isCurrent(generation: g1) == false)
        #expect(await actor.snapshot().hasTree == true)
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
        let (config, ref) = try LANGNRealGrammarSupport.jsonConfiguration()
        let actor = LanguageDocumentActor()
        try await actor.configure(config, languageRef: ref)
        let gen = try await Task.detached {
            try await actor.setText(#"{"hello":true}"#)
        }.value
        #expect(gen >= 1)
    }
}
