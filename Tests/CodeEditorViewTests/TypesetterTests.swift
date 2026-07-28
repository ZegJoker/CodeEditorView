import Testing
import Foundation
@testable import CodeEditorView

@Suite("Typesetter")
struct TypesetterTests {
    @Test func emptyLine() {
        let typesetter = Typesetter()
        let result = typesetter.typeset(
            NSAttributedString(string: ""),
            documentRange: NSRange(location: 0, length: 0),
            display: TypesetDisplayData(maxWidth: 200, estimatedLineHeight: 16)
        )
        #expect(result.fragments.count == 1)
        #expect(result.totalHeight == 16)
    }

    @Test func wrapsLongLine() {
        let font = PlatformDefaults.monospacedFont
        let text = String(repeating: "abcde ", count: 40)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = Typesetter(breakStrategy: .word)
        let result = typesetter.typeset(
            attr,
            documentRange: NSRange(location: 0, length: attr.length),
            display: TypesetDisplayData(maxWidth: 120, estimatedLineHeight: 16)
        )
        #expect(result.fragments.count > 1)
        #expect(result.totalHeight > 16)
    }
}
