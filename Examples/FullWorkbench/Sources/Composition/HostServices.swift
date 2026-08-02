import Foundation
import Observation
import CodeEditorCore
import CodeEditorWorkbench
import CodeEditorWorkspace
import CodeEditorDocuments
import CodeEditorCommands
import CodeEditorSearch
import CodeEditorTasks
import CodeEditorSourceControl
import CodeEditorTerminal
import CodeEditorLanguageServices

/// MainActor host bag: owns tooling services and UI state for FullWorkbench contributions.
@MainActor
@Observable
final class HostServices {
    let rootURL: URL
    private(set) weak var workbench: WorkbenchModel?

    let searchService: WorkspaceSearchService
    let scm: SourceControlService
    let tasks: TaskService
    let terminal: TerminalSessionManager
    let languageRegistry: LanguageServiceRegistry
    let outputChannel: OutputChannel
    private let outputRegistry: OutputChannelRegistry
    private let diagnosticsSink: HostDiagnosticsSink

    // MARK: - Search UI state
    var searchPattern: String = ""
    var replacePattern: String = ""
    var isReplaceMode: Bool = false
    /// Xcode-style find option toggles (Aa / ab / .*).
    var searchCaseSensitive: Bool = false
    var searchWholeWord: Bool = false
    var searchIsRegex: Bool = false
    /// Replace field “AB” — adapt replacement casing to each match.
    var searchPreserveCase: Bool = false
    var searchMatches: [SearchMatch] = []
    /// Index into flattened search order for replace-next (Enter in Replace field).
    var replaceCursor: Int = 0
    var searchStatus: String = ""
    var isSearching: Bool = false
    var expandedSearchFiles: Set<String> = []
    private var searchTask: Task<Void, Never>?
    /// Workspace-level undo/redo for Find & Replace (works without focusing an editor).
    private var replaceUndoStack: [WorkspaceEdit] = []
    private var replaceRedoStack: [WorkspaceEdit] = []

    var canUndoReplace: Bool { !replaceUndoStack.isEmpty }
    var canRedoReplace: Bool { !replaceRedoStack.isEmpty }

    /// Builds the query from current Find navigator options.
    func makeSearchQuery(pattern: String) -> SearchQuery {
        let mode: SearchMatchMode
        if searchIsRegex {
            mode = .regularExpression
        } else if searchWholeWord {
            mode = .matchesWord
        } else {
            mode = .contains
        }
        return SearchQuery(
            pattern: pattern,
            matchMode: mode,
            caseSensitive: searchCaseSensitive,
            isRegex: searchIsRegex,
            wholeWord: searchWholeWord
        )
    }

    // MARK: - SCM UI state
    var scmStatuses: [SCMFileStatus] = []
    var scmBranch: String?
    var scmError: String?

    // MARK: - Problems / output
    var problems: [HostProblem] = []
    var outputLines: [OutputLine] = []

    // MARK: - Terminal UI state
    var terminalOutput: String = ""
    var terminalInput: String = ""
    var terminalSessionID: TerminalSessionID?
    var terminalStatus: String = "Not started"
    private var terminalListenTask: Task<Void, Never>?
    private let terminalBackend = ProcessTerminalBackend()

