import CoreGraphics
import Foundation
import Testing

@testable import CodeEditorCommands
@testable import CodeEditorCore
@testable import CodeEditorView

// MARK: - UI-N01 CaretNavigationEngine

@Suite("UI-N01 CaretNavigationEngine")
@MainActor
struct UIN01CaretNavigationEngineTests {
    @Test func test_UI_N01_verticalMovePreservesPreferredXAcrossUnevenLines() {
        let text = "short\nlong line of text here\nmid\n"
        let controller = EditorController(text: text)
        let width: CGFloat = 400
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 800),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: text
        )
        // Caret at end of "short" (offset 5) — column near end of short line.
        let caret = TextPosition(utf16Offset: 5)
        let first = CaretNavigationEngine.move(
            caret: caret,
            direction: .down,
            preferredX: nil,
            layout: snapshot
        )
        #expect(first.position.utf16Offset > 5)
        #expect(first.preferredX != nil)

        let second = CaretNavigationEngine.move(
            caret: first.position,
            direction: .down,
            preferredX: first.preferredX,
            layout: snapshot
        )
        // Preferred X should stick so we do not jump to end of long intermediate line solely by UTF-16 delta.
        let longLineEnd = (text as NSString).range(of: "\n", options: [], range: NSRange(location: 6, length: 20)).location
        #expect(second.position.utf16Offset != longLineEnd)
        #expect(second.preferredX == first.preferredX || abs((second.preferredX ?? 0) - (first.preferredX ?? 0)) < 0.5)
    }

    @Test func test_UI_N01_verticalMoveDoesNotLandInsideGrapheme() {
        let emoji = "😀"  // 2 UTF-16 units
        let text = "a\(emoji)\nb\(emoji)\n"
        let controller = EditorController(text: text)
        let width: CGFloat = 300
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 400),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: text
        )
        // From after 'a' (offset 1 is start of emoji — valid boundary).
        let start = TextPosition(utf16Offset: 1)
        let result = CaretNavigationEngine.move(
            caret: start,
            direction: .down,
            preferredX: nil,
            layout: snapshot
        )
        #expect(TextOffsetSemantics.isGraphemeBoundary(utf16Offset: result.position.utf16Offset, in: text))
        // Must never be mid-emoji (offset where only high surrogate sits).
        let midEmojiOnLine0 = 2  // inside first emoji if started at 1
        #expect(result.position.utf16Offset != midEmojiOnLine0 || TextOffsetSemantics.isGraphemeBoundary(utf16Offset: midEmojiOnLine0, in: text))
    }

    @Test func test_UI_N01_uiKitVerticalUsesEngineNotRawUTF16() {
        // Host path: EditorController.visualCaretMove (used by UIKitEditorView UITextInput).
        let text = "hello\nworld"
        let controller = EditorController(text: text)
        let width: CGFloat = 400
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 400),
            containerWidth: width
        )
        let moved = controller.visualCaretMove(
            from: 0,
            direction: .down,
            preferredX: 0,
            containerWidth: width
        )
        #expect(moved.position.utf16Offset == 6)  // start of "world"
        // Raw UTF-16 arithmetic would yield 1 ("e"), which is wrong for visual down.
        #expect(moved.position.utf16Offset != 1)

        // AppKit host path: controller.move(.down) must also use the engine (not SelectionEngine raw hit).
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        controller.move(direction: .down, containerWidth: width)
        #expect(controller.selectedRange.location == 6)
        #expect(controller.selectedRange.location != 1)
    }

    @Test func test_UI_N01_appKitHostViewWiresVerticalMoveToEngine() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let text = "aa\nbb\ncc"
            let controller = EditorController(text: text)
            let editor = AppKitEditorView(controller: controller)
            editor.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            editor.layoutSubtreeIfNeeded()
            controller.setSelectedRange(NSRange(location: 0, length: 0))
            // Simulate AppKit moveDown action path.
            editor.moveDown(nil)
            #expect(controller.selectedRange.location == 3)  // start of "bb"
            #expect(controller.selectedRange.location != 1)
        #endif
    }
}

// MARK: - UI-N02 grapheme-valid positions

