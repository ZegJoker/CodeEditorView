import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Observation

// MARK: - Required navigator inventory (WB-010 / Phase 10 E1)

/// Canonical navigator contribution IDs for an Xcode-like workbench.
public enum WorkbenchNavigatorID: String, CaseIterable, Sendable {
    case files = "workbench.navigator.files"
    case symbols = "workbench.navigator.symbols"
    case search = "workbench.navigator.search"
    case issues = "workbench.navigator.issues"
    case tests = "workbench.navigator.tests"
    case debug = "workbench.navigator.debug"
    case scm = "workbench.navigator.scm"
    case breakpoints = "workbench.navigator.breakpoints"

    /// Host may use a product-prefixed alias; still counts toward completeness when registered.
    public var aliases: [String] {
        switch self {
        case .search: return ["fullworkbench.navigator.find"]
        case .scm: return ["fullworkbench.navigator.scm"]
        default: return []
        }
    }

    public static func isCovered(by registeredIDs: Set<String>) -> Bool {
        for nav in allCases {
            if registeredIDs.contains(nav.rawValue) { continue }
            if nav.aliases.contains(where: { registeredIDs.contains($0) }) { continue }
            return false
        }
        return true
    }
}

// MARK: - Scheme / run destination (WB-012)

public struct WorkbenchRunDestination: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct WorkbenchScheme: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var buildTaskID: String?
    public var testTaskID: String?
    public var runTaskID: String?
    public var debugSessionName: String?

    public init(
        id: String,
        name: String,
        buildTaskID: String? = nil,
        testTaskID: String? = nil,
        runTaskID: String? = nil,
        debugSessionName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.buildTaskID = buildTaskID
        self.testTaskID = testTaskID
        self.runTaskID = runTaskID
        self.debugSessionName = debugSessionName
    }
}

@MainActor
@Observable
public final class WorkbenchSchemeModel {
    public private(set) var schemes: [WorkbenchScheme] = []
    public private(set) var destinations: [WorkbenchRunDestination] = []
    public var selectedSchemeID: String?
    public var selectedDestinationID: String?
    /// Last action outcome for tests/UI status.
    public private(set) var lastAction: String?
    public private(set) var lastError: String?

    public init() {}

    public func setSchemes(_ schemes: [WorkbenchScheme]) {
        self.schemes = schemes
        if selectedSchemeID == nil { selectedSchemeID = schemes.first?.id }
    }

    public func setDestinations(_ destinations: [WorkbenchRunDestination]) {
        self.destinations = destinations
        if selectedDestinationID == nil { selectedDestinationID = destinations.first?.id }
    }

    public var selectedScheme: WorkbenchScheme? {
        schemes.first { $0.id == selectedSchemeID }
    }

    public var selectedDestination: WorkbenchRunDestination? {
        destinations.first { $0.id == selectedDestinationID }
    }

    public enum SchemeAction: String, Sendable {
        case build, test, run
    }

    /// Resolves the task id for an action; throws if scheme missing or task unset.
    public func taskID(for action: SchemeAction) throws -> String {
        guard let scheme = selectedScheme else {
            throw WorkbenchChromeError.noScheme
        }
        let id: String?
        switch action {
        case .build: id = scheme.buildTaskID
        case .test: id = scheme.testTaskID
        case .run: id = scheme.runTaskID
        }
        guard let id, !id.isEmpty else {
            throw WorkbenchChromeError.noTask(action.rawValue)
        }
        lastAction = action.rawValue
        lastError = nil
        return id
    }

    public func recordError(_ message: String) {
        lastError = message
    }
}

public enum WorkbenchChromeError: Error, Sendable, Equatable {
    case noScheme
    case noTask(String)
    case untrusted
}

// MARK: - Activity / progress (WB-013)

public struct WorkbenchActivityItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var isCancellable: Bool
    public var progress: Double?

    public init(id: String, title: String, isCancellable: Bool = true, progress: Double? = nil) {
        self.id = id
        self.title = title
        self.isCancellable = isCancellable
        self.progress = progress
    }
}

@MainActor
@Observable
public final class WorkbenchActivityModel {
    public private(set) var items: [WorkbenchActivityItem] = []
    public private(set) var cancelledIDs: Set<String> = []

    public init() {}

    public func begin(id: String, title: String, cancellable: Bool = true) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].title = title
            items[idx].isCancellable = cancellable
        } else {
            items.append(WorkbenchActivityItem(id: id, title: title, isCancellable: cancellable))
        }
        cancelledIDs.remove(id)
    }

    public func updateProgress(id: String, progress: Double) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].progress = min(1, max(0, progress))
    }

    public func end(id: String) {
        items.removeAll { $0.id == id }
        cancelledIDs.remove(id)
    }

    @discardableResult
    public func cancel(id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.isCancellable else { return false }
        cancelledIDs.insert(id)
        items.removeAll { $0.id == id }
        // Keep id in cancelledIDs for observers (do not call end which clears it).
        return true
    }

    public var isBusy: Bool { !items.isEmpty }
}

// MARK: - Status metrics (WB-013) — line/col via LineIndex, not full scan

