import Foundation

/// Immutable, generation-scoped plan produced by package loaders.
public struct ValidatedContributionPlan: Sendable, Hashable {
    public var packageID: ExtensionID
    public var displayName: String
    public var version: SemanticVersion
    public var manifest: ExtensionManifest
    public var packageRoot: URL?
    public var sourceFormat: PackageSourceFormat
    public var digest: String?
    public var themes: [ThemeContribution]
    public var snippets: [SnippetContribution]
    public var iconThemes: [IconThemeContribution]
    public var languages: [LanguageDefinitionDTO]
    public var keybindings: [KeybindingOverrideDTO]
    public var grammars: [GrammarContribution]
    public var queries: [QueryContribution]
    public var languageServers: [LanguageServerContribution]
    public var debugAdapters: [DebugAdapterContribution]
    public var mcpServers: [MCPServerContribution]
    public var slashCommands: [SlashCommandContribution]
    public var documentationPackages: [DocumentationPackageContribution]
    public var assets: [AssetContribution]
    public var diagnostics: [ExtensionPackageDiagnostic]
    public var unsupportedFields: [String]
    public var parityProfile: String
    public var generation: UInt64

    public init(
        packageID: ExtensionID,
        displayName: String,
        version: SemanticVersion,
        manifest: ExtensionManifest,
        packageRoot: URL? = nil,
        sourceFormat: PackageSourceFormat,
        digest: String? = nil,
        themes: [ThemeContribution] = [],
        snippets: [SnippetContribution] = [],
        iconThemes: [IconThemeContribution] = [],
        languages: [LanguageDefinitionDTO] = [],
        keybindings: [KeybindingOverrideDTO] = [],
        grammars: [GrammarContribution] = [],
        queries: [QueryContribution] = [],
        languageServers: [LanguageServerContribution] = [],
        debugAdapters: [DebugAdapterContribution] = [],
        mcpServers: [MCPServerContribution] = [],
        slashCommands: [SlashCommandContribution] = [],
        documentationPackages: [DocumentationPackageContribution] = [],
        assets: [AssetContribution] = [],
        diagnostics: [ExtensionPackageDiagnostic] = [],
        unsupportedFields: [String] = [],
        parityProfile: String = "codeeditor-data-s1",
        generation: UInt64 = 0
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.version = version
        self.manifest = manifest
        self.packageRoot = packageRoot
        self.sourceFormat = sourceFormat
        self.digest = digest
        self.themes = themes
        self.snippets = snippets
        self.iconThemes = iconThemes
        self.languages = languages
        self.keybindings = keybindings
        self.grammars = grammars
        self.queries = queries
        self.languageServers = languageServers
        self.debugAdapters = debugAdapters
        self.mcpServers = mcpServers
        self.slashCommands = slashCommands
        self.documentationPackages = documentationPackages
        self.assets = assets
        self.diagnostics = diagnostics
        self.unsupportedFields = unsupportedFields
        self.parityProfile = parityProfile
        self.generation = generation
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

public enum PackageSourceFormat: String, Sendable, Hashable, Codable {
    case toml
    case legacyJSON
    case zedImport
}

/// Collision / precedence policy for contribution IDs.
public enum ContributionPrecedence: Sendable, Hashable {
    /// Higher package generation wins.
    case higherGeneration
    /// Explicit priority field, then generation, then package id.
    case priorityThenGeneration
    /// First registered wins (stable for same generation).
    case firstWins
}

public struct ContributionCollision: Sendable, Hashable {
    public var kind: String
    public var contributionID: String
    public var winnerPackageID: ExtensionID
    public var loserPackageID: ExtensionID
    public var rule: String

    public init(
        kind: String,
        contributionID: String,
        winnerPackageID: ExtensionID,
        loserPackageID: ExtensionID,
        rule: String
    ) {
        self.kind = kind
        self.contributionID = contributionID
        self.winnerPackageID = winnerPackageID
        self.loserPackageID = loserPackageID
        self.rule = rule
    }
}

/// Immutable snapshot of all loaded declarative contributions.
public struct ExtensionContributionSnapshot: Sendable, Hashable {
    public var generation: UInt64
    public var packages: [ValidatedContributionPlan]
    public var themes: [ThemeContribution]
    public var snippets: [SnippetContribution]
    public var iconThemes: [IconThemeContribution]
    public var languages: [LanguageDefinitionDTO]
    public var keybindings: [KeybindingOverrideDTO]
    public var grammars: [GrammarContribution]
    public var queries: [QueryContribution]
    public var collisions: [ContributionCollision]

    public init(
        generation: UInt64,
        packages: [ValidatedContributionPlan],
        themes: [ThemeContribution],
        snippets: [SnippetContribution],
        iconThemes: [IconThemeContribution],
        languages: [LanguageDefinitionDTO],
        keybindings: [KeybindingOverrideDTO],
        grammars: [GrammarContribution] = [],
        queries: [QueryContribution] = [],
        collisions: [ContributionCollision] = []
    ) {
        self.generation = generation
        self.packages = packages
        self.themes = themes
        self.snippets = snippets
        self.iconThemes = iconThemes
        self.languages = languages
        self.keybindings = keybindings
        self.grammars = grammars
        self.queries = queries
        self.collisions = collisions
    }

    public static let empty = ExtensionContributionSnapshot(
        generation: 0,
        packages: [],
        themes: [],
        snippets: [],
        iconThemes: [],
        languages: [],
        keybindings: []
    )
}

/// Builds an immutable snapshot from validated plans with deterministic collision resolution.
public enum ImmutableContributionRegistry {
    /// Precedence within one generation: lexicographic package id (later overwrites),
    /// then collisions recorded. Callers that prefer dev packages must pass plans already filtered
    /// so only one plan exists per package id (dev install replaces installed).
    public static func build(
        packages: [ValidatedContributionPlan],
        generation: UInt64
    ) -> ExtensionContributionSnapshot {
        let sorted = packages.sorted { $0.packageID.rawValue < $1.packageID.rawValue }
        var themeMap: [String: (ThemeContribution, ExtensionID)] = [:]
        var snippetMap: [String: (SnippetContribution, ExtensionID)] = [:]
        var iconMap: [String: (IconThemeContribution, ExtensionID)] = [:]
        var langMap: [String: (LanguageDefinitionDTO, ExtensionID)] = [:]
        var grammarMap: [String: (GrammarContribution, ExtensionID)] = [:]
        var queryMap: [String: (QueryContribution, ExtensionID)] = [:]
        var collisions: [ContributionCollision] = []

        func collide(
            kind: String,
            id: String,
            winner: ExtensionID,
            loser: ExtensionID
        ) {
            collisions.append(
                ContributionCollision(
                    kind: kind,
                    contributionID: id,
                    winnerPackageID: winner,
                    loserPackageID: loser,
                    rule: "package-id-lexicographic-overwrite"
                ))
        }

        for plan in sorted {
            for theme in plan.themes {
                if let existing = themeMap[theme.id] {
                    collide(kind: "theme", id: theme.id, winner: plan.packageID, loser: existing.1)
                }
                themeMap[theme.id] = (theme, plan.packageID)
            }
            for snip in plan.snippets {
                if let existing = snippetMap[snip.id] {
                    collide(kind: "snippet", id: snip.id, winner: plan.packageID, loser: existing.1)
                }
                snippetMap[snip.id] = (snip, plan.packageID)
            }
            for icon in plan.iconThemes {
                if let existing = iconMap[icon.id] {
                    collide(kind: "icon_theme", id: icon.id, winner: plan.packageID, loser: existing.1)
                }
                iconMap[icon.id] = (icon, plan.packageID)
            }
            for lang in plan.languages {
                if let existing = langMap[lang.id] {
                    collide(kind: "language", id: lang.id, winner: plan.packageID, loser: existing.1)
                }
                langMap[lang.id] = (lang, plan.packageID)
            }
            for g in plan.grammars {
                if let existing = grammarMap[g.id] {
                    collide(kind: "grammar", id: g.id, winner: plan.packageID, loser: existing.1)
                }
                grammarMap[g.id] = (g, plan.packageID)
            }
            for q in plan.queries {
                if let existing = queryMap[q.id] {
                    collide(kind: "query", id: q.id, winner: plan.packageID, loser: existing.1)
                }
                queryMap[q.id] = (q, plan.packageID)
            }
        }

        return ExtensionContributionSnapshot(
            generation: generation,
            packages: sorted,
            themes: themeMap.values.map(\.0).sorted { $0.id < $1.id },
            snippets: snippetMap.values.map(\.0).sorted { $0.id < $1.id },
            iconThemes: iconMap.values.map(\.0).sorted { $0.id < $1.id },
            languages: langMap.values.map(\.0).sorted { $0.id < $1.id },
            keybindings: sorted.flatMap(\.keybindings),
            grammars: grammarMap.values.map(\.0).sorted { $0.id < $1.id },
            queries: queryMap.values.map(\.0).sorted { $0.id < $1.id },
            collisions: collisions
        )
    }
}

/// Canonical package file digest (SHA-256 hex of sorted path+content).
public enum ExtensionPackageDigest {
    public static func compute(packageRoot: URL) throws -> String {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: packageRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw ExtensionError.dataLoad("cannot enumerate package")
        }
        var files: [(String, Data)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: packageRoot.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.hasPrefix(".codeeditor/") { continue }
            let data = try Data(contentsOf: url)
            files.append((rel, data))
        }
        files.sort { $0.0 < $1.0 }
        var hasher = SHA256Hasher()
        for (path, data) in files {
            hasher.update(Data(path.utf8))
            hasher.update(Data([0]))
            hasher.update(data)
            hasher.update(Data([0]))
        }
        return hasher.finalizeHex()
    }
}

/// Minimal SHA-256 (via CryptoKit when available, else CommonCrypto-free portable).
#if canImport(CryptoKit)
    import CryptoKit

    struct SHA256Hasher {
        private var hasher = SHA256()
        mutating func update(_ data: Data) { hasher.update(data: data) }
        func finalizeHex() -> String {
            hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        }
    }
#else
    struct SHA256Hasher {
        private var data = Data()
        mutating func update(_ chunk: Data) { data.append(chunk) }
        func finalizeHex() -> String {
            // Fallback: non-crypto fingerprint for platforms without CryptoKit (should not hit on Apple).
            var hash: UInt64 = 5381
            for b in data { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
            return String(format: "%016llx", hash) + String(format: "%08x", data.count)
        }
    }
#endif
