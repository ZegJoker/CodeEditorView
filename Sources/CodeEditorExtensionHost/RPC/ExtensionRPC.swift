import Foundation
import CodeEditorExtensions

public struct ExtensionRPCProtocolVersion: Hashable, Codable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    public static let current = ExtensionRPCProtocolVersion(major: 1, minor: 0)

    /// Same major required; peer minor must be >= host minor for host→extension compatibility.
    public func isCompatible(with peer: ExtensionRPCProtocolVersion) -> Bool {
        major == peer.major
    }
}

public enum ExtensionRPCMethod: String, Codable, Sendable, Hashable {
    case activate
    case deactivate
    case completion
    case hover
    case definition
    case diagnostics
    case ping
}

public struct ExtensionRPCHandshake: Codable, Sendable {
    public var protocolVersion: ExtensionRPCProtocolVersion
    public var extensionManifest: ExtensionManifest
    public var processID: Int32?

    public init(
        protocolVersion: ExtensionRPCProtocolVersion = .current,
        extensionManifest: ExtensionManifest,
        processID: Int32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.extensionManifest = extensionManifest
        self.processID = processID
    }
}

public struct ExtensionRPCHandshakeResult: Codable, Sendable {
    public var accepted: Bool
    public var protocolVersion: ExtensionRPCProtocolVersion
    public var hostCapabilities: [HostCapability]
    public var grantedPermissions: [ExtensionPermission]
    public var rejectReason: String?

    public init(
        accepted: Bool,
        protocolVersion: ExtensionRPCProtocolVersion = .current,
        hostCapabilities: Set<HostCapability> = [],
        grantedPermissions: Set<ExtensionPermission> = [],
        rejectReason: String? = nil
    ) {
        self.accepted = accepted
        self.protocolVersion = protocolVersion
        self.hostCapabilities = Array(hostCapabilities).sorted { $0.rawValue < $1.rawValue }
        self.grantedPermissions = Array(grantedPermissions).sorted { $0.rawValue < $1.rawValue }
        self.rejectReason = rejectReason
    }
}

public struct ExtensionRPCRequest: Codable, Sendable {
    public var id: UUID
    public var method: ExtensionRPCMethod
    public var payload: Data
    public var timeoutMS: Int

    public init(id: UUID = UUID(), method: ExtensionRPCMethod, payload: Data = Data(), timeoutMS: Int = 15_000) {
        self.id = id
        self.method = method
        self.payload = payload
        self.timeoutMS = timeoutMS
    }
}

public struct ExtensionRPCErrorPayload: Codable, Sendable, Hashable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let methodNotFound = ExtensionRPCErrorPayload(code: -32601, message: "Method not found")
    public static let timeout = ExtensionRPCErrorPayload(code: -32000, message: "Timeout")
    public static let payloadTooLarge = ExtensionRPCErrorPayload(code: -32001, message: "Payload too large")
    public static let incompatibleProtocol = ExtensionRPCErrorPayload(code: -32002, message: "Incompatible protocol")
}

public struct ExtensionRPCResponse: Codable, Sendable {
    public var id: UUID
    public var result: Data?
    public var error: ExtensionRPCErrorPayload?

    public init(id: UUID, result: Data? = nil, error: ExtensionRPCErrorPayload? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct ExtensionProcessHealth: Codable, Sendable, Hashable {
    public var lastPong: Date?
    public var consecutiveTimeouts: Int
    public var rssBytes: UInt64?

    public init(lastPong: Date? = nil, consecutiveTimeouts: Int = 0, rssBytes: UInt64? = nil) {
        self.lastPong = lastPong
        self.consecutiveTimeouts = consecutiveTimeouts
        self.rssBytes = rssBytes
    }
}

public enum ExtensionRPCNotification: Codable, Sendable {
    case log(level: String, message: String)
    case diagnostics(uri: String, itemsJSON: Data)
    case health(ExtensionProcessHealth)
    case crashed(reason: String)
}

public enum ExtensionRPCEnvelope: Codable, Sendable {
    case handshake(ExtensionRPCHandshake)
    case handshakeResult(ExtensionRPCHandshakeResult)
    case request(ExtensionRPCRequest)
    case response(ExtensionRPCResponse)
    case notification(ExtensionRPCNotification)
    case cancel(requestID: UUID)
}

public enum ExtensionHostError: Error, Sendable, Equatable {
    case transportClosed
    case timeout
    case incompatibleProtocol(String)
    case rejected(String)
    case rpc(ExtensionRPCErrorPayload)
    case decode(String)
    case payloadTooLarge
    case notRunning
    case alreadyRunning
    case notFound(String)
}

public enum ExtensionRPCCodec {
    public static func encode(_ envelope: ExtensionRPCEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> ExtensionRPCEnvelope {
        try JSONDecoder().decode(ExtensionRPCEnvelope.self, from: data)
    }

    public static func encodePayload<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decodePayload<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
