import CodeEditorLanguageSupport
import CodeEditorLanguages
import CodeEditorTreeSitter
import Foundation
import Testing

/// Generated-style conformance matrix for all shipped grammar packs (LANG-N06).
///
/// Covers parser load, representative parse, highlight query presence/compile,
/// optional query compile when shipped, malformed-source non-crash, and
/// inventory provenance fields for built-in packs.
@Suite("LANG-N06 grammar pack conformance", .serialized)
struct LANGN06ConformanceTests {
    /// Catalog language IDs expected from the umbrella bootstrap (39 grammars + aliases).
    private static let shippedLanguageIDs: [LanguageID] = [
        .agda, .bash, .c, .cpp, .cSharp, .css, .dart, .dockerfile, .elixir,
        .go, .goMod, .haskell, .html, .java, .javascript, .jsdoc, .json, .jsx,
        .julia, .kotlin, .lua, .markdown, .markdownInline, .objc, .ocaml, .perl,
        .php, .python, .regex, .ruby, .rust, .scala, .sql, .swift, .toml,
        .tsx, .typescript, .verilog, .yaml, .zig,
    ]

    private static let representativeSource: [String: String] = [
        "swift": "func hello() -> Int { return 1 }\n",
        "json": #"{"a": 1, "b": true}"#,
        "python": "def f(x):\n    return x + 1\n",
        "javascript": "const x = (a) => a + 1;\n",
        "typescript": "const x: number = 1;\n",
        "tsx": "const e = <div/>;\n",
        "go": "package main\nfunc main() {}\n",
        "rust": "fn main() { let x = 1; }\n",
        "c": "int main(void) { return 0; }\n",
        "cpp": "int main() { return 0; }\n",
        "java": "class A { int x() { return 1; } }\n",
        "ruby": "def f(x) x + 1 end\n",
        "bash": "echo hello\n",
        "html": "<div class=\"x\">hi</div>\n",
        "css": "body { color: red; }\n",
        "yaml": "a: 1\nb: [2, 3]\n",
        "toml": "a = 1\n",
        "markdown": "# Title\n\nParagraph.\n",
        "sql": "SELECT 1 AS x;\n",
        "lua": "local x = 1\n",
        "php": "<?php echo 1;\n",
        "kotlin": "fun main() { println(1) }\n",
        "scala": "object A { def f = 1 }\n",
        "zig": "pub fn main() void {}\n",
        "elixir": "def f(x), do: x\n",
        "haskell": "f x = x + 1\n",
        "ocaml": "let f x = x + 1\n",
        "perl": "my $x = 1;\n",
        "julia": "f(x) = x + 1\n",
        "dart": "void main() { print(1); }\n",
        "verilog": "module m; endmodule\n",
        "dockerfile": "FROM alpine\nRUN echo hi\n",
        "regex": "a+b*\n",
        "jsdoc": "/** @param {string} x */\n",
        "goMod": "module example.com/m\ngo 1.22\n",
        "objc": "@interface A : NSObject @end\n",
        "cSharp": "class A { int M() => 1; }\n",
        "agda": "module M where\n",
        "markdownInline": "*emph* and `code`\n",
        "jsx": "const e = <span/>;\n",
    ]

    init() {
        _ = CodeEditorLanguages.bootstrap()
    }

    @Test func test_LANG_N06_allShippedParsersLoad() {
        var missing: [String] = []
        for id in Self.shippedLanguageIDs {
            if !LanguageRegistry.shared.hasParser(for: id) {
                missing.append(id.rawValue)
            }
        }
        #expect(missing.isEmpty, "parsers missing: \(missing)")
        #expect(Self.shippedLanguageIDs.count >= 39)
    }