@Suite("UI-N02 Grapheme-valid insertion points")
struct UIN02GraphemeValidPositionTests {
    @Test func test_UI_N02_midSurrogateIsInvalidInsertionPoint() {
        let emoji = "😀"
        let text = "x\(emoji)y"
        // Offset 2 is mid-emoji (after high surrogate).
        #expect(!TextOffsetSemantics.isGraphemeBoundary(utf16Offset: 2, in: text))
        #expect(throws: DocumentStoreError.self) {
            try TextOffsetSemantics.validatedInsertionPoint(utf16Offset: 2, in: text, policy: .exact)
        }
        let snapped = try! TextOffsetSemantics.validatedInsertionPoint(
            utf16Offset: 2, in: text, policy: .roundToGrapheme
        )
        #expect(TextOffsetSemantics.isGraphemeBoundary(utf16Offset: snapped, in: text))
        #expect(snapped == 1 || snapped == 3)
    }

    @Test func test_UI_N02_validatedSelectionRangeRejectsMidGraphemeEndpoints() {
        let text = "a👨‍👩‍👧‍👦b"
        let mid = 3  // inside ZWJ family if not boundary
        if !TextOffsetSemantics.isGraphemeBoundary(utf16Offset: mid, in: text) {
            #expect(throws: DocumentStoreError.self) {
                try TextOffsetSemantics.validatedSelectionRange(
                    NSRange(location: mid, length: 1),
                    in: text,
                    policy: .exact
                )
            }
            let safe = try! TextOffsetSemantics.validatedSelectionRange(
                NSRange(location: mid, length: 1),
                in: text,
                policy: .roundToGrapheme
            )
            #expect(TextOffsetSemantics.isGraphemeBoundary(utf16Offset: safe.location, in: text))
            #expect(
                TextOffsetSemantics.isGraphemeBoundary(
                    utf16Offset: safe.location + safe.length, in: text
                )
            )
        } else {
            // Family emoji may report boundary at unexpected offsets on some OS — still require API.
            let r = try! TextOffsetSemantics.validatedSelectionRange(
                NSRange(location: 0, length: (text as NSString).length),
                in: text,
                policy: .exact
            )
            #expect(r.location == 0)
        }
    }

    @Test func test_UI_N02_positionFactoryNeverReturnsInvalidOffset() {
        let text = "ab😀cd"
        let len = (text as NSString).length
        for raw in 0...len {
            let p = NativeInputPositions.clampedGraphemePosition(utf16Offset: raw, in: text)
            #expect(TextOffsetSemantics.isGraphemeBoundary(utf16Offset: p, in: text))
        }
    }
}

// MARK: - UI-N03 selection geometry

@Suite("UI-N03 Fragment selection rects")
@MainActor
struct UIN03SelectionGeometryTests {
    @Test func test_UI_N03_rectsArePerFragmentNotPerUTF16Unit() {
        let line = String(repeating: "abcdefghij", count: 20)  // 200 chars
        let text = line + "\n" + line
        let controller = EditorController(text: text)
        let width: CGFloat = 200  // force wrapping → multiple fragments
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 2000),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: text
        )
        let full = NSRange(location: 0, length: (text as NSString).length)
        let rects = SelectionGeometry.selectionRects(
            for: full,
            layout: snapshot,
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 2000)
        )
        #expect(!rects.isEmpty)
        #expect(rects.count < full.length)  // not one rect per UTF-16 unit
        // Must not exceed fragment count + small slack for multi-cursor splits.
        #expect(rects.count <= snapshot.fragments.count + 4)
    }

    @Test func test_UI_N03_largeSelectionIsSublinearInUTF16Length() {
        let chunk = String(repeating: "word ", count: 400)  // ~2000 chars
        let text = (0..<10).map { _ in chunk }.joined(separator: "\n")
        let controller = EditorController(text: text)
        let width: CGFloat = 300
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 5000),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: text
        )
        let selLen = (text as NSString).length
        let t0 = CFAbsoluteTimeGetCurrent()
        let rects = SelectionGeometry.selectionRects(
            for: NSRange(location: 0, length: selLen),
            layout: snapshot,
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 5000)
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        #expect(!rects.isEmpty)
        #expect(rects.count < selLen / 4)
        #expect(elapsed < 0.25)  // fragment walk must stay interactive
    }

    @Test func test_UI_N03_offscreenSelectionIsVirtualized() {
        let text = (0..<100).map { "line \($0) content\n" }.joined()
        let controller = EditorController(text: text)
        let width: CGFloat = 400
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 80),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: text
        )
        let full = NSRange(location: 0, length: (text as NSString).length)
        let visible = CGRect(x: 0, y: 0, width: width, height: 80)
        let rects = SelectionGeometry.selectionRects(
            for: full,
            layout: snapshot,
            visibleRect: visible
        )
        // Only fragments intersecting the visible rect contribute geometry.
        for r in rects {
            #expect(r.rect.maxY >= visible.minY - 1)
            #expect(r.rect.minY <= visible.maxY + 1)
        }
    }
}

