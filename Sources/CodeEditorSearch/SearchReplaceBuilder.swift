import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

public struct SearchReplacePlan: Sendable {
    public var query: SearchQuery
    public var replacement: String
    public var matches: [SearchMatch]
    /// Optional snapshot pins captured at preview time (SRCH-N09).
    public var pinnedDocuments: [DocumentURI: SearchReplacePinnedDocument]

    public init(
        query: SearchQuery,
        replacement: String,
        matches: [SearchMatch],
        pinnedDocuments: [DocumentURI: SearchReplacePinnedDocument] = [:]
    ) {
        self.query = query
        self.replacement = replacement
        self.matches = matches
        self.pinnedDocuments = pinnedDocuments
    }
}

/// Content/identity snapshot for one document at replace preview time (SRCH-N09).
public struct SearchReplacePinnedDocument: Sendable, Hashable {
    public var uri: DocumentURI
    public var version: DocumentVersion
    public var contentState: DocumentContentStateID
    public var fileIdentity: DocumentFileIdentity?
    public var text: String

    public init(
        uri: DocumentURI,
        version: DocumentVersion,
        contentState: DocumentContentStateID,
        fileIdentity: DocumentFileIdentity? = nil,
        text: String
    ) {
        self.uri = uri
        self.version = version
        self.contentState = contentState
        self.fileIdentity = fileIdentity
        self.text = text
    }
}

public enum SearchReplaceError: Error, Sendable, Equatable {
    case missingPinnedText(uri: String)
    case rangeOutOfBounds(uri: String)
    case matchNoLongerValid(uri: String)
    case contentStateMismatch(uri: String)
    case versionMismatch(uri: String, expected: UInt64, actual: UInt64)
    case invalidRegex(String)
}

public enum SearchReplaceBuilder {
    /// Builds a ``WorkspaceEdit`` grouping matches by URI with high→low ranges.
    ///
    /// Uses pinned document text / versions when present (SRCH-N09). Regex replacement
    /// reuses the **exact** match ranges against pinned text — never a second free-text find
    /// (SRCH-N08).
    public static func makeWorkspaceEdit(
        plan: SearchReplacePlan,
        openDocumentVersions: [DocumentURI: DocumentVersion] = [:],
        documentTexts: [DocumentURI: String] = [:],
        preserveCase: Bool = false
    ) throws -> WorkspaceEdit {
        let byURI = Dictionary(grouping: plan.matches, by: \.uri)
        var documentChanges: [DocumentChange] = []

        for (uri, matches) in byURI {
            let ordered = matches.sorted {
                $0.range.location > $1.range.location
            }
            let pinned = plan.pinnedDocuments[uri]
            let fullText = pinned?.text ?? documentTexts[uri]
            var textChanges: [TextChange] = []
            for match in ordered {
                let newText = try replacementText(
                    for: match,
                    template: plan.replacement,
                    query: plan.query,
                    fullText: fullText,
                    preserveCase: preserveCase
                )
                textChanges.append(
                    TextChange(
                        replacedRange: match.range,
                        replacement: newText
                    )
                )
            }
            guard !textChanges.isEmpty else { continue }
            let expectedVersion = pinned?.version ?? openDocumentVersions[uri]
            documentChanges.append(
                DocumentChange(
                    uri: uri,
                    expectedVersion: expectedVersion,
                    expectedFileIdentity: pinned?.fileIdentity,
                    transaction: EditTransaction(changes: textChanges, origin: .programmatic)
                )
            )
        }
        return WorkspaceEdit(documentChanges: documentChanges)
    }

