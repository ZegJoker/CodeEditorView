# Phase 11 notes — tooling products

## Search

```swift
import CodeEditorSearch

let context = WorkspaceSearchContext(
    rootDirectories: [projectRoot],
    openDocuments: [document.uri: document.text],
    openDocumentVersions: [document.uri: document.version]
)
let service = WorkspaceSearchService(context: context)
var matches: [SearchMatch] = []
for try await event in service.search(SearchQuery(pattern: "TODO", isRegex: false)) {
    if case .match(let m) = event { matches.append(m) }
}

let plan = SearchReplacePlan(query: SearchQuery(pattern: "TODO"), replacement: "DONE", matches: matches)
let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
    plan: plan,
    openDocumentVersions: context.openDocumentVersions
)
_ = try await WorkspaceEditService(workspace: workspace).apply(edit)
```

## Tasks

```swift
let tasks = TaskService()
await tasks.registerMatcher(try ProblemMatcher.swiftCompiler())
await tasks.setDiagnosticsSink(mySink)
await tasks.register(TaskDefinition(
    id: "build",
    label: "Build",
    executable: "/usr/bin/swift",
    arguments: ["build"],
    cwd: projectRoot,
    problemMatchers: ["swift"]
))
let run = try await tasks.run(id: "build")
```

## Terminal

```swift
let backend = MockTerminalBackend() // or ProcessTerminalBackend()
let manager = TerminalSessionManager()
await manager.attach(backend: backend)
let session = try await manager.create(title: "Shell")
// Host: show TerminalPanelDescriptor in workbench utility slot
try await manager.write("echo hi\n", to: session.id)
```

## Source control

```swift
let scm = SourceControlService()
await scm.setProvider(GitCLIProvider(repositoryRoot: projectRoot))
let status = try await scm.refresh()
```

## Isolation

```bash
scripts/check-product-isolation.sh
```
