import SwiftUI
import CodeEditorWorkbench
import CodeEditorWorkspace
import CodeEditorDocuments
import CodeEditorLanguageSwift
import CodeEditorCommands

#if os(macOS)
import AppKit
#endif

#if os(macOS)
final class FullWorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct FullWorkbenchApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FullWorkbenchAppDelegate.self) private var appDelegate
    #endif

    init() {
        CodeEditorLanguageSwift.register()
    }

    var body: some Scene {
        WindowGroup {
            FullWorkbenchRoot()
                #if os(macOS)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                #endif
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .fullWorkbenchUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") {
                    NotificationCenter.default.post(name: .fullWorkbenchRedo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Open Quickly…") {
                    NotificationCenter.default.post(name: .fullWorkbenchOpenQuickly, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .fullWorkbenchCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Button("Toggle Navigator") {
                    NotificationCenter.default.post(name: .fullWorkbenchToggleNavigator, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .fullWorkbenchToggleInspector, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Toggle Utility Area") {
                    NotificationCenter.default.post(name: .fullWorkbenchToggleUtility, object: nil)
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                Divider()
                Button("Show Find Navigator") {
                    NotificationCenter.default.post(name: .fullWorkbenchShowFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Source Control") {
                    NotificationCenter.default.post(name: .fullWorkbenchShowSCM, object: nil)
                }
            }
            CommandMenu("Run") {
                Button("Run Sample Task") {
                    NotificationCenter.default.post(name: .fullWorkbenchRunTask, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let fullWorkbenchOpenQuickly = Notification.Name("fullWorkbench.openQuickly")
    static let fullWorkbenchCommandPalette = Notification.Name("fullWorkbench.commandPalette")
    static let fullWorkbenchToggleNavigator = Notification.Name("fullWorkbench.toggleNavigator")
    static let fullWorkbenchToggleInspector = Notification.Name("fullWorkbench.toggleInspector")
    static let fullWorkbenchToggleUtility = Notification.Name("fullWorkbench.toggleUtility")
    static let fullWorkbenchShowFind = Notification.Name("fullWorkbench.showFind")
    static let fullWorkbenchShowSCM = Notification.Name("fullWorkbench.showSCM")
    static let fullWorkbenchRunTask = Notification.Name("fullWorkbench.runTask")
    static let fullWorkbenchUndo = Notification.Name("fullWorkbench.undo")
    static let fullWorkbenchRedo = Notification.Name("fullWorkbench.redo")
}

@MainActor
struct FullWorkbenchRoot: View {
    @State private var phase: LaunchPhase = .loading
    @State private var host: HostServices?

    private enum LaunchPhase {
        case loading
        case ready(WorkbenchModel)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Opening workspace…")
            case .ready(let model):
                WorkbenchView(model: model)
                    .frame(minWidth: 900, minHeight: 600)
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchOpenQuickly)) { _ in
                        model.presentOpenQuickly()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchCommandPalette)) { _ in
                        model.presentCommandPalette()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchToggleNavigator)) { _ in
                        withAnimation(WorkbenchMotion.pane) { model.isNavigatorVisible.toggle() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchToggleInspector)) { _ in
                        withAnimation(WorkbenchMotion.pane) { model.isInspectorVisible.toggle() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchToggleUtility)) { _ in
                        withAnimation(WorkbenchMotion.pane) { model.isUtilityVisible.toggle() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchShowFind)) { _ in
                        model.selectNavigator(id: "fullworkbench.navigator.find")
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchShowSCM)) { _ in
                        model.selectNavigator(id: "fullworkbench.navigator.scm")
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchRunTask)) { _ in
                        Task { await host?.runDemoTask() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchUndo)) { _ in
                        host?.undo()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fullWorkbenchRedo)) { _ in
                        host?.redo()
                    }
            case .failed(let message):
                ContentUnavailableView(
                    "Could not open workspace",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard case .loading = phase else { return }
            await openWorkspace()
        }
    }

    private func openWorkspace() async {
        do {
            let root = try SampleProjectFactory.create()
            let workspace = try await Workspace.local(rootDirectories: [root])
            let workbench = WorkbenchModel(
                workspace: workspace,
                configuration: .xcodeLike
            )

            let services = HostServices(rootURL: root)
            await services.attach(to: workbench)
            host = services

            let mainURL = root.appendingPathComponent("Main.swift")
            _ = try await workspace.openInActivePane(
                uri: DocumentURI(fileURL: mainURL),
                preview: false
            )
            workbench.statusMessage = "Main.swift"
            workbench.isUtilityVisible = false
            phase = .ready(workbench)
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

/// Creates a small multi-file sample project with optional git repo for SCM demo.
enum SampleProjectFactory {
    static func create() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullWorkbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let main = """
        // Full workbench sample
        import Foundation

        @main
        struct Sample {
            static func main() {
                print("Hello from FullWorkbench")
                Helper.greet()
            }
        }

        """
        try Data(main.utf8).write(to: root.appendingPathComponent("Main.swift"))

        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("""
        // helper
        enum Helper {
            static func greet() {
                print("hi")
            }
        }

        """.utf8).write(to: sources.appendingPathComponent("Helper.swift"))

        try Data("""
        # Sample Project

        Open **Find** (⇧⌘F), **Source Control**, **Terminal**, and **Output** panels.

        """.utf8).write(to: root.appendingPathComponent("README.md"))

        // git init so SCM navigator has a real provider surface.
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init"]
        git.currentDirectoryURL = root
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try? git.run()
        git.waitUntilExit()

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["add", "."]
        add.currentDirectoryURL = root
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try? add.run()
        add.waitUntilExit()

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["-c", "user.email=dev@example.com", "-c", "user.name=FullWorkbench", "commit", "-m", "Initial sample"]
        commit.currentDirectoryURL = root
        commit.standardOutput = FileHandle.nullDevice
        commit.standardError = FileHandle.nullDevice
        try? commit.run()
        commit.waitUntilExit()

        // Leave a dirty file for SCM to show changes.
        try Data("// helper (edited)\n".utf8).write(to: sources.appendingPathComponent("Helper.swift"))

        return root
    }
}