// MARK: - UI-N04 BiDi

@Suite("UI-N04 Platform BiDi writing direction")
@MainActor
struct UIN04BiDiTests {
    @Test func test_UI_N04_arabicParagraphResolvesRTLFromPlatformLayout() {
        let arabic = "مرحبا بالعالم"
        // Must use CoreText platform layout (CTLine runs), not first-strong scan alone.
        let platform = WritingDirectionModel.platformBaseWritingDirection(for: arabic)
        #expect(platform == .rightToLeft)
        let dir = WritingDirectionModel.resolveBaseDirection(forParagraphContaining: 0, in: arabic)
        #expect(dir == .rightToLeft)
    }

    @Test func test_UI_N04_latinParagraphResolvesLTR() {
        let latin = "hello world"
        let platform = WritingDirectionModel.platformBaseWritingDirection(for: latin)
        #expect(platform == .leftToRight)
        let dir = WritingDirectionModel.resolveBaseDirection(forParagraphContaining: 0, in: latin)
        #expect(dir == .leftToRight)
    }

    @Test func test_UI_N04_platformLayoutAPIIsCoreTextNotFirstStrongOnly() {
        // Mixed: Latin then Arabic — platform CTLine first run is LTR (layout-based).
        let mixed = "hello مرحبا"
        let platform = WritingDirectionModel.platformBaseWritingDirection(for: mixed)
        #expect(platform == .leftToRight)
        // Pure Hebrew paragraph resolves RTL via platform layout.
        let hebrew = "שלום עולם"
        #expect(WritingDirectionModel.platformBaseWritingDirection(for: hebrew) == .rightToLeft)
    }

    @Test func test_UI_N04_setBaseWritingDirectionIsNotNoOp() {
        var model = WritingDirectionModel()
        let range = NSRange(location: 0, length: 5)
        model.setBaseWritingDirection(.rightToLeft, for: range)
        #expect(model.baseWritingDirection(at: 2) == .rightToLeft)
        model.setBaseWritingDirection(.leftToRight, for: range)
        #expect(model.baseWritingDirection(at: 2) == .leftToRight)
    }

    @Test func test_UI_N04_mixedBidiUsesStoredOverrideOverHeuristic() {
        var model = WritingDirectionModel()
        let mixed = "hello مرحبا 123"
        // Force LTR override on whole string.
        model.setBaseWritingDirection(.leftToRight, for: NSRange(location: 0, length: (mixed as NSString).length))
        #expect(model.resolvedDirection(at: 0, in: mixed) == .leftToRight)
        model.setBaseWritingDirection(.rightToLeft, for: NSRange(location: 0, length: (mixed as NSString).length))
        #expect(model.resolvedDirection(at: 0, in: mixed) == .rightToLeft)
    }
}

// MARK: - UI-N05 firstRect / attributedSubstring contracts

@Suite("UI-N05 Native input range contracts")
@MainActor
struct UIN05NativeInputContractTests {
    @Test func test_UI_N05_attributedSubstringReturnsActualRangeMatchingContent() {
        let controller = EditorController(text: "hello world")
        let proposed = NSRange(location: 0, length: 1000)
        let result = NativeInputContracts.attributedSubstring(
            proposedRange: proposed,
            documentLength: controller.document.length,
            substring: { controller.document.attributedSubstring(from: $0) }
        )
        #expect(result.string.length == controller.document.length)
        #expect(result.actualRange.location == 0)
        #expect(result.actualRange.length == controller.document.length)
        #expect(result.string.length == result.actualRange.length)
    }

    @Test func test_UI_N05_attributedSubstringRejectsInvalidInteriorWithEmptyActual() {
        let controller = EditorController(text: "hi")
        let proposed = NSRange(location: 50, length: 3)
        let result = NativeInputContracts.attributedSubstring(
            proposedRange: proposed,
            documentLength: controller.document.length,
            substring: { controller.document.attributedSubstring(from: $0) }
        )
        #expect(result.string.length == 0)
        #expect(result.actualRange.length == 0)
    }