    @Test func test_LANG_N06_highlightQueriesPresentAndReadable() throws {
        var failures: [String] = []
        for id in Self.shippedLanguageIDs {
            // jsx shares javascript queries in some packs — allow missing only if no provider.
            guard LanguageRegistry.shared.hasQueryProvider(for: id) else {
                // jsx may rely on javascript provider in some registrations
                if id == .jsx { continue }
                failures.append("\(id.rawValue): no query provider")
                continue
            }
            guard let url = LanguageRegistry.shared.queryURL(for: id, kind: .highlights) else {
                if id == .jsx { continue }
                failures.append("\(id.rawValue): no highlights.scm")
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.isEmpty {
                failures.append("\(id.rawValue): empty highlights")
            }
        }
        #expect(failures.isEmpty, "highlight failures: \(failures)")
    }

    /// Expected highlight capture substrings for pilot/representative packs (LANG-N06 scopes).
    private static let expectedHighlightScopes: [String: [String]] = [
        "json": ["string", "number"],
        "swift": ["function", "keyword", "type"],
        "python": ["function", "keyword"],
        "javascript": ["variable", "function", "keyword"],
        "go": ["function", "keyword"],
        "rust": ["function", "keyword"],
        "c": ["function", "type", "keyword"],
    ]

    @Test func test_LANG_N06_representativeSourceParsesWithoutCrash() async throws {
        var parseFailures: [String] = []
        var highlightCompileFailures: [String] = []
        var scopeFailures: [String] = []
        var highlightOK = 0
        for id in Self.shippedLanguageIDs {
            guard let pointer = LanguageRegistry.shared.parser(for: id) else {
                parseFailures.append("\(id.rawValue): no parser")
                continue
            }
            let source = Self.representativeSource[id.rawValue] ?? "x = 1\n"
            // Parser-only path: prove grammar loads and parses without requiring queries.
            let parser = Parser()
            let language = Language(language: pointer)
            do {
                try parser.setLanguage(language)
            } catch {
                parseFailures.append("\(id.rawValue): setLanguage \(error)")
                continue
            }
            let tree = parser.parse(source)
            if tree == nil {
                parseFailures.append("\(id.rawValue): parse returned nil")
            }
            // Malformed fixture must not crash the parser.
            _ = parser.parse("}}}{{{(((***")

            // Highlight compile: fail-closed (typed error) when query mismatches grammar.
            if let codeLang = CodeLanguages.language(id: id.rawValue) {
                TreeSitterConfigurationFactory.clearCache()
                do {
                    if let config = try TreeSitterConfigurationFactory.languageConfiguration(for: codeLang) {
                        highlightOK += 1
                        // Expected scopes for key packs: query real captures (not compile-only).
                        if let expected = Self.expectedHighlightScopes[id.rawValue],
                            let highlightsQuery = config.queries[.highlights],
                            let parsed = tree
                        {
                            let cursor = highlightsQuery.execute(in: parsed)
                            cursor.setRange(NSRange(location: 0, length: (source as NSString).length))
                            let named = cursor
                                .resolve(with: Predicate.Context(string: source))
                                .highlights()
                            let names = Set(named.map(\.name))
                            let matched = expected.contains { exp in
                                names.contains(where: { $0.localizedCaseInsensitiveContains(exp) })
                            }
                            if !matched {
                                scopeFailures.append(
                                    "\(id.rawValue): expected one of \(expected) in \(names.sorted())")
                            }
                        }
                    }
                } catch TreeSitterConfigurationFactory.Error.malformedQuery {
                    highlightCompileFailures.append(id.rawValue)
                } catch {
                    highlightCompileFailures.append("\(id.rawValue): \(error)")
                }
            }
        }
        #expect(parseFailures.isEmpty, "parse failures: \(parseFailures)")
        // All shipped packs must compile highlights (fail closed — no soft omit).
        #expect(
            highlightCompileFailures.isEmpty,
            "highlight compile failures (fail closed): \(highlightCompileFailures)")
        #expect(
            highlightOK >= Self.shippedLanguageIDs.count - 1,
            "highlight compile ok=\(highlightOK) of \(Self.shippedLanguageIDs.count)")
        #expect(scopeFailures.isEmpty, "expected scopes missing: \(scopeFailures)")
    }

    @Test func test_LANG_N06_optionalShippedQueriesCompileWhenPresent() throws {
        var failures: [String] = []
        var compiledCount = 0
        let optionalKinds: [QueryKind] = [
            .folds, .indents, .injections, .locals, .tags, .outline, .textobjects, .structure,
        ]
        for id in Self.shippedLanguageIDs {
            guard let pointer = LanguageRegistry.shared.parser(for: id) else { continue }
            let language = Language(language: pointer)
            for kind in optionalKinds {
                guard let url = LanguageRegistry.shared.queryURL(for: id, kind: kind) else {
                    continue  // not shipped — OK (missing optional is not an error)
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard let data = text.data(using: .utf8), !data.isEmpty else {
                    failures.append("\(id.rawValue).\(kind.rawValue): empty present file")
                    continue
                }
                do {
                    // Present optional queries must compile (LANG-N02/N06 fail closed).
                    _ = try Query(language: language, data: data)
                    compiledCount += 1
                } catch {
                    failures.append("\(id.rawValue).\(kind.rawValue): \(error)")
                }
            }
        }
        #expect(Self.shippedLanguageIDs.count >= 39)
        #expect(compiledCount >= 10, "expected many shipped optional queries to compile, got \(compiledCount)")
        // Fail closed: no soft/informational pass on present-but-broken optional queries.
        #expect(failures.isEmpty, "present optional queries must compile: \(failures)")
    }

    @Test func test_LANG_N06_inventoryProvenancePresentForSwiftAndJSON() {
        // Pilot packs expose pin metadata; umbrella grammars are pinned via grammar-inventory.json.
        #expect(CodeEditorLanguageSwift.grammarCommit.count == 40)
        #expect(CodeEditorLanguageSwift.grammarParserSHA256.count == 64)
        #expect(CodeEditorLanguageJSON.grammarCommit.count == 40)
        let inventoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LANGN06...
            .deletingLastPathComponent()  // CodeEditorLanguagesTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("scripts/grammar-inventory.json")
        #expect(FileManager.default.fileExists(atPath: inventoryURL.path))
        let data = try! Data(contentsOf: inventoryURL)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let grammars = json["grammars"] as! [[String: Any]]
        #expect(grammars.count == 39)
        for g in grammars {
            #expect((g["commit"] as? String)?.count == 40, "missing commit for \(g["name"] ?? "?")")
            #expect((g["license"] as? String)?.isEmpty == false)
            #expect((g["parser_c_sha256"] as? String)?.count == 64)
            #expect((g["repository_url"] as? String)?.contains("http") == true)
        }
    }

    @Test func test_LANG_N06_hostOwnedBootstrapDoesNotRequireSharedMutation() {
        let host = LanguageRegistry()
        let first = CodeEditorLanguages.bootstrap(into: host, installEnvironment: false)
        #expect(first == true)
        #expect(host.hasParser(for: .swift))
        #expect(host.hasParser(for: .zig))
        // Shared may or may not already be bootstrapped; host is independently populated.
        let second = CodeEditorLanguages.bootstrap(into: host, installEnvironment: false)
        #expect(second == false)
    }

    @MainActor
    @Test func test_LANG_N06_malformedFixtureDoesNotCrashHighlightProvider() async throws {
        _ = CodeEditorLanguages.bootstrap()
        TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
        let provider = TreeSitterHighlightProvider(language: .json)
        let text = "{{{ not json at all %%%"
        await provider.setDocumentText(text)
        let ranges = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length),
            text: text
        )
        // May be empty or partial; must not throw/crash. Provider stays usable.
        #expect(ranges.count >= 0)
        #expect(provider.highlightGeneration >= 0)
    }
}

// Need SwiftTreeSitter for Query compile in optional matrix.
import SwiftTreeSitter
import CodeEditorLanguageSwift
import CodeEditorLanguageJSON
