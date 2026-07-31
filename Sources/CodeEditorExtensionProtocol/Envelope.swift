import Foundation
import CodeEditorExtensionAPI

public struct ExtensionWireProtocolVersion: Hashable, Codable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    public static let current = ExtensionWireProtocolVersion(
        major: ExtensionMethodCatalog.protocolMajor,
        minor: ExtensionMethodCatalog.protocolMinor
    )

    public func isCompatible(with peer: ExtensionWireProtocolVersion) -> Bool {
        major == peer.major
    }
}

public struct ExtensionRequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct ExtensionWireError: Error, Sendable, Equatable, Codable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let methodNotFound = ExtensionWireError(code: -32601, message: "Method not found")
    public static let timeout = ExtensionWireError(code: -32000, message: "Timeout")
    public static let payloadTooLarge = ExtensionWireError(code: -32001, message: "Payload too large")
    public static let incompatibleProtocol = ExtensionWireError(code: -32002, message: "Incompatible protocol")
    public static let cancelled = ExtensionWireError(code: -32800, message: "Cancelled")
    public static let permissionDenied = ExtensionWireError(code: -32003, message: "Permission denied")
    public static let forgedHandle = ExtensionWireError(code: -32004, message: "Forged or stale handle")
    public static let quarantined = ExtensionWireError(code: -32005, message: "Extension quarantined")
    public static let schemaMismatch = ExtensionWireError(code: -32006, message: "Schema hash mismatch")
    public static let untrustedPackage = ExtensionWireError(code: -32007, message: "Untrusted native package")
    public static let transportClosed = ExtensionWireError(code: -32008, message: "Transport closed")
}

public struct ExtensionHostLimits: Hashable, Codable, Sendable {
    public var maxPayloadBytes: Int
    public var maxFrameBytes: Int
    public var streamWindow: Int
    public var maxConcurrentRequests: Int
    public var requestTimeoutMS: Int

    public init(
        maxPayloadBytes: Int = 4 * 1024 * 1024,
        maxFrameBytes: Int = 4 * 1024 * 1024,
        streamWindow: Int = 8,
        maxConcurrentRequests: Int = 32,
        requestTimeoutMS: Int = 15_000
    ) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxFrameBytes = maxFrameBytes
        self.streamWindow = streamWindow
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestTimeoutMS = requestTimeoutMS
    }

    public static let `default` = ExtensionHostLimits()
}

public struct ExtensionWireHandshake: Sendable, Hashable {
    public var protocolVersion: ExtensionWireProtocolVersion
    public var schemaHash: String
    public var apiVersion: String
    public var packageID: String
    public var packageVersion: String
    public var packageDigest: String?
    public var displayName: String
    public var capabilities: [String]
    public var permissions: [String]
    public var runtimeKind: String
    public var platform: String
    public var arch: String
    public var processID: Int32?

    public init(
        protocolVersion: ExtensionWireProtocolVersion = .current,
        schemaHash: String = ExtensionMethodCatalog.schemaHash,
        apiVersion: String = "\(SemanticVersion.phase9API)",
        packageID: String,
        packageVersion: String,
        packageDigest: String? = nil,
        displayName: String,
        capabilities: [String] = [],
        permissions: [String] = [],
        runtimeKind: String = "native-process",
        platform: String = "macOS",
        arch: String = "arm64",
        processID: Int32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.schemaHash = schemaHash
        self.apiVersion = apiVersion
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.packageDigest = packageDigest
        self.displayName = displayName
        self.capabilities = capabilities
        self.permissions = permissions
        self.runtimeKind = runtimeKind
        self.platform = platform
        self.arch = arch
        self.processID = processID
    }

    public init(manifest: ExtensionManifest, runtimeKind: String = "native-process", packageDigest: String? = nil) {
        self.init(
            apiVersion: "\(manifest.requiredAPIVersion.min)",
            packageID: manifest.id.rawValue,
            packageVersion: "\(manifest.version)",
            packageDigest: packageDigest,
            displayName: manifest.displayName,
            capabilities: manifest.requiredHostCapabilities.map(\.rawValue).sorted(),
            permissions: manifest.requestedPermissions.map(\.rawValue).sorted(),
            runtimeKind: runtimeKind,
            processID: ProcessInfo.processInfo.processIdentifier
        )
    }
}

public struct ExtensionWireHandshakeResult: Sendable, Hashable {
    public var accepted: Bool
    public var protocolVersion: ExtensionWireProtocolVersion
    public var schemaHash: String
    public var hostCapabilities: [String]
    public var grantedPermissions: [String]
    public var limits: ExtensionHostLimits
    public var generation: UInt64
    public var rejectReason: String?