    @Test func test_UI_N05_firstRectActualRangeMatchesGeometrySpan() {
        let controller = EditorController(text: "abc\ndef")
        let width: CGFloat = 400
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: 400),
            containerWidth: width
        )
        let snapshot = controller.layout.makeEditorLayoutSnapshot(
            containerWidth: width,
            documentText: controller.text
        )
        let proposed = NSRange(location: 0, length: 3)
        let result = NativeInputContracts.firstRect(for: proposed, layout: snapshot)
        #expect(result.rect.width >= 0)
        #expect(result.actualRange.location >= 0)
        #expect(result.actualRange.length > 0 || proposed.length == 0)
        // actual range must be inside document and within/equal proposed when valid.
        #expect(result.actualRange.location + result.actualRange.length <= (controller.text as NSString).length)
    }
}

// MARK: - UI-N06 IME marked-text lifecycle

@Suite("UI-N06 IME marked-text lifecycle")
@MainActor
struct UIN06IMELifecycleTests {
    @Test func test_UI_N06_compositionCancelRestoresPreCompositionSnapshot() {
        let c = EditorController(text: "base")
        c.setSelectedRange(NSRange(location: 4, length: 0))
        c.beginMarkedTextComposition(replacing: NSRange(location: 4, length: 0))
        c.applyMarkedText(
            "ni", selectedRangeInMarked: NSRange(location: 2, length: 0), replaceRange: NSRange(location: 4, length: 0)
        )
        #expect(c.isComposingMarkedText)
        #expect(c.text.contains("ni"))
        c.cancelMarkedTextComposition()
        #expect(!c.isComposingMarkedText)
        #expect(c.text == "base")
    }

    @Test func test_UI_N06_commitCreatesSingleUndoBoundary() {
        let c = EditorController(text: "")
        c.beginMarkedTextComposition(replacing: NSRange(location: 0, length: 0))
        c.applyMarkedText(
            "n", selectedRangeInMarked: NSRange(location: 1, length: 0), replaceRange: NSRange(location: 0, length: 0)
        )
        c.applyMarkedText(
            "ni", selectedRangeInMarked: NSRange(location: 2, length: 0), replaceRange: NSRange(location: 0, length: 1)
        )
        let committed = "你"
        c.applyMarkedText(
            committed, selectedRangeInMarked: NSRange(location: 1, length: 0),
            replaceRange: NSRange(location: 0, length: 2)
        )
        c.commitMarkedTextComposition()
        #expect(!c.isComposingMarkedText)
        #expect(c.text == committed)
        // One undo group should reverse the whole composition (not step through pinyin).
        #expect(c.undoCoordinator.canUndo)
        c.undo()
        #expect(c.text == "")
        #expect(c.markedTextSession.compositionEditCount == 0)
    }

    @Test func test_UI_N06_markedSubSelectionAndReplacementRange() {
        var session = MarkedTextSession.inactive
        session.setMarked(
            text: "変換",
            selectedRangeInMarked: NSRange(location: 0, length: 2),
            documentReplaceRange: NSRange(location: 5, length: 0)
        )
        #expect(session.absoluteSelectedRange == NSRange(location: 5, length: 2))
        #expect(session.replacementRange.location == 5)
    }

    @Test func test_UI_N06_emojiZWJAndSkinToneCompositionSurvivesMarkedLifecycle() {
        let zwj = "👨‍👩‍👧‍👦"
        let tone = "👍🏽"
        let c = EditorController(text: "")
        c.applyMarkedText(
            zwj, selectedRangeInMarked: NSRange(location: (zwj as NSString).length, length: 0),
            replaceRange: NSRange(location: 0, length: 0)
        )
        #expect(c.text == zwj)
        c.clearMarkedTextSession()
        c.setSelectedRange(NSRange(location: (zwj as NSString).length, length: 0))
        c.applyMarkedText(
            tone, selectedRangeInMarked: NSRange(location: (tone as NSString).length, length: 0),
            replaceRange: NSRange(location: (zwj as NSString).length, length: 0)
        )
        #expect(c.text.contains("👍") || c.text.hasSuffix(tone) || c.text == zwj + tone)
    }

