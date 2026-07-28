import Testing
import CoreGraphics
@testable import CodeEditorView

@Suite("Minimap geometry")
struct MinimapGeometryTests {
    @Test func widthClamps() {
        #expect(MinimapGeometry.width(hostWidth: 100) == MinimapMetrics.minWidth)
        let mid = MinimapGeometry.width(hostWidth: 800)
        #expect(mid == 800 * MinimapMetrics.relativeWidth)
        #expect(MinimapGeometry.width(hostWidth: 2000) == MinimapMetrics.maxWidth)
    }

    @Test func yMappingRoundTrip() {
        let editorH: CGFloat = 1000
        let miniH: CGFloat = 300
        let y = MinimapGeometry.minimapY(editorY: 250, editorHeight: editorH, minimapHeight: miniH)
        #expect(abs(y - 75) < 0.001)
        let back = MinimapGeometry.editorY(minimapY: y, editorHeight: editorH, minimapHeight: miniH)
        #expect(abs(back - 250) < 0.001)
    }

    @Test func viewportHeight() {
        let h = MinimapGeometry.viewportHeight(
            editorVisibleHeight: 200,
            editorHeight: 1000,
            minimapHeight: 500
        )
        #expect(abs(h - 100) < 0.001)
    }

    @Test func scrollFraction() {
        #expect(MinimapGeometry.scrollFraction(editorOffsetY: 0, editorHeight: 1000, editorVisibleHeight: 200) == 0)
        #expect(MinimapGeometry.scrollFraction(editorOffsetY: 400, editorHeight: 1000, editorVisibleHeight: 200) == 0.5)
        #expect(MinimapGeometry.scrollFraction(editorOffsetY: 800, editorHeight: 1000, editorVisibleHeight: 200) == 1)
    }

    @Test func viewportDoesNotFillStripWhenDocumentIsShort() {
        // Short content in a tall strip: overlay covers content, not the whole strip.
        let frame = MinimapGeometry.viewportFrame(
            editorOffsetY: 0,
            editorVisibleHeight: 400,
            editorHeight: 200,
            contentHeight: 60,
            stripHeight: 600
        )
        #expect(frame.height <= 60 + 0.5)
        #expect(frame.height < 600)
        #expect(abs(frame.origin.y) < 0.5)
    }

    @Test func viewportTracksScrollOnTallDocument() {
        let top = MinimapGeometry.viewportFrame(
            editorOffsetY: 0,
            editorVisibleHeight: 200,
            editorHeight: 2000,
            contentHeight: 400,
            stripHeight: 300
        )
        let mid = MinimapGeometry.viewportFrame(
            editorOffsetY: 900,
            editorVisibleHeight: 200,
            editorHeight: 2000,
            contentHeight: 400,
            stripHeight: 300
        )
        let bottom = MinimapGeometry.viewportFrame(
            editorOffsetY: 1800,
            editorVisibleHeight: 200,
            editorHeight: 2000,
            contentHeight: 400,
            stripHeight: 300
        )
        #expect(top.origin.y < mid.origin.y)
        #expect(mid.origin.y < bottom.origin.y)
        // Box height is a fraction of the strip, not the full strip.
        #expect(top.height < 300)
        #expect(top.height > MinimapMetrics.lineHeight - 0.5)
    }
}
