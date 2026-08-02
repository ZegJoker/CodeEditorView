import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("HTML to TS switch")
@MainActor
struct HTMLToTSSwitchTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func htmlThenTypescriptDoesNotHang() async throws {
        let html = demoHTML
        let ts = demoTS
        let controller = EditorController(text: html, language: .html)
        let t0 = ContinuousClock.now
        for _ in 0..<30 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            if ContinuousClock.now - t0 > .seconds(4) { break }
        }
        print("html settle \(ContinuousClock.now - t0)")

        let t1 = ContinuousClock.now
        controller.language = .typescript
        controller.text = ts
        var n = 0
        while ContinuousClock.now - t1 < .seconds(8) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            n += 1
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
            if n > 40 { break }
        }
        print("ts switch \(ContinuousClock.now - t1) n=\(n) lang=\(controller.languageID ?? "?")")
        #expect(ContinuousClock.now - t1 < .seconds(8))

        // keywords should highlight
        let storage = controller.document.storage
        let r = (ts as NSString).range(of: "function")
        if r.location != NSNotFound {
            let c = storage.attributes(at: r.location, effectiveRange: nil)[.foregroundColor] as? PlatformColor
            print("function color=\(String(describing: c))")
        }
    }

    @Test func rapidLanguageFlapDoesNotHang() async throws {
        let controller = EditorController(text: "x", language: .swift)
        let langs: [CodeLanguage] = [.html, .typescript, .html, .typescript, .python, .typescript]
        let t0 = ContinuousClock.now
        for lang in langs {
            controller.language = lang
            controller.text = "// \(lang.displayName)\nfunction test() { return 1; }\n"
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        // settle
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            if ContinuousClock.now - t0 > .seconds(10) { break }
        }
        print("flap elapsed \(ContinuousClock.now - t0) lang=\(controller.languageID ?? "?")")
        #expect(ContinuousClock.now - t0 < .seconds(12))
    }
}

private let demoHTML = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>CodeEditorView</title>
      </head>
      <body>
        <h1>Hello, world!</h1>
        <!-- HTML demo -->
      </body>
    </html>
    """

private let demoTS = """
    // TypeScript
    function greet(name: string): void {
      console.log(`Hello, ${name}!`);
      if (!name) {
        return;
      }
    }
    const message: string = "This is a deliberately long TypeScript string so soft-wrap can be verified when Wrap is enabled.";
    greet("world");
    """
