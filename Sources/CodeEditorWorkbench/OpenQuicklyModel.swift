import Foundation
import Observation
import CodeEditorDocuments
import CodeEditorWorkspace

public struct OpenQuicklyItem: Identifiable, Hashable, Sendable {
    public var id: DocumentURI { uri }
    public var uri: DocumentURI
    public var name: String
    public var path: String

    public init(uri: DocumentURI, name: String, path: String) {
        self.uri = uri
        self.name = name
        self.path = path
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
    public private(set) var results: [OpenQuicklyItem] = []
    public private(set) var isScanning: Bool = false
    /// Keyboard / list highlight index into ``results``.
    public var selectedIndex: Int = 0

    private var allItems: [OpenQuicklyItem] = []
    private var scanTask: Task<Void, Never>?
    public var resultLimit: Int = 50

    public init() {}

    public func resetPresentation() {
        query = ""
        selectedIndex = 0
        results = Array(allItems.prefix(resultLimit))
    }

    public func recompute(workspace: Workspace) async {
        scanTask?.cancel()
        isScanning = true
        defer { isScanning = false }

        var collected: [OpenQuicklyItem] = []
        for root in workspace.fileSystem.roots {
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            try? await collectFiles(
                from: rootItem,
                rootName: root.name,
                workspace: workspace,
                into: &collected,
                depth: 0,
                maxDepth: 12
            )
            if Task.isCancelled { return }
        }
        allItems = collected
        applyFilter()
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            results = Array(allItems.prefix(resultLimit))
            selectedIndex = 0
            return
        }
        let ranked = allItems.compactMap { item -> (OpenQuicklyItem, Int)? in
            guard let score = Self.fuzzyScore(query: q, name: item.name, path: item.path) else {
                return nil
            }
            return (item, score)
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
    /// Prefers consecutive runs, word/camel starts, and matches in the file name over path.
    public static func fuzzyScore(query: String, name: String, path: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }

        let nameScore = subsequenceScore(query: q, in: name, baseBonus: 120)
        let pathScore = subsequenceScore(query: q, in: path, baseBonus: 40)

        switch (nameScore, pathScore) {
        case let (n?, p?):
            return max(n, p)
        case let (n?, nil):
            return n
        case let (nil, p?):
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
            // Case-insensitive match; keep original case for boundary bonuses.
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
            // Word / path / camelCase boundary bonus.
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
            // Prefer earlier first match.
            if ti == firstMatchIndex {
                points += max(0, 20 - ti)
            }
            score += points
            lastMatch = ti
            qi += 1
        }

        guard qi == query.count else { return nil }
        // Shorter candidates win ties later; slight penalty for long remaining tail.
        score -= max(0, chars.count - query.count) / 4
        // Exact name-like prefix boost (case-insensitive).
        if text.lowercased().hasPrefix(String(query)) {
            score += 80
        }
        return score
    }

    private func collectFiles(
        from item: WorkspaceItemID,
        rootName: String,
        workspace: Workspace,
        into collected: inout [OpenQuicklyItem],
        depth: Int,
        maxDepth: Int
    ) async throws {
        guard depth <= maxDepth, !Task.isCancelled else { return }
        let children = try await workspace.fileSystem.children(of: item)
        for child in children {
            if Task.isCancelled { return }
            if child.isDirectory {
                try await collectFiles(
                    from: child.id,
                    rootName: rootName,
                    workspace: workspace,
                    into: &collected,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
            } else {
                let displayPath = child.id.path.isEmpty ? child.name : "\(rootName)/\(child.id.path)"
                collected.append(
                    OpenQuicklyItem(uri: child.uri, name: child.name, path: displayPath)
                )
            }
        }
    }
}
