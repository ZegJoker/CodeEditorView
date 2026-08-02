import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Observation

public enum OpenQuicklyMode: String, Sendable, Hashable, CaseIterable {
    case file
    case symbol
    case command
}

public struct OpenQuicklyItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var uri: DocumentURI?
    public var name: String
    public var path: String
    public var mode: OpenQuicklyMode
    /// Zero-based line when opened via `path:line:col` or symbol.
    public var line: Int?
    public var column: Int?

    public init(
        id: String? = nil,
        uri: DocumentURI?,
        name: String,
        path: String,
        mode: OpenQuicklyMode = .file,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.uri = uri
        self.name = name
        self.path = path
        self.mode = mode
        self.line = line
        self.column = column
        self.id = id ?? (uri?.rawValue ?? "\(mode.rawValue):\(path):\(name)")
    }
}

@MainActor
@Observable
public final class OpenQuicklyModel {
    public var query: String = "" {
        didSet {
            if query != oldValue {
                scheduleFilter()
            }
        }
    }
    public var mode: OpenQuicklyMode = .file {
        didSet {
            if mode != oldValue { scheduleFilter() }
        }
    }
    public private(set) var results: [OpenQuicklyItem] = []
    public private(set) var isScanning: Bool = false
    /// Keyboard / list highlight index into ``results``.
    public var selectedIndex: Int = 0
    public var resultLimit: Int = 50
    /// Injected index service (default file-tree index).
    public var indexService: any WorkspaceIndexService = FileTreeIndexService()
    /// Symbol catalog for symbol mode (host/LSP fills).
    public var symbolItems: [OpenQuicklyItem] = []
    /// Command catalog for command mode.
    public var commandItems: [OpenQuicklyItem] = []

    private var allItems: [OpenQuicklyItem] = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0

    public init() {}

    public func resetPresentation() {
        query = ""
        selectedIndex = 0
        results = Array(allItems.prefix(resultLimit))
    }

    /// Parse `path:line` or `path:line:column` suffix (1-based line/col → 0-based stored).
    public static func parseLocationQuery(_ raw: String) -> (path: String, line: Int?, column: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return (trimmed, nil, nil) }
        // path:line:col
        if parts.count >= 3,
            let col = Int(parts[parts.count - 1]),
            let line = Int(parts[parts.count - 2]),
            col >= 0, line >= 1
        {
            let path = parts.dropLast(2).joined(separator: ":")
            if !path.isEmpty {
                return (path, line - 1, max(0, col - 1))
            }
        }
        // path:line
        if let line = Int(parts[parts.count - 1]), line >= 1 {
            let path = parts.dropLast().joined(separator: ":")
            if !path.isEmpty {
                return (path, line - 1, nil)
            }
        }
        return (trimmed, nil, nil)
    }

    /// Rebuilds the file index via ``indexService`` (cancellable).
    public func recompute(workspace: Workspace) async {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }

        let service = indexService
        do {
            let items = try await service.rebuild(workspace: workspace)
            guard generation == scanGeneration else { return }
            allItems = items
            applyFilter()
        } catch is CancellationError {
            return
        } catch {
            guard generation == scanGeneration else { return }
            // Keep previous index on failure.
            applyFilter()
        }
    }

    public var selectedItem: OpenQuicklyItem? {
        guard results.indices.contains(selectedIndex) else { return results.first }
        return results[selectedIndex]
    }

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selectedIndex = 0
            return
        }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(results.count - 1, next))
    }

    public func selectIndex(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    private func scheduleFilter() {
        applyFilter()
    }

    private func applyFilter() {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let corpus: [OpenQuicklyItem]
        switch mode {
        case .file: corpus = allItems
        case .symbol: corpus = symbolItems
        case .command: corpus = commandItems
        }
        if raw.isEmpty {
            results = Array(corpus.prefix(resultLimit))
            selectedIndex = 0
            return
        }

        // path:line:col handling (file mode)
        var q = raw
        var forcedLine: Int?
        var forcedCol: Int?
        if mode == .file {
            let parsed = Self.parseLocationQuery(raw)
            if parsed.line != nil {
                q = parsed.path
                forcedLine = parsed.line
                forcedCol = parsed.column
            }
        }

        let ranked = corpus.compactMap { item -> (OpenQuicklyItem, Int)? in
            guard let score = Self.fuzzyScore(query: q, name: item.name, path: item.path) else {
                return nil
            }
            var copy = item
            if let forcedLine {
                copy.line = forcedLine
                copy.column = forcedCol
            }
            return (copy, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.name.count != rhs.0.name.count {
                return lhs.0.name.count < rhs.0.name.count
            }
            return lhs.0.path.localizedCaseInsensitiveCompare(rhs.0.path) == .orderedAscending
        }
        results = Array(ranked.prefix(resultLimit).map(\.0))
        selectedIndex = 0
    }

    /// Subsequence fuzzy score. Higher is better. `nil` = no match.
    public static func fuzzyScore(query: String, name: String, path: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }

        let nameScore = subsequenceScore(query: q, in: name, baseBonus: 120)
        let pathScore = subsequenceScore(query: q, in: path, baseBonus: 40)

        switch (nameScore, pathScore) {
        case (let n?, let p?):
            return max(n, p)
        case (let n?, nil):
            return n
        case (nil, let p?):
            return p
        case (nil, nil):
            return nil
        }
    }

    private static func subsequenceScore(query: [Character], in text: String, baseBonus: Int) -> Int? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }

        var qi = 0
        var score = 0
        var consecutive = 0
        var lastMatch = -2
        var firstMatchIndex: Int?

        for (ti, ch) in chars.enumerated() {
            guard qi < query.count else { break }
            guard ch.lowercased() == String(query[qi]) else {
                consecutive = 0
                continue
            }
            if firstMatchIndex == nil { firstMatchIndex = ti }
            var points = baseBonus
            if ti == lastMatch + 1 {
                consecutive += 1
                points += 25 * consecutive
            } else {
                consecutive = 1
            }
            if ti == 0 {
                points += 40
            } else {
                let prev = chars[ti - 1]
                if prev == "/" || prev == "." || prev == "_" || prev == "-" || prev == " " {
                    points += 30
                } else if prev.isLowercase && ch.isUppercase {
                    points += 25
                }
            }
            if ti == firstMatchIndex {
                points += max(0, 20 - ti)
            }
            score += points
            lastMatch = ti
            qi += 1
        }
        return qi == query.count ? score : nil
    }
}
