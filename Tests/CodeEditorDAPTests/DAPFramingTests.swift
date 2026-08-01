import Foundation
import Testing
import CodeEditorDAP

@Suite("CodeEditorDAP framing")
struct DAPFramingTests {
    @Test func encodeDecodeRoundTrip() {
        let body = Data(#"{"seq":1,"type":"request","command":"initialize"}"#.utf8)
        let framed = DAPMessageFraming.encode(body)
        let decoder = DAPMessageFraming.Decoder()
        let messages = decoder.append(framed)
        #expect(messages.count == 1)
        #expect(messages[0] == body)
    }

    @Test func bodyTooLargeRejected() {
        let decoder = DAPMessageFraming.Decoder(maxBodyBytes: 8, maxBufferBytes: 64)
        let huge = Data("Content-Length: 100\r\n\r\n".utf8) + Data(repeating: 0x41, count: 20)
        _ = decoder.append(huge)
        #expect(decoder.lastError == .bodyTooLarge(100))
    }

    @Test func emptyCapabilities() {
        let caps = DAPCapabilities.empty
        #expect(!caps.supportsSetVariable)
        #expect(!caps.supportsDisassembleRequest)
    }
}
