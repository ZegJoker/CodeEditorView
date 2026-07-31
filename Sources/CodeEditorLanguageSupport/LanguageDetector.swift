import Foundation

/// Deterministic language detection from filename and optional content prefix.
public enum LanguageDetector: Sendable {
    public static let maxContentBytes = 4096

    /// Detect language for a path and optional file head.
    ///
    /// Order: exact filename → first-line patterns → content patterns → extension
    /// (highest ``LanguageDefinition/detectionPriority`` wins ties).
    public static func detect(
        filename: String,
        contentPrefix: String? = nil,
        in registry: LanguageRegistry = .shared
    ) -> LanguageID? {
        let definitions = registry.allDefinitions()
        guard !definitions.isEmpty else { return nil }

        let base = (filename as NSString).lastPathComponent
        let baseLower = base.lowercased()
        let ext = (base as NSString).pathExtension.lowercased()

        // 1) Exact filename
        var filenameHits = definitions.filter { $0.filenames.contains(baseLower) }
        if let best = pickBest(filenameHits) { return best.id }

        let head: String?
        if let contentPrefix {
            head = String(contentPrefix.prefix(maxContentBytes))
        } else {
            head = nil
        }
        let firstLine = head?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)

        // 2) First-line
        if let firstLine {
            var hits: [LanguageDefinition] = []
            for def in definitions {
                for pattern in def.firstLinePatterns {
                    if match(pattern: pattern, text: firstLine) {
                        hits.append(def)
                        break
                    }
                }
            }
            if let best = pickBest(hits) { return best.id }
        }

        // 3) Content
        if let head {
            var hits: [LanguageDefinition] = []
            for def in definitions {
                for pattern in def.contentPatterns {
                    if match(pattern: pattern, text: head) {
                        hits.append(def)
                        break
                    }
                }
            }
            if let best = pickBest(hits) { return best.id }
        }

        // 4) Extension
        if !ext.isEmpty {
            let hits = definitions.filter { $0.fileExtensions.contains(ext) }
            if let best = pickBest(hits) { return best.id }
        }

        return nil
    }

    private static func pickBest(_ defs: [LanguageDefinition]) -> LanguageDefinition? {
        defs.max { a, b in
            if a.detectionPriority != b.detectionPriority {
                return a.detectionPriority < b.detectionPriority
            }
            return a.id.rawValue > b.id.rawValue
        }
    }

    private static func match(pattern: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