    public init(
        accepted: Bool,
        protocolVersion: ExtensionWireProtocolVersion = .current,
        schemaHash: String = ExtensionMethodCatalog.schemaHash,
        hostCapabilities: [String] = [],
        grantedPermissions: [String] = [],
        limits: ExtensionHostLimits = .default,
        generation: UInt64 = 1,
        rejectReason: String? = nil
    ) {
        self.accepted = accepted
        self.protocolVersion = protocolVersion
        self.schemaHash = schemaHash
        self.hostCapabilities = hostCapabilities
        self.grantedPermissions = grantedPermissions
        self.limits = limits
        self.generation = generation
        self.rejectReason = rejectReason
    }
}

public enum ExtensionEnvelope: Sendable, Equatable {
    case handshake(ExtensionWireHandshake)
    case handshakeResult(ExtensionWireHandshakeResult)
    case request(id: ExtensionRequestID, method: ExtensionMethodID, payload: Data, timeoutMS: Int, generation: UInt64)
    case response(id: ExtensionRequestID, result: Data?, error: ExtensionWireError?, generation: UInt64)
    case cancel(id: ExtensionRequestID)
    case progress(id: ExtensionRequestID, percent: Int?, message: String?)
    case streamOpen(id: ExtensionRequestID, streamID: String, window: Int)
    case streamChunk(streamID: String, sequence: UInt64, data: Data, fin: Bool)
    case streamClose(streamID: String, error: ExtensionWireError?)
    case notification(kind: String, payload: Data)
    case ping
    case pong
}

// MARK: - CBOR mapping

public enum ExtensionEnvelopeCodec {
    public static func encode(_ envelope: ExtensionEnvelope) throws -> Data {
        CBORCodec.encode(toCBOR(envelope))
    }

    public static func decode(_ data: Data) throws -> ExtensionEnvelope {
        let value = try CBORCodec.decode(data)
        return try fromCBOR(value)
    }

    public static func toCBOR(_ envelope: ExtensionEnvelope) -> CBORValue {
        switch envelope {
        case .handshake(let h):
            return CBORValue.stringMap([
                "k": .text("handshake"),
                "major": .int(h.protocolVersion.major),
                "minor": .int(h.protocolVersion.minor),
                "schema": .text(h.schemaHash),
                "api": .text(h.apiVersion),
                "id": .text(h.packageID),
                "ver": .text(h.packageVersion),
                "digest": h.packageDigest.map { .text($0) } ?? .null,
                "name": .text(h.displayName),
                "caps": .array(h.capabilities.map { .text($0) }),
                "perms": .array(h.permissions.map { .text($0) }),
                "runtime": .text(h.runtimeKind),
                "platform": .text(h.platform),
                "arch": .text(h.arch),
                "pid": h.processID.map { .int(Int($0)) } ?? .null,
            ])
        case .handshakeResult(let r):
            return CBORValue.stringMap([
                "k": .text("handshakeResult"),
                "ok": .bool(r.accepted),
                "major": .int(r.protocolVersion.major),
                "minor": .int(r.protocolVersion.minor),
                "schema": .text(r.schemaHash),
                "caps": .array(r.hostCapabilities.map { .text($0) }),
                "perms": .array(r.grantedPermissions.map { .text($0) }),
                "max_payload": .int(r.limits.maxPayloadBytes),
                "max_frame": .int(r.limits.maxFrameBytes),
                "stream_window": .int(r.limits.streamWindow),
                "max_concurrent": .int(r.limits.maxConcurrentRequests),
                "timeout_ms": .int(r.limits.requestTimeoutMS),
                "generation": .unsigned(r.generation),
                "reason": r.rejectReason.map { .text($0) } ?? .null,
            ])
        case .request(let id, let method, let payload, let timeoutMS, let generation):
            return CBORValue.stringMap([
                "k": .text("request"),
                "id": .text(id.rawValue.uuidString),
                "method": .text(method.rawValue),
                "payload": .bytes(payload),
                "timeout_ms": .int(timeoutMS),
                "generation": .unsigned(generation),
            ])
        case .response(let id, let result, let error, let generation):
            var map: [String: CBORValue] = [
                "k": .text("response"),
                "id": .text(id.rawValue.uuidString),
                "generation": .unsigned(generation),
            ]
            if let result { map["result"] = .bytes(result) } else { map["result"] = .null }
            if let error {
                map["error_code"] = .int(error.code)
                map["error_msg"] = .text(error.message)
            }
            return CBORValue.stringMap(map)
        case .cancel(let id):
            return CBORValue.stringMap([
                "k": .text("cancel"),
                "id": .text(id.rawValue.uuidString),
            ])
        case .progress(let id, let percent, let message):
            return CBORValue.stringMap([
                "k": .text("progress"),
                "id": .text(id.rawValue.uuidString),
                "percent": percent.map { .int($0) } ?? .null,
                "message": message.map { .text($0) } ?? .null,
            ])
        case .streamOpen(let id, let streamID, let window):
            return CBORValue.stringMap([
                "k": .text("streamOpen"),
                "id": .text(id.rawValue.uuidString),
                "stream": .text(streamID),
                "window": .int(window),
            ])
        case .streamChunk(let streamID, let sequence, let data, let fin):
            return CBORValue.stringMap([
                "k": .text("streamChunk"),
                "stream": .text(streamID),
                "seq": .unsigned(sequence),
                "data": .bytes(data),
                "fin": .bool(fin),
            ])
        case .streamClose(let streamID, let error):
            var map: [String: CBORValue] = [
                "k": .text("streamClose"),
                "stream": .text(streamID),
            ]
            if let error {
                map["error_code"] = .int(error.code)
                map["error_msg"] = .text(error.message)
            }
            return CBORValue.stringMap(map)
        case .notification(let kind, let payload):
            return CBORValue.stringMap([
                "k": .text("notification"),
                "kind": .text(kind),
                "payload": .bytes(payload),
            ])
        case .ping:
            return CBORValue.stringMap(["k": .text("ping")])
        case .pong:
            return CBORValue.stringMap(["k": .text("pong")])
        }
    }

