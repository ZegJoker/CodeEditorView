import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Highlight paint")
@MainActor
struct HighlightPaintTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func controllerAttributesAreContiguousForTokens() async throws {
        let source = """
            static void Greet(string name) {
                Console.WriteLine("hi");
                if (string.IsNullOrEmpty(name)) {
                    return;
                }
            }
            """
        let controller = EditorController(text: source, language: .cSharp)
        // Allow async language load + highlight
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
            if controller.highlightProviders.first is TreeSitterHighlightProvider {
                break
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            containerWidth: 800
        )
        try await Task.sleep(for: .milliseconds(300))

        let storage = controller.document.storage
        let ns = source as NSString
        // Find WriteLine
        let wr = ns.range(of: "WriteLine")
        #expect(wr.length == 9)
        var colors: [String] = []
        for i in 0..<wr.length {
            let loc = wr.location + i
            let attrs = storage.attributes(at: loc, effectiveRange: nil)
            let color = attrs[.foregroundColor] as? PlatformColor
            colors.append(color.map { String(describing: $0) } ?? "nil")
        }
        let unique = Set(colors)
        print("WriteLine colors unique=\(unique.count) detail=\(colors)")
        #expect(unique.count == 1, "WriteLine should be one color, got \(unique.count): \(colors)")

        let ret = ns.range(of: "return")
        var retColors: [String] = []
        for i in 0..<ret.length {
            let attrs = storage.attributes(at: ret.location + i, effectiveRange: nil)
            let color = attrs[.foregroundColor] as? PlatformColor
            retColors.append(color.map { String(describing: $0) } ?? "nil")
        }
        print("return colors unique=\(Set(retColors).count) detail=\(retColors)")
        #expect(Set(retColors).count == 1, "return should be one color")
    }
}
