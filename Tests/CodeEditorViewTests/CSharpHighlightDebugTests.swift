import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages


@Suite("CSharp highlight debug")
@MainActor
struct CSharpHighlightDebugTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func printRanges() async throws {
        let source = """
        using System;
        class Program {
            static void Greet(string name) {
                Console.WriteLine("hi");
            }
        }
        """
        let provider = try #require(TreeSitterHighlightProvider.make(for: .cSharp))
        await provider.loadAsync(language: .cSharp)
        await provider.setDocumentText(source)
        let full = NSRange(location: 0, length: (source as NSString).length)
        let highlights = try await provider.queryHighlights(in: full, text: source)
        print("C# highlight count=\(highlights.count)")
        let ns = source as NSString
        for h in highlights.prefix(50) {
            let piece = ns.substring(with: h.range)
            print("\(h.range.location)+\(h.range.length) cap=\(h.capture?.rawValue ?? "nil") raw=\(h.rawCapture ?? "") text=\(piece.debugDescription)")
        }
        #expect(!highlights.isEmpty)
        // Keywords like "class" should be a single contiguous range, not 1-char fragments for the whole word only
        let classHits = highlights.filter { ($0.rawCapture ?? "").contains("keyword") && ns.substring(with: $0.range).contains("class") || ns.substring(with: $0.range) == "class" }
        print("class hits: \(classHits.count)")
    }
}
