import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Trusted issuer key for signed revocation lists (EXT-N15).
public struct RevocationAuthorityKey: Sendable, Hashable, Codable {
    public var keyID: String
    public var publicKeyRaw: Data
    public var issuer: String

    public init(keyID: String, publicKeyRaw: Data, issuer: String) {
        self.keyID = keyID
        self.publicKeyRaw = publicKeyRaw
        self.issuer = issuer
    }
}

public enum RevocationListError: Error, Sendable, Equatable {
    case missingIssuer
    case missingKeyID
    case missingSignature
    case missingExpiresAt
    case invalidSignature
    case unknownIssuerKey
    case cryptoUnavailable
    case notFresh
    case emptyAuthoritySet
}

/// Ed25519 sign/verify over a canonical revocation payload (EXT-N15).
public enum RevocationListCrypto {
    /// Canonical JSON bytes of all trust-critical fields **except** `signature`.
    public static func canonicalPayload(_ document: RevocationListDocument) throws -> Data {
        guard let issuer = document.issuer, !issuer.isEmpty else {
            throw RevocationListError.missingIssuer
        }
        guard let keyID = document.keyID, !keyID.isEmpty else {
            throw RevocationListError.missingKeyID
        }
        guard let expiresAt = document.expiresAt else {
            throw RevocationListError.missingExpiresAt
        }
        // Second precision only — stable sign/verify round-trip.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let updated = formatter.string(from: document.updatedAt)
        let expires = formatter.string(from: expiresAt)
        let entries: [[String: String]] = document.entries.map { e in
            var m: [String: String] = ["reason": e.reason]
            if let p = e.packageID { m["package_id"] = p }
            if let v = e.version { m["version"] = v }
            if let k = e.keyID { m["key_id"] = k }
            return m
        }
        let body: [String: Any] = [
            "version": document.version,
            "updated_at": updated,
            "entries": entries,
            "sequence": document.sequence,
            "issuer": issuer,
            "key_id": keyID,
            "expires_at": expires,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Generate an Ed25519 key pair for a revocation authority (tests / tooling).
    public static func generateAuthorityKeyPair(keyID: String, issuer: String) throws -> (
        authority: RevocationAuthorityKey, privateKeyRaw: Data
    ) {
        #if canImport(CryptoKit)
            let privateKey = Curve25519.Signing.PrivateKey()
            let authority = RevocationAuthorityKey(
                keyID: keyID,
                publicKeyRaw: privateKey.publicKey.rawRepresentation,
                issuer: issuer
            )
            return (authority, privateKey.rawRepresentation)
        #else
            throw RevocationListError.cryptoUnavailable
        #endif
    }

    /// Sign `document` in place; requires issuer/keyID/expiresAt/sequence fields already set (or set here).
    public static func sign(
        _ document: inout RevocationListDocument,
        privateKeyRaw: Data,
        keyID: String,
        issuer: String
    ) throws {
        document.issuer = issuer
        document.keyID = keyID
        if document.expiresAt == nil {
            document.expiresAt = Date().addingTimeInterval(7 * 24 * 3600)
        }
        if document.sequence == 0 {
            document.sequence = 1
        }
        let payload = try canonicalPayload(document)
        #if canImport(CryptoKit)
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
            let signature = try privateKey.signature(for: payload)
            document.signature = signature.base64EncodedString()
        #else
            throw RevocationListError.cryptoUnavailable
        #endif
    }

    /// Fail-closed signature verification against trusted authorities.
    public static func verify(
        _ document: RevocationListDocument,
        authorities: [RevocationAuthorityKey]
    ) throws {
        guard !authorities.isEmpty else {
            throw RevocationListError.emptyAuthoritySet
        }
        guard let issuer = document.issuer, !issuer.isEmpty else {
            throw RevocationListError.missingIssuer
        }
        guard let keyID = document.keyID, !keyID.isEmpty else {
            throw RevocationListError.missingKeyID
        }
        guard let signatureB64 = document.signature, !signatureB64.isEmpty else {
            throw RevocationListError.missingSignature
        }
        guard document.expiresAt != nil else {
            throw RevocationListError.missingExpiresAt
        }
        guard let signature = Data(base64Encoded: signatureB64) else {
            throw RevocationListError.invalidSignature
        }
        guard let authority = authorities.first(where: { $0.keyID == keyID && $0.issuer == issuer })
        else {
            throw RevocationListError.unknownIssuerKey
        }
        let payload = try canonicalPayload(document)
        #if canImport(CryptoKit)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: authority.publicKeyRaw)
            guard publicKey.isValidSignature(signature, for: payload) else {
                throw RevocationListError.invalidSignature
            }
        #else
            throw RevocationListError.cryptoUnavailable
        #endif
    }

    /// Structural completeness for any non-bootstrap list (sequence > 0 or non-empty entries).
    public static func requireSignedStructure(_ document: RevocationListDocument) throws {
        if document.sequence == 0 && document.entries.isEmpty {
            // Bootstrap empty state only.
            return
        }
        guard let issuer = document.issuer, !issuer.isEmpty else {
            throw RevocationListError.missingIssuer
        }
        guard let keyID = document.keyID, !keyID.isEmpty else {
            throw RevocationListError.missingKeyID
        }
        guard let sig = document.signature, !sig.isEmpty else {
            throw RevocationListError.missingSignature
        }
        guard document.expiresAt != nil else {
            throw RevocationListError.missingExpiresAt
        }
    }
}