    public static func fromCBOR(_ value: CBORValue) throws -> ExtensionEnvelope {
        guard let map = value.stringMap, let kind = map["k"]?.stringValue else {
            throw CBORError.typeMismatch("envelope map")
        }
        switch kind {
        case "handshake":
            return .handshake(ExtensionWireHandshake(
                protocolVersion: ExtensionWireProtocolVersion(
                    major: map["major"]?.intValue ?? 1,
                    minor: map["minor"]?.intValue ?? 0
                ),
                schemaHash: map["schema"]?.stringValue ?? "",
                apiVersion: map["api"]?.stringValue ?? "1.0.0",
                packageID: map["id"]?.stringValue ?? "",
                packageVersion: map["ver"]?.stringValue ?? "0",
                packageDigest: map["digest"]?.stringValue,
                displayName: map["name"]?.stringValue ?? "",
                capabilities: map["caps"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                permissions: map["perms"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                runtimeKind: map["runtime"]?.stringValue ?? "native-process",
                platform: map["platform"]?.stringValue ?? "",
                arch: map["arch"]?.stringValue ?? "",
                processID: map["pid"]?.intValue.map { Int32($0) }
            ))
        case "handshakeResult":
            let limits = ExtensionHostLimits(
                maxPayloadBytes: map["max_payload"]?.intValue ?? ExtensionHostLimits.default.maxPayloadBytes,
                maxFrameBytes: map["max_frame"]?.intValue ?? ExtensionHostLimits.default.maxFrameBytes,
                streamWindow: map["stream_window"]?.intValue ?? ExtensionHostLimits.default.streamWindow,
                maxConcurrentRequests: map["max_concurrent"]?.intValue ?? ExtensionHostLimits.default.maxConcurrentRequests,
                requestTimeoutMS: map["timeout_ms"]?.intValue ?? ExtensionHostLimits.default.requestTimeoutMS
            )
            return .handshakeResult(ExtensionWireHandshakeResult(
                accepted: map["ok"]?.boolValue ?? false,
                protocolVersion: ExtensionWireProtocolVersion(
                    major: map["major"]?.intValue ?? 1,
                    minor: map["minor"]?.intValue ?? 0
                ),
                schemaHash: map["schema"]?.stringValue ?? "",
                hostCapabilities: map["caps"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                grantedPermissions: map["perms"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                limits: limits,
                generation: map["generation"]?.intValue.map { UInt64($0) } ?? {
                    if case .unsigned(let u) = map["generation"] { return u }
                    return 1
                }(),
                rejectReason: map["reason"]?.stringValue
            ))
        case "request":
            guard let idStr = map["id"]?.stringValue, let uuid = UUID(uuidString: idStr),
                  let method = map["method"]?.stringValue
            else { throw CBORError.typeMismatch("request") }
            let gen: UInt64
            if case .unsigned(let u) = map["generation"] { gen = u }
            else { gen = UInt64(map["generation"]?.intValue ?? 0) }
            return .request(
                id: ExtensionRequestID(uuid),
                method: ExtensionMethodID(rawValue: method),
                payload: map["payload"]?.dataValue ?? Data(),
                timeoutMS: map["timeout_ms"]?.intValue ?? 15_000,
                generation: gen
            )
        case "response":
            guard let idStr = map["id"]?.stringValue, let uuid = UUID(uuidString: idStr) else {
                throw CBORError.typeMismatch("response")
            }
            let gen: UInt64
            if case .unsigned(let u) = map["generation"] { gen = u }
            else { gen = UInt64(map["generation"]?.intValue ?? 0) }
            var error: ExtensionWireError?
            if let code = map["error_code"]?.intValue {
                error = ExtensionWireError(code: code, message: map["error_msg"]?.stringValue ?? "")
            }
            let result: Data?
            if case .null = map["result"] { result = nil }
            else { result = map["result"]?.dataValue }
            return .response(id: ExtensionRequestID(uuid), result: result, error: error, generation: gen)
        case "cancel":
            guard let idStr = map["id"]?.stringValue, let uuid = UUID(uuidString: idStr) else {
                throw CBORError.typeMismatch("cancel")
            }
            return .cancel(id: ExtensionRequestID(uuid))
        case "progress":
            guard let idStr = map["id"]?.stringValue, let uuid = UUID(uuidString: idStr) else {
                throw CBORError.typeMismatch("progress")
            }
            return .progress(
                id: ExtensionRequestID(uuid),
                percent: map["percent"]?.intValue,
                message: map["message"]?.stringValue
            )
        case "streamOpen":
            guard let idStr = map["id"]?.stringValue, let uuid = UUID(uuidString: idStr),
                  let stream = map["stream"]?.stringValue
            else { throw CBORError.typeMismatch("streamOpen") }
            return .streamOpen(id: ExtensionRequestID(uuid), streamID: stream, window: map["window"]?.intValue ?? 8)
        case "streamChunk":
            guard let stream = map["stream"]?.stringValue else { throw CBORError.typeMismatch("streamChunk") }
            let seq: UInt64
            if case .unsigned(let u) = map["seq"] { seq = u }
            else { seq = UInt64(map["seq"]?.intValue ?? 0) }
            return .streamChunk(
                streamID: stream,
                sequence: seq,
                data: map["data"]?.dataValue ?? Data(),
                fin: map["fin"]?.boolValue ?? false
            )
        case "streamClose":
            guard let stream = map["stream"]?.stringValue else { throw CBORError.typeMismatch("streamClose") }
            var error: ExtensionWireError?
            if let code = map["error_code"]?.intValue {
                error = ExtensionWireError(code: code, message: map["error_msg"]?.stringValue ?? "")
            }
            return .streamClose(streamID: stream, error: error)
        case "notification":
            return .notification(
                kind: map["kind"]?.stringValue ?? "",
                payload: map["payload"]?.dataValue ?? Data()
            )
        case "ping":
            return .ping
        case "pong":
            return .pong
        default:
            throw CBORError.typeMismatch("unknown kind \(kind)")
        }
    }
}

/// JSON diagnostic renderer (not the wire format).
public enum JSONDiagnosticRenderer {
    public static func render(_ envelope: ExtensionEnvelope) -> String {
        switch envelope {
        case .handshake(let h):
            return "handshake \(h.packageID)@\(h.packageVersion) schema=\(h.schemaHash.prefix(12))…"
        case .handshakeResult(let r):
            return "handshakeResult ok=\(r.accepted) gen=\(r.generation) \(r.rejectReason ?? "")"
        case .request(_, let method, let payload, _, let gen):
            return "request \(method.rawValue) bytes=\(payload.count) gen=\(gen)"
        case .response(_, let result, let error, let gen):
            if let error { return "response error \(error.code) gen=\(gen)" }
            return "response bytes=\(result?.count ?? 0) gen=\(gen)"
        case .cancel(let id):
            return "cancel \(id)"
        case .progress(_, let p, let m):
            return "progress \(p.map(String.init) ?? "-") \(m ?? "")"
        case .streamOpen(_, let s, let w):
            return "streamOpen \(s) window=\(w)"
        case .streamChunk(let s, let seq, let d, let fin):
            return "streamChunk \(s) seq=\(seq) bytes=\(d.count) fin=\(fin)"
        case .streamClose(let s, let e):
            return "streamClose \(s) \(e?.message ?? "ok")"
        case .notification(let k, let p):
            return "notification \(k) bytes=\(p.count)"
        case .ping: return "ping"
        case .pong: return "pong"
        }
    }
}