    private var commandTokens: [any CommandDisposable] = []
    private var contributionTokens: [any CommandDisposable] = []

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.searchService = WorkspaceSearchService(
            context: WorkspaceSearchContext(rootDirectories: [rootURL])
        )
        self.scm = SourceControlService()
        self.outputRegistry = OutputChannelRegistry()
        self.tasks = TaskService(channels: outputRegistry)
        self.terminal = TerminalSessionManager()
        self.languageRegistry = LanguageServiceRegistry()
        self.diagnosticsSink = HostDiagnosticsSink()
        self.outputChannel = OutputChannel(id: "workbench.output", name: "Output")
        // OutputChannelRegistry is actor — seed via task after init
    }

    func attach(to workbench: WorkbenchModel) async {
        self.workbench = workbench
        diagnosticsSink.host = self
        await tasks.setDiagnosticsSink(diagnosticsSink)

        // Seed output registry channel used by demo task.
        _ = await outputRegistry.channel(id: "workbench.output", name: "Output")

        // Replace placeholder utilities with host panels.
        workbench.contributionRegistry.unregister(id: "workbench.utility.output")
        workbench.contributionRegistry.unregister(id: "workbench.utility.problems")
        workbench.contributionRegistry.unregister(id: "workbench.utility.terminal")

        // Host find navigator replaces shell search; keep Phase 10 IDs covered via aliases + host find.
        workbench.contributionRegistry.unregister(id: WorkbenchNavigatorID.search.rawValue)
        workbench.contributionRegistry.unregister(id: WorkbenchNavigatorID.scm.rawValue)
        contributionTokens.append(workbench.contributionRegistry.register(FindNavigatorContribution(host: self)))
        contributionTokens.append(workbench.contributionRegistry.register(SCMNavigatorContribution(host: self)))
        contributionTokens.append(workbench.contributionRegistry.register(OutputUtilityContribution(host: self)))
        contributionTokens.append(workbench.contributionRegistry.register(ProblemsUtilityContribution(host: self)))
        contributionTokens.append(workbench.contributionRegistry.register(TerminalUtilityContribution(host: self)))
        contributionTokens.append(workbench.contributionRegistry.register(SCMStatusContribution(host: self)))

        workbench.ensureActiveNavigator()
        workbench.ensureActiveUtility()

        // Schemes for build/test/run (Phase 10).
        workbench.schemes.setSchemes([
            WorkbenchScheme(
                id: "sample",
                name: "Sample",
                buildTaskID: "sample.build",
                testTaskID: "sample.test",
                runTaskID: "sample.echo",
                debugSessionName: "Sample Debug"
            )
        ])
        workbench.schemes.setDestinations([
            WorkbenchRunDestination(id: "my-mac", name: "My Mac")
        ])
        workbench.tests.setTests([
            WorkbenchTestItem(id: "sample.tests.main", name: "MainTests")
        ])
        workbench.symbols.setSymbols([
            WorkbenchSymbolItem(name: "main", kind: "func", path: "Main.swift", line: 0),
            WorkbenchSymbolItem(name: "Sample", kind: "type", path: "Main.swift", line: 0),
        ])
        workbench.openQuickly.symbolItems = workbench.symbols.symbols.map {
            OpenQuicklyItem(
                uri: DocumentURI(fileURL: rootURL.appendingPathComponent($0.path)),
                name: $0.name,
                path: $0.path,
                mode: .symbol,
                line: $0.line,
                column: $0.column
            )
        }
        workbench.openQuickly.commandItems = WorkbenchChromeCommand.allCases.map {
            OpenQuicklyItem(
                uri: nil,
                name: $0.rawValue,
                path: $0.rawValue,
                mode: .command
            )
        }

        // Tooling commands
        let cmds = workbench.commandDispatcher.commands
        commandTokens.append(SearchCommands.register(into: cmds, onFindInFiles: { [weak self] in
            self?.workbench?.selectNavigator(id: "fullworkbench.navigator.find")
        }))
        commandTokens.append(SCMCommands.register(into: cmds, onRefresh: { [weak self] in
            Task { await self?.refreshSCM() }
        }))
        commandTokens.append(TaskCommands.register(into: cmds, onRun: { [weak self] in
            Task { await self?.runDemoTask() }
        }))

        // Git provider if repo exists.
        await scm.setProvider(GitCLIProvider(repositoryRoot: rootURL, trusted: true))
        workbench.scmModel.trusted = true
        await refreshSCM()
        await workbench.scmModel.refresh(provider: GitCLIProvider(repositoryRoot: rootURL, trusted: true))

        // Terminal backend + session.
        await terminal.attach(backend: terminalBackend)
        await ensureTerminalSession()

        // Demo task: echo + fake diagnostic line for problems matcher.
        if let matcher = try? ProblemMatcher.swiftCompiler() {
            await tasks.registerMatcher(matcher)
        }
        await tasks.register(
            TaskDefinition(
                id: "sample.echo",
                label: "Sample Echo",
                executable: "/bin/echo",
                arguments: ["Hello from FullWorkbench task"],
                cwd: rootURL,
                group: .build
            )
        )
        await tasks.register(
            TaskDefinition(
                id: "sample.build",
                label: "Sample Build",
                executable: "/bin/echo",
                arguments: ["build ok"],
                cwd: rootURL,
                group: .build
            )
        )
        await tasks.register(
            TaskDefinition(
                id: "sample.test",
                label: "Sample Test",
                executable: "/bin/echo",
                arguments: ["test ok"],
                cwd: rootURL,
                group: .test
            )
        )
        await tasks.register(
            TaskDefinition(
                id: "sample.problems",
                label: "Sample Diagnostics",
                executable: "/bin/echo",
                arguments: ["\(rootURL.path)/Sources/Helper.swift:1:1: warning: sample diagnostic from task"],
                cwd: rootURL,
                problemMatchers: ["swift"],
                group: .build
            )
        )

        // Listen to output channel stream.
        Task { await self.pumpOutput() }

        appendOutput("Workspace ready: \(rootURL.lastPathComponent)", isError: false)
    }

    // MARK: - Search

    func runSearch() {
        searchTask?.cancel()
        let pattern = searchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            searchMatches = []
            expandedSearchFiles = []
            searchStatus = "Enter a pattern"
            return
        }
        isSearching = true
        searchMatches = []
        searchStatus = "Searching…"
        let openDocs = openDocumentsSnapshot()
        searchTask = Task {
            let ctx = WorkspaceSearchContext(rootDirectories: [rootURL], openDocuments: openDocs)
            let service = WorkspaceSearchService(context: ctx)
            let query = makeSearchQuery(pattern: pattern)
            var collected: [SearchMatch] = []
            do {
                for try await event in await service.search(query) {
                    if Task.isCancelled { break }
                    switch event {
                    case .match(let m):
                        collected.append(m)
                        if collected.count % 20 == 0 {
                            searchMatches = collected
                            expandAllSearchGroups(collected)
                        }
                    case .progress(let p):
                        searchStatus = "\(p.matchesFound) matches…"
                    case .finished(let filesWithMatches, let count):
                        let fileWord = filesWithMatches == 1 ? "file" : "files"
                        let matchWord = count == 1 ? "result" : "results"
                        searchStatus = "\(count) \(matchWord) in \(filesWithMatches) \(fileWord)"
                    }
                }
                searchMatches = collected
                expandAllSearchGroups(collected)
                replaceCursor = 0
                isSearching = false
            } catch {
                if !Task.isCancelled {
                    searchStatus = "Search failed: \(error.localizedDescription)"
                    isSearching = false
                }
            }
        }
    }

    private func expandAllSearchGroups(_ matches: [SearchMatch]) {
        expandedSearchFiles = Set(matches.map(\.fileGroupKey))
    }

    /// Flattened match order used by replace-next.
    var orderedSearchMatches: [SearchMatch] {
        searchGroups.flatMap(\.matches)
    }

    /// Matches grouped by file for Xcode-style outline.
    var searchGroups: [SearchFileGroup] {
        let grouped = Dictionary(grouping: searchMatches, by: \.fileGroupKey)
        return grouped.keys.sorted().compactMap { key in
            guard let matches = grouped[key], let first = matches.first else { return nil }
            let name = first.uri.fileURL?.lastPathComponent ?? first.uri.rawValue
            let path = first.uri.fileURL?.path ?? first.uri.rawValue
            return SearchFileGroup(
                id: key,
                fileName: name,
                path: path,
                matches: matches.sorted { $0.line < $1.line || ($0.line == $1.line && $0.column < $1.column) }
            )
        }
    }

    func openSearchMatch(_ match: SearchMatch) {
        if let idx = orderedSearchMatches.firstIndex(where: { $0.id == match.id }) {
            replaceCursor = idx
        }
        workbench?.openURI(match.uri, preview: true, selection: match.range)
        workbench?.statusMessage = "\(match.uri.fileURL?.lastPathComponent ?? "") :\(match.line + 1)"
    }

    /// Opens every file that has matches as permanent tabs; focuses the first match’s tab.
    func openAllSearchMatchesInEditor() {
        let groups = searchGroups
        guard let firstMatch = groups.first?.matches.first else { return }
        replaceCursor = 0
        Task {
            guard let workbench else { return }
            // Open other files first so the final open leaves the first file focused.
            for group in groups.dropFirst() {
                guard let uri = group.matches.first?.uri else { continue }
                _ = try? await workbench.workspace.openInActivePane(uri: uri, preview: false)
            }
            do {
                let opened = try await workbench.workspace.openInActivePane(
                    uri: firstMatch.uri,
                    preview: false
                )
                opened.session.selections = [firstMatch.range]
                workbench.statusMessage =
                    "Opened \(groups.count) file(s) · \(firstMatch.uri.fileURL?.lastPathComponent ?? "") :\(firstMatch.line + 1)"
            } catch {
                workbench.statusMessage = "Open failed: \(error.localizedDescription)"
            }
        }
    }

    /// Preview replacement string for a match (green side of red/green UI).
    func previewReplacement(for match: SearchMatch) -> String {
        let texts = documentTextsSnapshot()
        let query = makeSearchQuery(pattern: searchPattern)
        return (try? SearchReplaceBuilder.replacementText(
            for: match,
            template: replacePattern,
            query: query,
            fullText: texts[match.uri],
            preserveCase: searchPreserveCase
        )) ?? replacePattern
    }

    /// Enter in Replace field: replace current match, then advance to the next.
    func replaceNextMatch() {
        let ordered = orderedSearchMatches
        guard !ordered.isEmpty else {
            // No results yet — run search first, then user presses Enter again.
            runSearch()
            return
        }
        if replaceCursor >= ordered.count {
            replaceCursor = 0
        }
        let match = ordered[replaceCursor]
        Task {
            do {
                try await applyReplacements(matches: [match])
                // After one replace, re-search; cursor stays on “next” index.
                let nextIndex = replaceCursor
                runSearch()
                // Defer cursor adjustment until search completes (best-effort).
                try? await Task.sleep(nanoseconds: 150_000_000)
                if !searchMatches.isEmpty {
                    let ordered = orderedSearchMatches
                    replaceCursor = min(nextIndex, max(0, ordered.count - 1))
                    if replaceCursor < ordered.count {
                        openSearchMatch(ordered[replaceCursor])
                    }
                }
                searchStatus = "Replaced 1 occurrence"
            } catch {
                searchStatus = "Replace failed: \(error.localizedDescription)"
            }
        }
    }

    func replaceAllMatches() {
        guard !searchMatches.isEmpty else {
            searchStatus = "No matches to replace"
            return
        }
        let count = searchMatches.count
        Task {
            do {
                try await applyReplacements(matches: searchMatches)
                searchStatus = "Replaced \(count) occurrence(s)"
                runSearch()
            } catch {
                searchStatus = "Replace failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyReplacements(matches: [SearchMatch]) async throws {
        guard let workbench else { return }
        let plan = SearchReplacePlan(
            query: makeSearchQuery(pattern: searchPattern),
            replacement: replacePattern,
            matches: matches
        )
        var versions: [DocumentURI: DocumentVersion] = [:]
        var texts: [DocumentURI: String] = [:]
        for doc in workbench.workspace.documents.documents {
            versions[doc.uri] = doc.version
            texts[doc.uri] = doc.text
        }
        // Load any match files not yet open so we have text + can apply.
        for match in matches {
            if texts[match.uri] == nil {
                let doc = try await workbench.workspace.openDocument(uri: match.uri)
                texts[doc.uri] = doc.text
                versions[doc.uri] = doc.version
            }
        }
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            openDocumentVersions: versions,
            documentTexts: texts,
            preserveCase: searchPreserveCase
        )
        let service = WorkspaceEditService(workspace: workbench.workspace)
        let result = try await service.apply(edit)
        // Push inverse so ⌘Z undoes the whole replace without focusing a document first.
        replaceUndoStack.append(result.inverse)
        replaceRedoStack.removeAll()
        if let first = matches.first {
            workbench.openURI(first.uri, preview: false, selection: first.range)
        }
    }

    /// Undo the last Find & Replace (multi-file aware). Falls back to active-editor undo.
    func undo() {
        if let inverse = replaceUndoStack.popLast() {
            Task {
                do {
                    guard let workbench else { return }
                    let service = WorkspaceEditService(workspace: workbench.workspace)
                    // Refresh expected versions from live documents before applying inverse.
                    var edit = inverse
                    edit.documentChanges = inverse.documentChanges.map { change in
                        var c = change
                        if let doc = workbench.workspace.documents.document(uri: change.uri)
                            ?? change.documentID.flatMap({ workbench.workspace.documents.document(id: $0) }) {
                            c.expectedVersion = doc.version
                            c.documentID = doc.id
                        }
                        return c
                    }
                    let result = try await service.apply(edit)
                    replaceRedoStack.append(result.inverse)
                    searchStatus = "Undid replace"
                    runSearch()
                } catch {
                    searchStatus = "Undo failed: \(error.localizedDescription)"
                    // Put inverse back if apply failed.
                    replaceUndoStack.append(inverse)
                }
            }
            return
        }
        // No replace to undo — active document undo.
        guard let workbench,
              let context = workbench.makeCommandContext()
        else { return }
        try? workbench.commandDispatcher.execute(BuiltInCommandID.undo, context: context)
    }

    /// Redo the last undone Find & Replace, else active-editor redo.
    func redo() {
        if let redoEdit = replaceRedoStack.popLast() {
            Task {
                do {
                    guard let workbench else { return }
                    let service = WorkspaceEditService(workspace: workbench.workspace)
                    var edit = redoEdit
                    edit.documentChanges = redoEdit.documentChanges.map { change in
                        var c = change
                        if let doc = workbench.workspace.documents.document(uri: change.uri)
                            ?? change.documentID.flatMap({ workbench.workspace.documents.document(id: $0) }) {
                            c.expectedVersion = doc.version
                            c.documentID = doc.id
                        }
                        return c
                    }
                    let result = try await service.apply(edit)
                    replaceUndoStack.append(result.inverse)
                    searchStatus = "Redid replace"
                    runSearch()
                } catch {
                    searchStatus = "Redo failed: \(error.localizedDescription)"
                    replaceRedoStack.append(redoEdit)
                }
            }
            return
        }
        guard let workbench,
              let context = workbench.makeCommandContext()
        else { return }
        try? workbench.commandDispatcher.execute(BuiltInCommandID.redo, context: context)
    }

    private func documentTextsSnapshot() -> [DocumentURI: String] {
        guard let workbench else { return [:] }
        var map: [DocumentURI: String] = [:]
        for doc in workbench.workspace.documents.documents {
            map[doc.uri] = doc.text
        }
        return map
    }

    private func openDocumentsSnapshot() -> [DocumentURI: String] {
        guard let workbench else { return [:] }
        var map: [DocumentURI: String] = [:]
        for doc in workbench.workspace.documents.documents {
            map[doc.uri] = doc.text
        }
        return map
    }

    // MARK: - SCM

    func refreshSCM() async {
        do {
            scmStatuses = try await scm.refresh()
            let branches = try await scm.branches()
            scmBranch = branches.current
            scmError = nil
        } catch {
            scmError = error.localizedDescription
            scmStatuses = []
            scmBranch = nil
        }
    }

    func openSCMFile(_ status: SCMFileStatus) {
        workbench?.openURI(status.uri, preview: true)
    }

    // MARK: - Tasks / output / problems

    func runDemoTask() async {
        workbench?.selectUtility(id: "workbench.utility.output")
        workbench?.isUtilityVisible = true
        appendOutput("$ task sample.problems", isError: false)
        do {
            let run = try await tasks.run(id: "sample.problems")
            appendOutput("Task \(run.definitionID.rawValue) → \(run.state.rawValue)", isError: run.state == .failed)
            // Also pull channel output
            let ch = await outputRegistry.channel(id: "task.sample.problems", name: "Sample Diagnostics")
            for line in ch.snapshot {
                appendOutput(line.text, isError: line.isError)
            }
            await publishSampleProblemsFromOutput()
        } catch {
            appendOutput("Task failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func publishSampleProblemsFromOutput() async {
        // Diagnostics sink may have been called; also parse echo line ourselves for reliability.
        if let matcher = try? ProblemMatcher.swiftCompiler() {
            var found: [HostProblem] = []
            for line in outputLines {
                if let m = ProblemMatcherEngine.match(line: line.text, matcher: matcher, cwd: rootURL) {
                    found.append(HostProblem(
                        id: UUID(),
                        path: m.path,
                        message: m.diagnostic.message,
                        severity: m.diagnostic.severity.rawValue,
                        uri: m.uri,
                        line: 0
                    ))
                }
            }
            if !found.isEmpty {
                problems = found
            }
        }
    }

    func appendOutput(_ text: String, isError: Bool) {
        let line = OutputLine(text: text, isError: isError)
        outputLines.append(line)
        if outputLines.count > 500 {
            outputLines.removeFirst(outputLines.count - 500)
        }
        outputChannel.append(line)
    }

    private func pumpOutput() async {
        // Keep UI in sync if something else writes to the shared channel.
        for await line in outputChannel.lines {
            if !outputLines.contains(where: { $0.date == line.date && $0.text == line.text }) {
                outputLines.append(line)
            }
        }
    }

    // MARK: - Terminal

    func ensureTerminalSession() async {
        do {
            if terminalSessionID == nil {
                let config = TerminalConfiguration(
                    shell: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-i"],
                    cwd: rootURL
                )
                let session = try await terminal.create(title: "Shell", configuration: config)
                terminalSessionID = session.id
                terminalStatus = "Running"
                startTerminalListen()
                appendOutput("[terminal] session started in \(rootURL.path)", isError: false)
            }
        } catch {
            terminalStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func startTerminalListen() {
        terminalListenTask?.cancel()
        terminalListenTask = Task {
            for await event in await terminalBackend.output {
                if Task.isCancelled { break }
                switch event {
                case .data(_, let bytes):
                    if let text = String(data: bytes, encoding: .utf8) {
                        terminalOutput += text
                        if terminalOutput.count > 20_000 {
                            terminalOutput = String(terminalOutput.suffix(15_000))
                        }
                    }
                case .exited(_, let code):
                    terminalStatus = "Exited (\(code))"
                    terminalOutput += "\n[process exited \(code)]\n"
                }
            }
        }
    }

    func sendTerminalInput() {
        guard let id = terminalSessionID else { return }
        let line = terminalInput.hasSuffix("\n") ? terminalInput : terminalInput + "\n"
        terminalInput = ""
        terminalOutput += line
        Task {
            try? await terminal.write(line, to: id)
        }
    }

    func publishProblem(_ problem: HostProblem) {
        if let idx = problems.firstIndex(where: { $0.path == problem.path && $0.message == problem.message }) {
            problems[idx] = problem
        } else {
            problems.append(problem)
        }
    }
}

struct HostProblem: Identifiable, Hashable {
    var id: UUID
    var path: String
    var message: String
    var severity: String
    var uri: DocumentURI?
    var line: Int
}

struct SearchFileGroup: Identifiable {
    var id: String
    var fileName: String
    var path: String
    var matches: [SearchMatch]
}

extension SearchMatch {
    /// Stable group key for outline UI (canonical path when available).
    var fileGroupKey: String {
        uri.fileURL?.standardizedFileURL.path ?? uri.rawValue
    }
}

/// Bridges task diagnostics onto MainActor host state.
final class HostDiagnosticsSink: TaskDiagnosticsSink, @unchecked Sendable {
    weak var host: HostServices?

    func publish(uri: DocumentURI, diagnostics: [LanguageDiagnostic], owner: String) async {
        let items = diagnostics.map { d in
            HostProblem(
                id: UUID(),
                path: uri.fileURL?.path ?? uri.rawValue,
                message: d.message,
                severity: d.severity.rawValue,
                uri: uri,
                line: 0
            )
        }
        await MainActor.run {
            guard let host else { return }
            // Merge by path+message
            for item in items {
                host.publishProblem(item)
            }
            if !items.isEmpty {
                host.workbench?.selectUtility(id: "workbench.utility.problems")
                host.workbench?.isUtilityVisible = true
            }
        }
    }
}
