import Foundation

/// Documents ownership of a tree-sitter `TSLanguage *` (LANG-N04).
public enum TSLanguageOwnership: Sendable, Hashable {
    /// Pointer from a static grammar C symbol (`tree_sitter_*()`). Never freed.
    /// Safe to share across actors for the process lifetime.
    case staticGrammarSymbol
    /// Pointer owned by a dynamic loader that must outlive parsers/trees/queries.
    /// The retaining object is held by the loader integration; this ref does not free it.
    case retainedExternal
}

/// Sendable handle to a tree-sitter language pointer with explicit ownership (LANG-N04).
///
/// Static grammar symbols are immortal for the process; this type prevents callers
/// from inventing raw `OpaquePointer` values without documenting lifetime.
///
/// `OpaquePointer` is not `Sendable`; the bit pattern is stored and reconstructed.
/// For ``TSLanguageOwnership/staticGrammarSymbol`` this is safe because the
/// underlying `TSLanguage` is process-immortal.
public struct TSLanguageRef: Sendable, Hashable {
    public let languageID: LanguageID
    public let ownership: TSLanguageOwnership
    private let pointerBits: UInt

    /// Underlying `TSLanguage *`. Valid while this ref (and any retaining owner) lives.
    public var pointer: OpaquePointer {
        OpaquePointer(bitPattern: pointerBits)!
    }

    public init(languageID: LanguageID, pointer: OpaquePointer, ownership: TSLanguageOwnership) {
        self.languageID = languageID
        self.pointerBits = UInt(bitPattern: pointer)
        self.ownership = ownership
    }

    public static func == (lhs: TSLanguageRef, rhs: TSLanguageRef) -> Bool {
        lhs.languageID == rhs.languageID
            && lhs.ownership == rhs.ownership
            && lhs.pointerBits == rhs.pointerBits
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(languageID)
        hasher.combine(ownership)
        hasher.combine(pointerBits)
    }
}