    /// Computes the replacement string for a single match (preview UI + apply).
    public static func replacementText(
        for match: SearchMatch,
        template: String,
        query: SearchQuery,
        fullText: String? = nil,
        preserveCase: Bool = false
    ) throws -> String {
        let isRegex = query.isRegex || query.matchMode == .regularExpression

        if isRegex {
            // SRCH-N08: require pinned full text — never preview-string re-find fallback.
            guard let fullText else {
                throw SearchReplaceError.missingPinnedText(uri: match.uri.rawValue)
            }
            let newText = try regexReplaceUsingExactRange(
                match: match,
                template: template,
                query: query,
                fullText: fullText
            )
            if preserveCase {
                let matched = substring(fullText, range: match.range)
                    ?? match.preview
                return applyPreserveCase(matched: matched, replacement: newText)
            }
            return newText
        }

        // Literal replace: use template; optional preserve-case from exact range slice.
        var newText = template
        if preserveCase {
            let matched: String
            if let fullText, let slice = substring(fullText, range: match.range) {
                matched = slice
            } else {
                matched = match.preview
            }
            newText = applyPreserveCase(matched: matched, replacement: newText)
        }
        return newText
    }

    /// Xcode-style preserve case: mirror ALL CAPS / Title / lower of the original match.
    public static func applyPreserveCase(matched: String, replacement: String) -> String {
        guard !matched.isEmpty, !replacement.isEmpty else { return replacement }
        let letters = matched.filter(\.isLetter)
        guard !letters.isEmpty else { return replacement }

        if letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if letters.allSatisfy(\.isLowercase) {
            return replacement.lowercased()
        }
        if let first = matched.first, first.isUppercase {
            let rest = replacement.dropFirst()
            return String(replacement.prefix(1)).uppercased() + rest.lowercased()
        }
        return replacement
    }

    // MARK: - Regex replace (SRCH-N08)

    /// Apply template against the **exact** match range using `NSRegularExpression` capture
    /// expansion (`$n`, `$0`, `${name}`, `$$`).
    private static func regexReplaceUsingExactRange(
        match: SearchMatch,
        template: String,
        query: SearchQuery,
        fullText: String
    ) throws -> String {
        let ns = fullText as NSString
        let r = match.range.nsRange
        guard r.location >= 0,
            let end = try? TextOffsetSemantics.utf16EndOffset(location: r.location, length: r.length),
            end <= ns.length,
            let validated = try? TextOffsetSemantics.validatedUTF16Range(
                r,
                documentUTF16Length: ns.length
            )
        else {
            throw SearchReplaceError.rangeOutOfBounds(uri: match.uri.rawValue)
        }

        let regex: NSRegularExpression
        do {
            regex = try WorkspaceSearchService.makeRegex(query)
        } catch {
            throw SearchReplaceError.invalidRegex(String(describing: error))
        }

        // Re-match at the exact range — never re-find elsewhere (SRCH-N08).
        // For zero-width matches the validated length is 0; search from that location
        // with remaining document length so lookarounds can succeed.
        let searchLocation = validated.location
        let searchLength = max(validated.length, ns.length - searchLocation)
        let searchRange = NSRange(location: searchLocation, length: searchLength)
        guard
            let result = regex.firstMatch(in: fullText, options: [], range: searchRange),
            result.range.location == validated.location,
            result.range.length == validated.length
        else {
            throw SearchReplaceError.matchNoLongerValid(uri: match.uri.rawValue)
        }

        return expandReplacementTemplate(
            template,
            match: result,
            fullText: fullText,
            regex: regex
        )
    }

