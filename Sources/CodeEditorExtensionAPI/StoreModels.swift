import Foundation

// MARK: - Install state

public enum PackageInstallState: String, Sendable, Hashable, Codable {
    case discovered
    case validating
    case installing
    case installed
    case failed
    case quarantined
    case uninstalling
}

public enum ExtensionTrustClassDTO: String, Sendable, Hashable, Codable {
    case trustedSigned
    case workspaceDev
    case untrusted
}

// MARK: - Trust UI descriptors (no SwiftUI)

public enum TrustAction: String, Sendable, Hashable, Codable, CaseIterable {
    case allowOnce
    case allowAlways
    case deny
    case viewDetails
}

public struct TrustPromptDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var message: String
    public var packageID: String
    public var publisher: String?
    public var trustClass: ExtensionTrustClassDTO
    public var risks: [String]
    public var actions: [TrustAction]

    public init(
        id: String = UUID().uuidString,
        title: String,
        message: String,
        packageID: String,
        publisher: String? = nil,
        trustClass: ExtensionTrustClassDTO,
        risks: [String] = [],
        actions: [TrustAction] = [.allowOnce, .deny, .viewDetails]
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.packageID = packageID
        self.publisher = publisher
        self.trustClass = trustClass
        self.risks = risks
        self.actions = actions
    }
}

public struct ExtensionTrustStatusItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String { packageID }
    public var packageID: String
    public var version: String
    public var trustClass: ExtensionTrustClassDTO
    public var enabled: Bool
    public var quarantined: Bool
    public var lastError: String?
    public var publisher: String?

    public init(
        packageID: String,
        version: String,
        trustClass: ExtensionTrustClassDTO,
        enabled: Bool,
        quarantined: Bool,
        lastError: String? = nil,
        publisher: String? = nil
    ) {
        self.packageID = packageID
        self.version = version
        self.trustClass = trustClass
        self.enabled = enabled
        self.quarantined = quarantined
        self.lastError = lastError
        self.publisher = publisher
    }
}

// MARK: - Telemetry

public struct StoreTelemetryEvent: Sendable, Hashable, Codable {
    public var event: String
    public var packageID: String?
    public var fromVersion: String?
    public var toVersion: String?
    public var success: Bool
    public var reason: String?
    public var todos: Int?
    public var timestamp: Date

    public init(
        event: String,
        packageID: String? = nil,
        fromVersion: String? = nil,
        toVersion: String? = nil,
        success: Bool,
        reason: String? = nil,
        todos: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.event = event
        self.packageID = packageID
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.success = success
        self.reason = reason
        self.todos = todos
        self.timestamp = timestamp
    }
}

// MARK: - Registry index

public struct ExtensionIndexDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var packages: [ExtensionIndexEntry]

    public init(schemaVersion: Int = 1, packages: [ExtensionIndexEntry] = []) {
        self.schemaVersion = schemaVersion
        self.packages = packages
    }
}

public struct ExtensionIndexEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var publisher: String?
    public var versions: [ExtensionIndexVersion]
    public var channels: [String]

    public init(
        id: String,
        name: String,
        publisher: String? = nil,
        versions: [ExtensionIndexVersion] = [],
        channels: [String] = ["stable"]
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.versions = versions
        self.channels = channels
    }
}

public struct ExtensionIndexVersion: Sendable, Hashable, Codable {
    public var version: String
    public var artifactPath: String
    public var digest: String?
    public var channel: String

    public init(version: String, artifactPath: String, digest: String? = nil, channel: String = "stable") {
        self.version = version
        self.artifactPath = artifactPath
        self.digest = digest
        self.channel = channel
    }
}

public struct ExtensionArtifactRef: Sendable, Hashable, Codable {
    public var packageID: String
    public var version: String
    public var localPath: URL?
    public var remoteURL: URL?
    public var digest: String?

    public init(
        packageID: String,
        version: String,
        localPath: URL? = nil,
        remoteURL: URL? = nil,
        digest: String? = nil
    ) {
        self.packageID = packageID
        self.version = version
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.digest = digest
    }
}

// MARK: - Revocation (EXT-N15 freshness / rollback / crypto protection)

public struct RevocationListDocument: Sendable, Hashable, Codable {
    public var version: Int
    public var updatedAt: Date
    public var entries: [RevocationEntry]
    /// Monotonic epoch for rollback prevention.
    public var sequence: UInt64
    /// Issuing authority subject (required for any non-bootstrap list).
    public var issuer: String?
    /// Key id of the Ed25519 authority key that produced ``signature``.
    public var keyID: String?
    public var expiresAt: Date?
    /// Base64 Ed25519 signature over ``RevocationListCrypto/canonicalPayload`` (required; verified before apply).
    public var signature: String?

    public init(
        version: Int = 1,
        updatedAt: Date = Date(),
        entries: [RevocationEntry] = [],
        sequence: UInt64 = 0,
        issuer: String? = nil,
        keyID: String? = nil,
        expiresAt: Date? = nil,
        signature: String? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.entries = entries
        self.sequence = sequence
        self.issuer = issuer
        self.keyID = keyID
        self.expiresAt = expiresAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case entries
        case sequence
        case issuer
        case keyID = "key_id"
        case expiresAt
        case signature
    }

    /// Fresh when not expired and within maxAge of `updatedAt`.
    public func isFresh(now: Date = Date(), maxAge: TimeInterval = 7 * 24 * 3600) -> Bool {
        if let exp = expiresAt, now > exp { return false }
        if now.timeIntervalSince(updatedAt) > maxAge { return false }
        return true
    }

    /// Apply an update only when its sequence is strictly greater (EXT-N15).
    /// Caller must already have verified crypto/freshness on `next`.
    public mutating func applyMonotonicUpdate(_ next: RevocationListDocument) throws {
        guard next.sequence > sequence else {
            throw ExtensionError.dataLoad(
                "revocation sequence rollback rejected: current=\(sequence) next=\(next.sequence)"
            )
        }
        self = next
    }

    /// Sign this document with an authority private key (EXT-N15).
    public mutating func sign(privateKeyRaw: Data, keyID: String, issuer: String) throws {
        try RevocationListCrypto.sign(
            &self, privateKeyRaw: privateKeyRaw, keyID: keyID, issuer: issuer)
    }

    /// Verify Ed25519 signature against trusted authorities (EXT-N15 fail-closed).
    public func verify(authorities: [RevocationAuthorityKey]) throws {
        try RevocationListCrypto.verify(self, authorities: authorities)
    }
}

public struct RevocationEntry: Sendable, Hashable, Codable {
    public var packageID: String?
    public var version: String?
    public var keyID: String?
    public var reason: String

    public init(packageID: String? = nil, version: String? = nil, keyID: String? = nil, reason: String) {
        self.packageID = packageID
        self.version = version
        self.keyID = keyID
        self.reason = reason
    }

    public func matches(packageID: String, version: String) -> Bool {
        guard let pid = self.packageID else { return false }
        guard pid == packageID else { return false }
        if let v = self.version, v != "*" {
            return v == version
        }
        return true
    }
}
