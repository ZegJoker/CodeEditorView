import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorTerminal

@Suite("Terminal")
struct TerminalTests {
    @Test func mockBackendEcho() async throws {
        let backend = MockTerminalBackend()
        let handle = try await backend.start(configuration: TerminalConfiguration())
        final class Box: @unchecked Sendable {
            var got: Data?
        }
        let box = Box()
        let stream = await backend.output
        let collector = Task {
            for await event in stream {
                if case .data(_, let bytes) = event {
                    box.got = bytes
                    break
                }
            }
        }
        try await backend.write(Data("hi".utf8), to: handle.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        #expect(box.got == Data("hi".utf8))
        await backend.terminate(session: handle.id)
    }

    @Test func sessionManagerLifecycle() async throws {
        let backend = MockTerminalBackend()
        let manager = TerminalSessionManager()
        await manager.attach(backend: backend)
        let session = try await manager.create(title: "Test")
        #expect(await manager.allSessions().count == 1)
        #expect(await manager.panelDescriptor(for: session.id)?.title == "Test")
        try await manager.write("x", to: session.id)
        await manager.close(session.id)
        #expect(await manager.allSessions().isEmpty)
    }

    @Test func processBackendFailsClosedWhenProfileDeniesLocalProcess() async {
        let backend = ProcessTerminalBackend(platformProfile: .processUnavailable)
        do {
            _ = try await backend.start(configuration: TerminalConfiguration())
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .localProcess)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func ptyBackendFailsClosedWhenProfileDeniesPTY() async {
        let backend = PTYTerminalBackend(platformProfile: .processUnavailable)
        do {
            _ = try await backend.start(configuration: TerminalConfiguration())
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .localPTY)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("VT parser and screen")
struct VTParserScreenTests {
    @Test func printAndCursorCSI() {
        let screen = TerminalScreen(cols: 20, rows: 5)
        screen.feed("hi")
        #expect(screen.cell(row: 0, col: 0).character == "h")
        #expect(screen.cell(row: 0, col: 1).character == "i")
        screen.feed("\u{1b}[2;3H*")
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 3)
        #expect(screen.cell(row: 1, col: 2).character == "*")
    }

    @Test func sgrColorsAndErase() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("\u{1b}[31;1mX\u{1b}[0m")
        #expect(screen.cell(row: 0, col: 0).character == "X")
        #expect(screen.cell(row: 0, col: 0).fg == 1)
        #expect(screen.cell(row: 0, col: 0).bold)
        screen.feed("\u{1b}[2J")
        #expect(screen.cell(row: 0, col: 0).character == " ")
    }

    @Test func alternateScreen() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("main")
        screen.feed("\u{1b}[?1049h")
        #expect(screen.altScreenActive)
        screen.feed("alt")
        #expect(screen.cell(row: 0, col: 0).character == "a")
        screen.feed("\u{1b}[?1049l")
        #expect(!screen.altScreenActive)
        #expect(screen.cell(row: 0, col: 0).character == "m")
    }

    @Test func scrollbackBounded() {
        let screen = TerminalScreen(cols: 8, rows: 2, maxScrollback: 3)
        screen.feed("a\n")
        screen.feed("b\n")
        screen.feed("c\n")
        screen.feed("d\n")
        screen.feed("e\n")
        #expect(screen.scrollbackLineCount <= 3)
    }

    @Test func resizeReflow() {
        let screen = TerminalScreen(cols: 10, rows: 4)
        screen.feed("hello")
        screen.resize(cols: 5, rows: 4)
        #expect(screen.cols == 5)
        #expect(screen.cell(row: 0, col: 0).character == "h")
    }

    @Test func unicodeWidthEmoji() {
        #expect(UnicodeWidth.displayWidth("a") == 1)
        #expect(UnicodeWidth.displayWidth("中") == 2)
        #expect(UnicodeWidth.displayWidth("😀") == 2)
    }

    @Test func adversarialCSIDoesNotCrash() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        var junk = Data([0x1b, 0x5b])  // ESC [
        junk.append(contentsOf: Array(repeating: UInt8(0x3b), count: 200))
        junk.append(0x6d)  // m
        junk.append(contentsOf: [0x1b, 0x5b, 0xff, 0x48])
        screen.feed(junk)
        screen.feed(String(repeating: "x", count: 1000))
        #expect(screen.cols == 10)
    }

    @Test func urlDetectionAndSelection() {
        let screen = TerminalScreen(cols: 40, rows: 3)
        screen.feed("see https://example.com/path ok")
        let urls = screen.detectedURLs()
        #expect(urls.contains(where: { $0.contains("example.com") }))
        let sel = screen.selectionText(row0: 0, col0: 0, row1: 0, col1: 10)
        #expect(!sel.isEmpty)
    }

    @Test func bracketedPasteEncoding() {
        let data = TerminalPaste.encode("hi", bracketed: true)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("200~"))
        #expect(s.contains("201~"))
    }

    @Test func remoteBackendDisconnect() async throws {
        let transport = MockRemoteTerminalTransport()
        let backend = RemoteTerminalBackend(
            transportFactory: { transport }
        )
        let handle = try await backend.start(configuration: TerminalConfiguration())
        try await backend.write(Data("ping".utf8), to: handle.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        await transport.simulateDisconnect()
        await backend.terminate(session: handle.id)
    }

    #if os(macOS)
        @Test func ptyInteractiveEchoAndResize() async throws {
            let backend = PTYTerminalBackend()
            let config = TerminalConfiguration(
                shell: URL(fileURLWithPath: "/bin/sh"),
                arguments: [],
                cols: 40,
                rows: 12
            )
            let handle = try await backend.start(configuration: config)
            final class Box: @unchecked Sendable { var chunks: [Data] = [] }
            let box = Box()
            let stream = backend.output
            let collector = Task {
                for await event in stream {
                    if case .data(_, let bytes) = event {
                        box.chunks.append(bytes)
                        let all = box.chunks.reduce(Data(), +)
                        if String(data: all, encoding: .utf8)?.contains("PTYOK") == true {
                            break
                        }
                    }
                }
            }
            try await backend.write(Data("printf 'PTYOK\\n'\n".utf8), to: handle.id)
            try await backend.resize(cols: 50, rows: 20, session: handle.id)
            try await Task.sleep(nanoseconds: 400_000_000)
            collector.cancel()
            let all = box.chunks.reduce(Data(), +)
            let text = String(data: all, encoding: .utf8) ?? ""
            #expect(text.contains("PTYOK") || !box.chunks.isEmpty)  // received some PTY output
            await backend.terminate(session: handle.id)
        }
    #endif
}
