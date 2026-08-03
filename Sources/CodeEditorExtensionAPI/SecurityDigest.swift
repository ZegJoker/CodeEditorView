import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Fail-closed SHA-256 for security digests (EXT-N03 / EXT-N08).
/// Never returns a non-cryptographic fingerprint; never `fatalError`s on host input.
public enum SecurityDigestError: Error, Sendable, Equatable {
    case cryptoUnavailable
}

/// Explicit crypto availability for callers that need to exercise fail-closed paths
/// (including tests). Production defaults use ``CryptoAvailability/system``.
public enum CryptoAvailability: Sendable, Equatable {
    /// Use platform CryptoKit when available; throw ``SecurityDigestError/cryptoUnavailable`` otherwise.
    case system
    /// Force the unavailable path (tests / degraded environments). Never a production default.
    case unavailable
}

public enum SecurityDigest {
    /// SHA-256 hex (64 lowercase hex chars). Throws when crypto is unavailable.
    public static func sha256Hex(
        _ data: Data,
        availability: CryptoAvailability = .system
    ) throws -> String {
        switch availability {
        case .unavailable:
            throw SecurityDigestError.cryptoUnavailable
        case .system:
            #if canImport(CryptoKit)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #else
                throw SecurityDigestError.cryptoUnavailable
            #endif
        }
    }

    /// Streaming SHA-256 of a regular file (bounded chunk reads; no whole-file `Data` load).
    public static func sha256HexFile(
        at url: URL,
        chunkSize: Int = 64 * 1024,
        availability: CryptoAvailability = .system
    ) throws -> String {
        switch availability {
        case .unavailable:
            throw SecurityDigestError.cryptoUnavailable
        case .system:
            #if canImport(CryptoKit)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    let chunk = try handle.read(upToCount: max(1, chunkSize)) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            #else
                throw SecurityDigestError.cryptoUnavailable
            #endif
        }
    }
}
