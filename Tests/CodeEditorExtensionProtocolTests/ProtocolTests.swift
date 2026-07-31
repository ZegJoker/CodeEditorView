import Foundation
import Testing
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol

@Suite("CBOR codec")
struct CBORCodecTests {
    @Test func roundTripScalarsAndContainers() throws {
        let value = CBORValue.stringMap([
            "s": .text("hello"),
            "n": .int(42),
            "neg": .int(-5),
            "b": .bool(true),
            "z": .null,
            "bytes": .bytes(Data([1, 2, 3])),
            "arr": .array([.int(1), .text("x")]),
        ])
        let data = CBORCodec.encode(value)
        let decoded = try CBORCodec.decode(data)
        #expect(decoded.stringMap?["s"]?.stringValue == "hello")
        #expect(decoded.stringMap?["n"]?.intValue == 42)
        #expect(decoded.stringMap?["neg"]?.intValue == -5)
        #expect(decoded.stringMap?["b"]?.boolValue == true)
        #expect(decoded.stringMap?["bytes"]?.dataValue == Data([1, 2, 3]))
    }

    @Test func rejectsTruncated() {
        #expect(throws: CBORError.self) {
            try CBORCodec.decode(Data([0x45, 0x61])) // text length 5 but short
        }
    }
}

@Suite("CBOR framing")
struct CBORFramingTests {
    @Test func frameRoundTripSplit() throws {
        let body = try ExtensionEnvelopeCodec.encode(.ping)
        let framed = try CBORFraming.encode(body)
        // Split mid-frame
        let mid = framed.count / 2
        let decoder = CBORFraming.Decoder()
        let a = try decoder.append(framed.prefix(mid))
        #expect(a.isEmpty)
        let b = try decoder.append(framed.suffix(from: mid))
        #expect(b.count == 1)
        let env = try ExtensionEnvelopeCodec.decode(b[0])
        #expect(env == .ping)
    }

    @Test func oversizedFrameRejected() {
        let body = Data(repeating: 0x41, count: 100)
        #expect(throws: ExtensionWireError.self) {
            try CBORFraming.encode(body, maxFrameBytes: 10)
        }
    }
}

@Suite("Envelope + catalog")
struct EnvelopeCatalogTests {
    @Test func handshakeRoundTrip() throws {
        let h = ExtensionWireHandshake(
            packageID: "com.example",
            packageVersion: "1.0.0",
            displayName: "Example",
            capabilities: ["themes"],
            permissions: ["readWorkspace"]
        )
        let data = try ExtensionEnvelopeCodec.encode(.handshake(h))
        let decoded = try ExtensionEnvelopeCodec.decode(data)
        if case .handshake(let hh) = decoded {
            #expect(hh.packageID == "com.example")
            #expect(hh.schemaHash == ExtensionMethodCatalog.schemaHash)
        } else {
            Issue.record("expected handshake")
        }
    }

    @Test func schemaHashStable() {
        #expect(ExtensionMethodCatalog.schemaHash.count == 64)
        #expect(ExtensionMethodCatalog.contains(.completion))
        #expect(ExtensionMethodCatalog.contains(.processSpawn))
    }

    @Test func requestResponseCancel() throws {
        let id = ExtensionRequestID()
        let req = ExtensionEnvelope.request(
            id: id,
            method: .echo,
            payload: Data("hi".utf8),
            timeoutMS: 1000,
            generation: 3
        )
        let r1 = try ExtensionEnvelopeCodec.decode(try ExtensionEnvelopeCodec.encode(req))
        if case .request(let rid, let m, let p, _, let g) = r1 {
            #expect(rid == id)
            #expect(m == .echo)
            #expect(p == Data("hi".utf8))
            #expect(g == 3)
        } else {
            Issue.record("request")
        }
        let cancel = try ExtensionEnvelopeCodec.decode(try ExtensionEnvelopeCodec.encode(.cancel(id: id)))
        if case .cancel(let cid) = cancel {
            #expect(cid == id)
        }
    }
}

@Suite("Wire connection")
struct WireConnectionTests {
    @Test func requestResponseOverMock() async throws {
        let pair = MockWireTransport.makePair()
        let host = ExtensionWireConnection(transport: pair.host)
        let guest = ExtensionWireConnection(transport: pair.remote)
        await host.start()
        await guest.start()
        await guest.setEnvelopeHandler { envelope in
            if case .request(let id, let method, let payload, _, let gen) = envelope {
                #expect(method == .echo)
                try? await guest.send(.response(id: id, result: payload, error: nil, generation: gen))
            }
        }
        let result = try await host.request(.echo, payload: Data("xyz".utf8))
        #expect(result == Data("xyz".utf8))
        await host.close()
        await guest.close()
    }

    @Test func cancelMarksRequestCancelled() async throws {
        let pair = MockWireTransport.makePair()
        let host = ExtensionWireConnection(transport: pair.host, defaultTimeout: .seconds(1))
        await host.start()
        let id = ExtensionRequestID()
        await host.cancel(id: id)
        #expect(await host.isCancelled(id))
        await host.close()
        await pair.remote.close()
    }

    @Test func streamBackpressure() async throws {
        let pair = MockWireTransport.makePair()
        let host = ExtensionWireConnection(transport: pair.host, streamWindow: 1)
        await host.start()
        let id = ExtensionRequestID()
        try await host.openStream(id: id, streamID: "s1")
        try await host.sendStreamChunk(streamID: "s1", sequence: 0, data: Data([1]), fin: false)
        // Window exhausted
        do {
            try await host.sendStreamChunk(streamID: "s1", sequence: 1, data: Data([2]), fin: true)
            Issue.record("expected backpressure")
        } catch let err as ExtensionWireError {
            #expect(err.code == -32010)
        }
        await host.close()
        await pair.remote.close()
    }
}