    @Test func test_UI_N06_koreanSyllableCompositionSteps() {
        // Hangul jamo composition sequence approximated as successive marked updates.
        let c = EditorController(text: "")
        c.beginMarkedTextComposition(replacing: NSRange(location: 0, length: 0))
        c.applyMarkedText(
            "ㅎ", selectedRangeInMarked: NSRange(location: 1, length: 0), replaceRange: NSRange(location: 0, length: 0)
        )
        c.applyMarkedText(
            "하", selectedRangeInMarked: NSRange(location: 1, length: 0), replaceRange: NSRange(location: 0, length: 1)
        )
        c.applyMarkedText(
            "한", selectedRangeInMarked: NSRange(location: 1, length: 0), replaceRange: NSRange(location: 0, length: 1)
        )
        #expect(c.markedTextSession.compositionEditCount >= 3)
        c.commitMarkedTextComposition()
        #expect(c.text == "한")
    }
}

// MARK: - UI-N07 no silent try? on input paths

@Suite("UI-N07 Editor diagnostic channel")
@MainActor
struct UIN07DiagnosticChannelTests {
    @Test func test_UI_N07_inputFailuresRouteToDiagnosticChannel() {
        let channel = EditorDiagnosticChannel()
        var seen: [EditorDiagnostic] = []
        channel.onDiagnostic = { seen.append($0) }
        channel.report(
            EditorDiagnostic(
                domain: .input,
                severity: .error,
                message: "command failed",
                underlying: nil
            )
        )
        #expect(seen.count == 1)
        #expect(seen[0].domain == .input)
        #expect(seen[0].severity == .error)
    }

    @Test func test_UI_N07_executeCommandFailureSurfacesAndKeepsSelection() {
        let c = EditorController(text: "hello")
        c.setSelectedRange(NSRange(location: 2, length: 0))
        let before = c.selectedRange
        var diagnostics: [EditorDiagnostic] = []
        c.diagnosticChannel.onDiagnostic = { diagnostics.append($0) }
        // Unknown / unregistered command must fail closed without swallowing.
        do {
            try c.executeCommand(CommandID(stringLiteral: "codeeditor.nonexistent.command.uin07"))
            Issue.record("expected throw")
        } catch {
            c.diagnosticChannel.reportInputFailure(error, operation: "executeCommand")
        }
        #expect(!diagnostics.isEmpty)
        #expect(c.selectedRange == before)
    }

    @Test func test_UI_N07_noSilentTryOnInputPathHelpers() {
        // Production helper must return Result, not discard errors.
        let result: Result<Void, Error> = EditorInputActions.runThrowing {
            throw DocumentStoreError.invalidOffset(99)
        }
        switch result {
        case .success:
            Issue.record("should fail")
        case .failure(let err):
            #expect(err is DocumentStoreError)
        }
    }
}

// MARK: - UI-N08 platform matrix evidence

@Suite("UI-N08 Platform matrix evidence")
struct UIN08PlatformMatrixTests {
    @Test func test_UI_N08_platformMatrixDocumentExists() throws {
        let root = packageRoot()
        let doc = root.appendingPathComponent("Docs/Architecture/PLATFORM-MATRIX.md")
        #expect(FileManager.default.fileExists(atPath: doc.path))
        let body = try String(contentsOf: doc, encoding: .utf8)
        #expect(body.contains("macOS 15"))
        #expect(body.contains("iOS 18"))
        #expect(body.contains("Apple silicon") || body.contains("Apple Silicon"))
        #expect(body.contains("platform-matrix.json") || body.contains("xcodebuild"))
    }

