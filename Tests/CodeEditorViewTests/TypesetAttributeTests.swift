import Testing
import Foundation
import CoreText
@testable import CodeEditorView

@Suite("Typeset attributes")
@MainActor
struct TypesetAttributeTests {
    @Test func ctLineUsesForegroundColors() {
        let s = NSMutableAttributedString(string: "WriteLine")
        s.addAttribute(.foregroundColor, value: PlatformColor.systemPurple, range: NSRange(location: 0, length: 9))
        s.addAttribute(.font, value: PlatformDefaults.monospacedFont, range: NSRange(location: 0, length: 9))
        let typesetter = Typesetter()
        let result = typesetter.typeset(
            s,
            documentRange: NSRange(location: 0, length: 9),
            display: TypesetDisplayData(maxWidth: 500, lineHeightMultiplier: 1.2, estimatedLineHeight: 16)
        )
        #expect(result.fragments.count == 1)
        #expect(result.fragments[0].ctLine != nil)
        // Enumerate CTRun colors
        let line = result.fragments[0].ctLine!
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        print("run count=\(runs.count)")
        for run in runs {
            let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            print("run attrs color=\(attrs[.foregroundColor] as Any) len=\(CTRunGetGlyphCount(run))")
        }
        #expect(runs.count >= 1)
    }
}
