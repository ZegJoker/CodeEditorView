import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol

/// Cooperative guest implementing core-Wasm ABI export semantics in Swift.
public final class WasmGuestRuntime: @unchecked Sendable {
    public var memory = Data(count: 64 * 1024)
    private var heapPtr = 2048
    private var started = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var schemaHash: String = ""
    private var inboundData: [Data] = []
    private var work: [(id: ExtensionRequestID, method: ExtensionMethodID, payload: Data, cost: Int)] = []

    public var hostSend: ((Data) -> Int32)?
    public var hostLog: ((Int32, String) -> Void)?
    public var hostMillis: (() -> Int64)?
    public var hostShouldCancel: ((Int64, Int64) -> Int32)?

    public var pendingSlowWork: Int = 0
    public private(set) var completedSlowWork: Int = 0
    public private(set) var cancelledSlowWork: Bool = false

    /// Optional method handlers (Phase 13+). When unset, methods return method-not-found error JSON — never canned success.
    public var methodHandlers: [ExtensionMethodID: @Sendable (Data) -> Data] = [:]

    public init() {}

    public func setHandler(for method: ExtensionMethodID, handler: @escaping @Sendable (Data) -> Data) {
        methodHandlers[method] = handler
    }

    public func abiVersion() -> Int32 { 1 }

    public func alloc(_ length: Int32) -> Int32 {
        let len = max(0, Int(length))
        if heapPtr + len > memory.count {
            memory.append(Data(count: len + 4096))
        }
        let p = heapPtr
        heapPtr += len
        return Int32(p)
    }

    public func dealloc(_ ptr: Int32, _ length: Int32) {
        _ = ptr; _ = length
    }

    public func start(configPtr: Int32, configLen: Int32) -> Int32 {
        guard !stopped else { return 1 }
        guard let data = try? read(ptr: Int(configPtr), len: Int(configLen)) else { return 1 }
        if let map = try? CBORCodec.decode(data).stringMap {
            schemaHash = map["schema"]?.stringValue ?? ""
            if case .unsigned(let g) = map["generation"] {
                generation = g
            } else if let g = map["generation"]?.intValue {
                generation = UInt64(g)
            }
        }
        if !schemaHash.isEmpty && schemaHash != ExtensionMethodCatalog.schemaHash {
            return 1
        }
        started = true
        hostLog?(1, "wasm guest started")
        return 0
    }

    public func receive(ptr: Int32, len: Int32) -> Int32 {
        guard started, !stopped else { return 1 }
        guard let data = try? read(ptr: Int(ptr), len: Int(len)) else { return 1 }
        inboundData.append(data)
        return 0
    }

    public func poll(_ budget: Int32) -> Int32 {
        guard started, !stopped else { return 1 }
        var remaining = Int(max(0, budget))

        while remaining > 0, !inboundData.isEmpty {
            let data = inboundData.removeFirst()
            remaining -= 1
            ingest(data)
        }

        while remaining > 0, pendingSlowWork > 0 {
            if hostShouldCancel?(0, Int64(pendingSlowWork)) != 0 {
                cancelledSlowWork = true
                pendingSlowWork = 0
                return 3
            }
            pendingSlowWork -= 1
            completedSlowWork += 1
            remaining -= 1
        }

        while remaining > 0, !work.isEmpty {
            var item = work.removeFirst()
            remaining -= 1
            if item.cost > 1 {
                item.cost -= 1
                work.insert(item, at: 0)
                continue
            }
            let out = dispatch(method: item.method, payload: item.payload)
            let env = ExtensionEnvelope.response(
                id: item.id,
                result: out,
                error: nil,
                generation: generation
            )
            if let encoded = try? ExtensionEnvelopeCodec.encode(env) {
                _ = hostSend?(encoded)
            }
        }

        let busy = !inboundData.isEmpty || !work.isEmpty || pendingSlowWork > 0
        return busy ? 2 : 0
    }

    public func stop(_ reason: Int32) {
        stopped = true
        inboundData.removeAll()
        work.removeAll()
        hostLog?(1, "stop \(reason)")
    }

    public func writeToMemory(_ data: Data, at ptr: Int) throws {
        guard ptr >= 0 else { throw WasmGuestError.outOfBounds }
        if ptr + data.count > memory.count {
            memory.append(Data(count: ptr + data.count - memory.count + 1024))
        }
        memory.replaceSubrange(ptr..<(ptr + data.count), with: data)
    }

    public func read(ptr: Int, len: Int) throws -> Data {
        guard ptr >= 0, len >= 0, ptr + len <= memory.count else {
            throw WasmGuestError.outOfBounds
        }
        return memory.subdata(in: ptr..<(ptr + len))
    }

