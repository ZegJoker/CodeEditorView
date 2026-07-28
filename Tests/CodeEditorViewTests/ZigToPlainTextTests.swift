import Testing
import Foundation
@testable import CodeEditorView
import CodeEditorLanguages

@Suite("Zig to plain text")
@MainActor
struct ZigToPlainTextTests {
    @Test func zigConfigLoad() throws {
        let t0 = ContinuousClock.now
        let config = try CodeLanguages.languageConfiguration(for: .zig)
        print("Zig config \(ContinuousClock.now - t0) patterns=\(config?.queries[.highlights]?.patternCount ?? -1)")
        #expect(config != nil)
    }

    @Test func zigToPlainTextDoesNotHang() async throws {
        let zig = """
        // Zig
        const std = @import("std");
        pub fn main() void {
            std.debug.print("hi\\n", .{});
        }
        """
        let controller = EditorController(text: zig, language: .zig)
        let t0 = ContinuousClock.now
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            if ContinuousClock.now - t0 > .seconds(5) { break }
        }
        print("zig settle \(ContinuousClock.now - t0) lang=\(controller.languageID ?? "nil") providers=\(controller.highlightProviders.count)")

        let t1 = ContinuousClock.now
        // Demo passes language: nil for plain text
        controller.language = nil
        controller.languageID = nil
        controller.text = "Plain text — no tree-sitter highlighting.\n"
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            if ContinuousClock.now - t1 > .seconds(6) { break }
        }
        print("plain switch \(ContinuousClock.now - t1) lang=\(controller.languageID ?? "nil") providers=\(controller.highlightProviders.count)")
        #expect(ContinuousClock.now - t1 < .seconds(6))
        #expect(controller.highlightProviders.isEmpty)
    }

    @Test func plainTextViaLanguagePlainText() async throws {
        let controller = EditorController(text: "fn main() {}", language: .zig)
        for _ in 0..<30 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let t0 = ContinuousClock.now
        controller.language = .plainText
        controller.text = "hello plain\n"
        for _ in 0..<30 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("plainText id switch \(ContinuousClock.now - t0) providers=\(controller.highlightProviders.count)")
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }
}