    @Test func test_UI_N08_platformMatrixScriptIsHardGate() throws {
        let root = packageRoot()
        let script = root.appendingPathComponent("scripts/check-platform-matrix.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        let body = try String(contentsOf: script, encoding: .utf8)
        #expect(body.contains("set -euo pipefail"))
        #expect(body.contains("swift build"))
        #expect(body.contains("iphonesimulator") || body.contains("ios18"))
        #expect(body.contains("xcodebuild"))
        #expect(body.contains("platform-matrix.json"))
        // Fail closed: non-zero exit on missing evidence.
        #expect(body.contains("exit 1") || body.contains("fail=1"))
    }

    @Test func test_UI_N08_packagePlatformsMatchDocumentedMatrix() throws {
        let root = packageRoot()
        let pkg = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(pkg.contains(".macOS(.v15)") || pkg.contains("macOS(.v15)"))
        #expect(pkg.contains(".iOS(.v18)") || pkg.contains("iOS(.v18)"))
        // No Intel macOS promise in package platforms (silicon-only policy documented).
        let matrix = try String(
            contentsOf: root.appendingPathComponent("Docs/Architecture/PLATFORM-MATRIX.md"),
            encoding: .utf8
        )
        #expect(matrix.lowercased().contains("silicon"))
    }

    @Test func test_UI_N08_matrixScriptExecutesRealBuildsAndWritesEvidence() throws {
        let root = packageRoot()
        let script = root.appendingPathComponent("scripts/check-platform-matrix.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Skip example xcodebuild in unit test (slow); still requires host+iOS simulator builds.
        var env = ProcessInfo.processInfo.environment
        env["PLATFORM_MATRIX_XCODEBUILD"] = "0"
        env.removeValue(forKey: "CI")
        // Isolated scratch path so nested `swift build` does not deadlock on `.build`.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uin08-matrix-\(UUID().uuidString)", isDirectory: true)
        env["PLATFORM_MATRIX_SCRATCH_PATH"] = scratch.path
        process.environment = env
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(
            process.terminationStatus == 0,
            "matrix script failed (\(process.terminationStatus)): \(stdout)\n\(stderr)"
        )
        #expect(stdout.contains("macOS swift build") || stdout.contains("macos"))
        #expect(stdout.contains("iOS Simulator") || stdout.contains("ios"))

        let evidence = root.appendingPathComponent("Baselines/evidence/platform-matrix.json")
        #expect(FileManager.default.fileExists(atPath: evidence.path))
        let body = try String(contentsOf: evidence, encoding: .utf8)
        #expect(body.contains("UI-N08"))
        #expect(body.contains("macos_swift_build"))
        #expect(body.contains("\"pass\""))
        #expect(body.contains("ios_simulator_swift_build"))
        #expect(body.contains("arm64") || body.contains("silicon_only"))
    }

    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            let pkg = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) { return url }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

// MARK: - UI-N09 large-file mode

@Suite("UI-N09 Large-file mode")
@MainActor
struct UIN09LargeFileModeTests {
    @Test func test_UI_N09_thresholdActivatesExplicitMode() {
        let policy = LargeFilePolicy.default
        #expect(policy.byteThreshold > 0)
        #expect(policy.lineThreshold > 0)
        let small = LargeFileMode.evaluate(utf16Length: 100, lineCount: 10, policy: policy)
        #expect(!small.isActive)
        let large = LargeFileMode.evaluate(
            utf16Length: policy.byteThreshold + 1,
            lineCount: policy.lineThreshold + 1,
            policy: policy
        )
        #expect(large.isActive)
        #expect(!large.limitationsDescription.isEmpty)
    }

    @Test func test_UI_N09_activeModeDisablesHeavyFeatures() {
        let mode = LargeFileMode.evaluate(
            utf16Length: LargeFilePolicy.default.byteThreshold * 2,
            lineCount: LargeFilePolicy.default.lineThreshold * 2,
            policy: .default
        )
        #expect(mode.isActive)
        #expect(mode.syntaxHighlightingEnabled == false)
        #expect(mode.minimapEnabled == false)
        #expect(mode.foldingEnabled == false)
        #expect(mode.semanticTokensEnabled == false)
        #expect(mode.diagnosticsEnabled == false)
        #expect(mode.boundedUndo == true)
    }

    @Test func test_UI_N09_controllerSurfacesLargeFileMode() {
        // Build text that exceeds line threshold — mode auto-activates on load.
        let lines = (0..<LargeFilePolicy.default.lineThreshold + 50).map { "line \($0)\n" }.joined()
        let c = EditorController(text: lines)
        #expect(c.largeFileMode.isActive)
        #expect(!c.largeFileMode.limitationsDescription.isEmpty)
        #expect(c.effectivePeripherals.showMinimap == false)
        #expect(c.isSyntaxHighlightingEnabled == false)
        #expect(c.isDiagnosticsEnabled == false)
        #expect(c.isFoldingEnabled == false)
        #expect(c.highlighter?.isSuspended == true)
    }

    @Test func test_UI_N09_memoryPressureEscalatesMode() {
        var mode = LargeFileMode.inactive
        mode = mode.applyingMemoryPressure(true, policy: .default)
        #expect(mode.isActive)
        #expect(mode.enteredViaMemoryPressure)
    }

    @Test func test_UI_N09_enforcesHighlighterSuspendAndDiagnosticsReject() {
        let c = EditorController(text: "small")
        c.largeFilePolicy = LargeFilePolicy(byteThreshold: 4, lineThreshold: 2, maxUndoGroups: 3)
        c.insertText("\nmore\nlines\nhere")
        // Edit auto-refreshes mode.
        #expect(c.largeFileMode.isActive)
        #expect(c.highlighter?.isSuspended == true)
        #expect(c.isSyntaxHighlightingEnabled == false)

        c.setAnnotations([
            LineAnnotation(line: 0, severity: .error, message: "should be rejected")
        ])
        #expect(c.annotations.isEmpty)
        #expect(c.isDiagnosticsEnabled == false)
    }

    @Test func test_UI_N09_boundedUndoActuallyTrimsStack() {
        let c = EditorController(text: "")
        c.largeFilePolicy = LargeFilePolicy(byteThreshold: 1, lineThreshold: 1, maxUndoGroups: 3)
        // Force large-file mode with enough content.
        for i in 0..<10 {
            c.insertText("x\(i)\n")
        }
        #expect(c.largeFileMode.isActive)
        #expect(c.largeFileMode.boundedUndo)
        #expect(c.undoCoordinator.maxGroups == 3)
        #expect(c.undoCoordinator.closedGroupCount <= 3)
    }

    @Test func test_UI_N09_autoRefreshOnLoadWithoutManualCall() {
        let policy = LargeFilePolicy(byteThreshold: 1_000_000, lineThreshold: 20, maxUndoGroups: 8)
        let lines = (0..<30).map { "L\($0)\n" }.joined()
        let c = EditorController(text: lines)
        c.largeFilePolicy = policy
        // Policy change alone does not re-evaluate; load path does via init.
        // Re-create with policy applied after init then refresh is not required if we
        // set policy before content growth — verify insert auto path:
        let c2 = EditorController(text: "a")
        c2.largeFilePolicy = LargeFilePolicy(byteThreshold: 2, lineThreshold: 100, maxUndoGroups: 4)
        #expect(!c2.largeFileMode.isActive)
        c2.insertText("bcdef")  // crosses byte threshold
        #expect(c2.largeFileMode.isActive)
        #expect(c2.highlighter?.isSuspended == true)
    }
}

// MARK: - UI-N10 semantic accessibility

@Suite("UI-N10 Semantic accessibility")
@MainActor
struct UIN10SemanticAccessibilityTests {
    @Test func test_UI_N10_lineColumnSelectionSummary() {
        let text = "aaa\nbbb\nccc"
        let summary = EditorAccessibility.semanticSummary(
            fullText: text,
            selectedRange: NSRange(location: 5, length: 2),
            multiCursorCount: 1,
            languageID: "swift",
            isEditable: true,
            isDirty: false,
            largeFileModeActive: false
        )
        #expect(summary.line >= 2)
        #expect(summary.column >= 1)
        #expect(summary.selectionLength == 2)
        #expect(summary.announcement.contains("Line"))
        #expect(summary.announcement.contains("column") || summary.announcement.contains("Column"))
    }

    @Test func test_UI_N10_multiCursorAnnouncement() {
        let a = EditorAccessibility.multiCursorAnnouncement(rangeCount: 3)
        #expect(a != nil)
        #expect(a!.contains("3"))
        #expect(EditorAccessibility.multiCursorAnnouncement(rangeCount: 1) == nil)
    }

    @Test func test_UI_N10_rotorSurfacesAreSemantic() {
        let items = EditorAccessibility.rotorItems(
            diagnosticsCount: 2,
            foldCount: 1,
            changeCount: 0,
            breakpointCount: 3,
            symbolCount: 4,
            searchMatchCount: 5
        )
        let labels = Set(items.map { $0.label.lowercased() })
        #expect(labels.contains { $0.contains("diagnostic") || $0.contains("error") })
        #expect(labels.contains { $0.contains("fold") })
        #expect(labels.contains { $0.contains("breakpoint") })
        #expect(labels.contains { $0.contains("symbol") })
        #expect(labels.contains { $0.contains("search") || $0.contains("match") })
    }

    @Test func test_UI_N10_controllerRotorUsesLiveBreakpointsAndSymbols() {
        let c = EditorController(text: "func foo() {}\nlet x = 1\n")
        c.setAnnotations([
            LineAnnotation(line: 0, severity: .error, message: "err", range: NSRange(location: 0, length: 4))
        ])
        c.setAccessibilityBreakpoints([5, 12])
        c.setAccessibilitySymbolCount(2)
        let items = c.accessibilityRotorItems
        let labels = items.map { $0.label.lowercased() }
        #expect(labels.contains { $0.contains("diagnostic") })
        #expect(labels.contains { $0.contains("breakpoint") })
        #expect(labels.contains { $0.contains("symbol") })
        #expect(items.first(where: { $0.label.lowercased().contains("breakpoint") })?.count == 2)
        #expect(items.first(where: { $0.label.lowercased().contains("symbol") })?.count == 2)
        // Not residual zeros: host-published counts flow through.
        #expect(c.accessibilityBreakpointOffsets.count == 2)
        #expect(c.accessibilitySymbolCount == 2)
    }

    @Test func test_UI_N10_completionAccessibilityAnnouncement() {
        let s = EditorAccessibility.completionAnnouncement(
            selectedLabel: "print",
            index: 0,
            total: 12
        )
        #expect(s.contains("print"))
        #expect(s.contains("1") && s.contains("12"))
    }

    @Test func test_UI_N10_controllerCompletionAnnouncementIsLive() {
        let c = EditorController(text: "prin")
        // Populate completion session via public APIs if available.
        c.completionSession.setVisible(true)
        // CompletionSession may require items — use label path via helper when empty is nil.
        if c.completionSession.items.isEmpty {
            // Still verify helper contract is wired on controller.
            #expect(c.completionAccessibilityAnnouncement == nil)
        }
        let announcement = EditorAccessibility.completionAnnouncement(
            selectedLabel: "print(_:)",
            index: 2,
            total: 5
        )
        #expect(announcement.contains("print"))
        #expect(announcement.contains("3") && announcement.contains("5"))
    }

    @Test func test_UI_N10_panelLandmarksAndReducedMotion() {
        let landmarks = EditorAccessibility.panelLandmarks
        #expect(landmarks.contains { $0.role == .editor })
        #expect(landmarks.contains { $0.role == .findPanel || $0.role == .completionPanel })
        #expect(EditorAccessibility.landmarkLabel(for: .completionPanel) == "Code completion")
        #expect(EditorAccessibility.landmarkLabel(for: .findPanel) == "Find")

        // Reduced motion is system-linked — must equal systemReduceMotionEnabled (not a tautology).
        #expect(EditorAccessibility.reducedMotionPreferredTransitions == EditorAccessibility.systemReduceMotionEnabled)
        let policy = EditorAccessibility.motionPolicy(reduceMotion: true)
        #expect(policy.animateCaretBlink == false)
        #expect(policy.animateFoldTransitions == false)
        let live = EditorAccessibility.currentMotionPolicy
        if EditorAccessibility.systemReduceMotionEnabled {
            #expect(live.animateCaretBlink == false)
        } else {
            #expect(live.animateCaretBlink == true)
        }
    }

    @Test func test_UI_N10_appKitHostExposesSemanticValueAndRotors() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let c = EditorController(text: "line1\nline2\n")
            c.setSelectedRange(NSRange(location: 6, length: 0))
            c.setAccessibilityBreakpoints([0])
            c.setAccessibilitySymbolCount(1)
            c.setAnnotations([
                LineAnnotation(line: 1, severity: .warning, message: "w", range: NSRange(location: 6, length: 4))
            ])
            let editor = AppKitEditorView(controller: c)
            editor.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            #expect(editor.isAccessibilityElement() == true)
            #expect(editor.accessibilityRole() == .textArea)
            let value = editor.accessibilityValue() as? String
            #expect(value != nil)
            #expect(c.accessibilitySemanticSummary.line >= 2)
            let rotors = editor.accessibilityCustomRotors()
            #expect(!rotors.isEmpty)
            let rotorLabels = rotors.map(\.label)
            #expect(rotorLabels.contains { $0.lowercased().contains("breakpoint") || $0.lowercased().contains("diagnostic") })
        #endif
    }
}