    /// Expand `$n`, `$0`, `${name}`, and `$$` against a regex match (SRCH-N08).
    ///
    /// Foundation’s `replacementString` mishandles some `$` sequences and does not
    /// expand named groups portably — we implement the documented grammar here.
    static func expandReplacementTemplate(
        _ template: String,
        match: NSTextCheckingResult,
        fullText: String,
        regex: NSRegularExpression
    ) -> String {
        let ns = fullText as NSString
        var out = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c != "$" {
                out.append(c)
                i += 1
                continue
            }
            // `$` at end → literal
            if i + 1 >= chars.count {
                out.append("$")
                i += 1
                continue
            }
            let next = chars[i + 1]
            // `$$` → literal `$`
            if next == "$" {
                out.append("$")
                i += 2
                continue
            }
            // `${name}` named capture
            if next == "{" {
                if let close = chars[(i + 2)...].firstIndex(of: "}") {
                    let nameChars = chars[(i + 2)..<close]
                    let name = String(nameChars)
                    if let groupIndex = namedGroupIndex(name: name, in: regex),
                        groupIndex <= match.numberOfRanges
                    {
                        let r = match.range(at: groupIndex)
                        if r.location != NSNotFound {
                            out += ns.substring(with: r)
                        }
                    }
                    i = close + 1
                    continue
                }
                // Unclosed brace — literal
                out.append("$")
                i += 1
                continue
            }
            // `$n` / `$nn` numbered capture (including `$0` whole match)
            if next.isNumber {
                var j = i + 1
                while j < chars.count, chars[j].isNumber {
                    j += 1
                }
                // Prefer longest valid group index, then shorter (PCRE/ICU style).
                var digits = String(chars[(i + 1)..<j])
                var digitEnd = j
                var resolved = false
                while !digits.isEmpty {
                    if let g = Int(digits), g >= 0, g < match.numberOfRanges {
                        let r = match.range(at: g)
                        if r.location != NSNotFound {
                            out += ns.substring(with: r)
                        }
                        i = digitEnd
                        resolved = true
                        break
                    }
                    digits = String(digits.dropLast())
                    digitEnd -= 1
                }
                if resolved {
                    continue
                }
                // No valid group — emit `$` literally and continue
                out.append("$")
                i += 1
                continue
            }
            // Unknown `$X` — literal `$`
            out.append("$")
            i += 1
        }
        return out
    }

    /// Resolve named capture index from the pattern string (`(?<name>…)` / `(?'name'…)`).
    private static func namedGroupIndex(name: String, in regex: NSRegularExpression) -> Int? {
        let pattern = regex.pattern
        // Scan for (?<name> or (?'name'
        var groupNumber = 0  // 0 = whole match; capturing groups start at 1
        var i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] == "(", pattern.index(after: i) < pattern.endIndex {
                let after = pattern.index(after: i)
                // Non-capturing / lookaround
                if pattern[after] == "?" {
                    let q = pattern.index(after: after)
                    if q < pattern.endIndex {
                        if pattern[q] == ":" || pattern[q] == "=" || pattern[q] == "!"
                            || pattern[q] == "<" && pattern.index(after: q) < pattern.endIndex
                                && (pattern[pattern.index(after: q)] == "="
                                    || pattern[pattern.index(after: q)] == "!")
                        {
                            i = after
                            continue
                        }
                        // Named: (?<name> or (?'name'
                        if pattern[q] == "<" || pattern[q] == "'" {
                            let delim = pattern[q]
                            let endDelim: Character = delim == "<" ? ">" : "'"
                            let nameStart = pattern.index(after: q)
                            if let nameEnd = pattern[nameStart...].firstIndex(of: endDelim) {
                                let found = String(pattern[nameStart..<nameEnd])
                                groupNumber += 1
                                if found == name { return groupNumber }
                                i = nameEnd
                                continue
                            }
                        }
                    }
                    i = after
                    continue
                }
                // Capturing group
                groupNumber += 1
            }
            // Skip character classes roughly
            if pattern[i] == "\\" {
                i = pattern.index(after: i)
                if i < pattern.endIndex { i = pattern.index(after: i) }
                continue
            }
            i = pattern.index(after: i)
        }
        return nil
    }

    private static func substring(_ text: String, range: CodeEditorCore.TextRange) -> String? {
        let ns = text as NSString
        let r = range.nsRange
        guard r.location >= 0,
            let end = try? TextOffsetSemantics.utf16EndOffset(location: r.location, length: r.length),
            end <= ns.length,
            let validated = try? TextOffsetSemantics.validatedUTF16Range(
                r,
                documentUTF16Length: ns.length
            )
        else {
            return nil
        }
        return ns.substring(with: validated)
    }
}
