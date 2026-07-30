import SwiftUI
import CodeEditorWorkbench
import CodeEditorWorkspace
import CodeEditorDocuments
import CodeEditorLanguageSwift
import CodeEditorSearch
import CodeEditorTasks
import CodeEditorSourceControl
import CodeEditorTerminal
import CodeEditorLanguageServices

/// Full composition sketch: workbench + workspace + tooling product types linked.
/// UI for search/tasks/SCM/terminal is host-owned; this sample proves linkage and a minimal shell.
@main
struct FullWorkbenchApp: App {
    init() {
        CodeEditorLanguageSwift.register()
    }

    var body: some Scene {
        WindowGroup {
            FullWorkbenchRoot()
        }
    }
}

@MainActor
struct FullWorkbenchRoot: View {
    @State private var model: WorkbenchModel?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let model {
                WorkbenchView(model: model)
                    .frame(minWidth: 900, minHeight: 600)
            } else if let errorText {
                Text(errorText).padding()
            } else {
                ProgressView("Opening workspace…")
                    .task { await open() }
            }
        }
    }

    private func open() async {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FullWorkbench-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "// full workbench sample\n".data(using: .utf8)?
                .write(to: root.appendingPathComponent("Main.swift"))

            let workspace = try await Workspace.local(rootDirectories: [root])
            // Touch tooling types so the composition is real (hosts wire UI separately).
            _ = WorkspaceSearchContext(rootDirectories: [root])
            _ = TaskService()
            _ = SourceControlService()
            _ = TerminalSessionManager()
            _ = LanguageServiceRegistry()

            model = WorkbenchModel(workspace: workspace)
        } catch {
            errorText = String(describing: error)
        }
    }
}