public enum WorkbenchStatusMetrics {
    /// O(log n) line/column from a UTF-16 caret offset using ``LineIndex``.
    public static func lineColumn(text: String, utf16Offset: Int) -> (line: Int, column: Int) {
        final class EmptyPayload: LinePayload {
            var id: ObjectIdentifier { ObjectIdentifier(self) }
        }
        let index = LineIndex<EmptyPayload>.build(
            from: text,
            estimatedLineHeight: 1,
            makePayload: { _ in EmptyPayload() }
        )
        let loc = min(max(0, utf16Offset), (text as NSString).length)
        guard let line = index.line(atUTF16Offset: loc) else {
            return (1, 1)
        }
        let col = max(1, loc - line.utf16Offset + 1)
        return (line.index + 1, col)
    }

    public static func label(text: String, utf16Offset: Int) -> String {
        let lc = lineColumn(text: text, utf16Offset: utf16Offset)
        return "Ln \(lc.line), Col \(lc.column)"
    }
}

// MARK: - Symbols navigator model (WB-010)

public struct WorkbenchSymbolItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: String
    public var path: String
    public var line: Int
    public var column: Int

    public init(id: String = UUID().uuidString, name: String, kind: String, path: String, line: Int, column: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
        self.column = column
    }
}

@MainActor
@Observable
public final class WorkbenchSymbolsModel {
    public private(set) var symbols: [WorkbenchSymbolItem] = []
    public private(set) var errorMessage: String?
    public var filter: String = ""

    public init() {}

    public func setSymbols(_ symbols: [WorkbenchSymbolItem]) {
        self.symbols = symbols
        errorMessage = nil
    }

    public func setError(_ message: String) {
        errorMessage = message
        symbols = []
    }

    public var filtered: [WorkbenchSymbolItem] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return symbols }
        return symbols.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }
}

// MARK: - Breakpoints (WB-010)

public struct WorkbenchBreakpointItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var path: String
    public var line: Int
    public var enabled: Bool
    public var condition: String?

    public init(
        id: String = UUID().uuidString,
        path: String,
        line: Int,
        enabled: Bool = true,
        condition: String? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.enabled = enabled
        self.condition = condition
    }
}

@MainActor
@Observable
public final class WorkbenchBreakpointsModel {
    public private(set) var breakpoints: [WorkbenchBreakpointItem] = []

    public init() {}

    public func upsert(_ item: WorkbenchBreakpointItem) {
        if let idx = breakpoints.firstIndex(where: { $0.id == item.id }) {
            breakpoints[idx] = item
        } else if let idx = breakpoints.firstIndex(where: { $0.path == item.path && $0.line == item.line }) {
            breakpoints[idx] = item
        } else {
            breakpoints.append(item)
        }
    }

    public func remove(id: String) {
        breakpoints.removeAll { $0.id == id }
    }

    public func setEnabled(id: String, enabled: Bool) {
        guard let idx = breakpoints.firstIndex(where: { $0.id == id }) else { return }
        breakpoints[idx].enabled = enabled
    }

    public func clear() { breakpoints = [] }
}

// MARK: - Tests navigator (WB-010)

public struct WorkbenchTestItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var state: String  // pending | running | passed | failed
    public var message: String?

    public init(id: String, name: String, state: String = "pending", message: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.message = message
    }
}

@MainActor
@Observable
public final class WorkbenchTestsModel {
    public private(set) var tests: [WorkbenchTestItem] = []
    public private(set) var lastRunTaskID: String?

    public init() {}

    public func setTests(_ tests: [WorkbenchTestItem]) {
        self.tests = tests
    }

    public func upsert(_ item: WorkbenchTestItem) {
        if let idx = tests.firstIndex(where: { $0.id == item.id }) {
            tests[idx] = item
        } else {
            tests.append(item)
        }
    }

    public func markRunning(taskID: String) {
        lastRunTaskID = taskID
        tests = tests.map {
            var t = $0
            t.state = "running"
            return t
        }
    }
}

// MARK: - Chrome command IDs (WB-014)

public enum WorkbenchChromeCommand: String, CaseIterable, Sendable {
    case showFilesNavigator = "workbench.navigator.files.focus"
    case showSymbolsNavigator = "workbench.navigator.symbols.focus"
    case showSearchNavigator = "workbench.navigator.search.focus"
    case showIssuesNavigator = "workbench.navigator.issues.focus"
    case showTestsNavigator = "workbench.navigator.tests.focus"
    case showDebugNavigator = "workbench.navigator.debug.focus"
    case showSCMNavigator = "workbench.navigator.scm.focus"
    case showBreakpointsNavigator = "workbench.navigator.breakpoints.focus"
    case schemeBuild = "workbench.scheme.build"
    case schemeTest = "workbench.scheme.test"
    case schemeRun = "workbench.scheme.run"
    case pinActiveTab = "workbench.tab.pin"
    case toggleTerminal = "workbench.utility.terminal.focus"
    case scmRefresh = "workbench.scm.refresh"

    public var commandID: CommandID { CommandID(stringLiteral: rawValue) }
}

// MARK: - Tab pin helper (WB-011)

public enum WorkbenchTabSemantics {
    /// Promote preview tab to permanent (e.g. after edit).
    public static func promotePreviewIfNeeded(tab: inout EditorTab) {
        if tab.isPreview {
            tab.isPreview = false
        }
    }

    public static func pin(tab: inout EditorTab) {
        tab.isPinned = true
        tab.isPreview = false
    }
}