    private func ingest(_ data: Data) {
        guard let env = try? ExtensionEnvelopeCodec.decode(data) else { return }
        switch env {
        case .request(let id, let method, let payload, _, let gen):
            if generation != 0 && gen != 0 && gen != generation {
                let err = ExtensionWireError(code: -32009, message: "stale generation")
                if let encoded = try? ExtensionEnvelopeCodec.encode(
                    .response(id: id, result: nil, error: err, generation: generation)
                ) {
                    _ = hostSend?(encoded)
                }
                return
            }
            let cost = (method == .echo || method == .ping) ? 1 : 2
            work.append((id, method, payload, cost))
        case .cancel(let id):
            work.removeAll { $0.id == id }
        case .ping:
            if let encoded = try? ExtensionEnvelopeCodec.encode(.pong) {
                _ = hostSend?(encoded)
            }
        default:
            break
        }
    }

    private func dispatch(method: ExtensionMethodID, payload: Data) -> Data {
        switch method {
        case .ping:
            return Data(#"{"ok":true}"#.utf8)
        case .activate, .deactivate:
            return Data()
        case .echo:
            return payload
        case .completion:
            return Data(#"{"items":[{"label":"conformanceHello","kind":"function","insertText":"conformanceHello()"}]}"#.utf8)
        case .hover:
            return Data(#"{"sections":[{"content":{"markdown":"**conformance** hover"}}]}"#.utf8)
        case .definition:
            return Data("[]".utf8)
        case .lsResolveLaunchPlan:
            // Codable LanguageServerLaunchPlan shape (matches host JSONDecoder).
            let plan: [String: Any] = [
                "serverID": "mock-ls",
                "displayName": "Mock LS",
                "languages": ["swift"],
                "command": "mock-ls",
                "arguments": [] as [String],
                "environment": [:] as [String: String],
                "transport": "stdio",
                "binarySource": [
                    "testFactory": ["id": "mock-ls-factory"],
                ],
            ]
            // Prefer Swift Codable encode when available via JSON that decoder accepts.
            // LanguageServerBinarySource uses auto-synthesized keyed enum encoding.
            struct WirePlan: Encodable {
                var serverID: String
                var displayName: String
                var languages: [String]
                var command: String
                var arguments: [String]
                var environment: [String: String]
                var transport: String
                var binarySource: WireSource
                enum WireSource: Encodable {
                    case testFactory(id: String)
                }
            }
            let wp = WirePlan(
                serverID: "mock-ls",
                displayName: "Mock LS",
                languages: ["swift"],
                command: "mock-ls",
                arguments: [],
                environment: [:],
                transport: "stdio",
                binarySource: .testFactory(id: "mock-ls-factory")
            )
            if let data = try? JSONEncoder().encode(wp) {
                return data
            }
            return (try? JSONSerialization.data(withJSONObject: plan)) ?? Data()
        case .lsInitializationOptions:
            return Data(#"{"fixture":true}"#.utf8)
        case .lsWorkspaceConfiguration:
            return Data(#"[{"section":"mock","value":"from-extension"}]"#.utf8)
        case .lsTransformCompletionLabel:
            // Expect JSON {"label":"..."}; prefix with ext:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let label = obj["label"] as? String
            {
                var out = obj
                out["label"] = label.hasPrefix("ext:") ? label : "ext:" + label
                return (try? JSONSerialization.data(withJSONObject: out)) ?? payload
            }
            return payload
        case .lsTransformSymbolLabel:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let name = obj["name"] as? String
            {
                var out = obj
                out["name"] = name.hasPrefix("ext:") ? name : "ext:" + name
                return (try? JSONSerialization.data(withJSONObject: out)) ?? payload
            }
            return payload
        case .lsStatus:
            return Data(#"{"state":"running","serverID":"mock-ls"}"#.utf8)
        case .lsRestart:
            return Data(#"{"ok":true}"#.utf8)
        case .dapResolveLaunchPlan, .dapResolveConfigurations, .dapLocate, .dapStatus, .dapRestart,
             .mcpResolveLaunchPlan, .mcpStatus, .mcpRestart,
             .slashExecute, .docsSuggest, .docsBuildIndex, .docsInvalidate:
            if let handler = methodHandlers[method] {
                return handler(payload)
            }
            // Honest failure — never canned success for Phase 13 surfaces.
            return Data(#"{"error":{"code":-32601,"message":"Method not found: handler not registered"}}"#.utf8)
        default:
            return Data()
        }
    }
}

public enum WasmGuestError: Error, Sendable {
    case outOfBounds
}
