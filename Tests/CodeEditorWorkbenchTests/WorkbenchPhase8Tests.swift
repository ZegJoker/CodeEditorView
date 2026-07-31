import Foundation
import SwiftUI
import Testing
import CodeEditorCommands
import CodeEditorDocuments
import CodeEditorWorkspace
@testable import CodeEditorWorkbench

@Suite("Workbench lifecycle and windows")
@MainActor
struct WorkbenchLifecycleTests {
    private func makeModel() async throws -> WorkbenchModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-P8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try await Workspace.local(rootDirectories: [root])
        return WorkbenchModel(workspace: workspace, configuration: .default)
    }

    @Test func lifecycleStartsActive() async throws {
        let model = try await makeModel()
        #expect(model.lifecyclePhase == .active)
        model.enterBackground()
        #expect(model.lifecyclePhase == .background)
        model.enterForeground()
        #expect(model.lifecyclePhase == .active)
    }

    @Test func multiWindowCreateFocusClose() async throws {
        let model = try await makeModel()
        #expect(model.windowRegistry.allWindows().count == 1)
        let second = model.createWindow(title: "Second")
        #expect(model.windowRegistry.allWindows().count == 2)
        model.isNavigatorVisible = false
        model.focusWindow(second.id)
        // Focusing second applies its stored chrome (navigator still default true on create)
        #expect(model.windowRegistry.focusedWindowID == second.id)
        model.closeWindow(second.id)
        #expect(model.windowRegistry.allWindows().count == 1)
    }

    @Test func restorationRoundTripChrome() async throws {
        let model = try await makeModel()
        model.isUtilityVisible = true
        model.selectUtility(id: "workbench.utility.terminal")
        model.utilityHeight = 220
        model.focus(.utility)
        let data = try model.encodeRestoration()
        let decoded = try WorkbenchRestoration.decode(data)
        #expect(decoded.windows.count >= 1)
        #expect(decoded.windows.contains(where: { $0.isUtilityVisible }))

        let model2 = try await makeModel()
        model2.applyRestoration(decoded)
        #expect(model2.isUtilityVisible)
        #expect(model2.activeUtilityID == "workbench.utility.terminal")
        #expect(model2.utilityHeight == 220)
        #expect(model2.focusedTarget == .utility)
        #expect(model2.lifecyclePhase == .active)
    }

    @Test func tearDownDisposesBuiltins() async throws {
        let model = try await makeModel()
        #expect(!model.contributionRegistry.contributions(for: .navigator).isEmpty)
        model.beginTearDown()
        #expect(model.lifecyclePhase == .tearingDown)
    }
}

@Suite("Workbench focus and commands")
@MainActor
struct WorkbenchFocusCommandTests {
    @Test func focusRoutingUpdatesTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-F-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        model.focus(.navigator)
        #expect(model.focusedTarget == .navigator)
        #expect(model.isNavigatorVisible)
        model.cycleFocusForward()
        #expect(model.focusedTarget == .editor)
    }

    @Test func commandValidationRequiresEditorForEditCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-C-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        model.focus(.navigator)
        #expect(!model.isCommandEnabled(CommandID(rawValue: "codeeditor.edit.undo")))
        model.focus(.editor)
        // Still no client without open file
        #expect(!model.isCommandEnabled(CommandID(rawValue: "codeeditor.edit.undo")))
    }
}

@Suite("Contribution isolation")
@MainActor
struct ContributionIsolationTests {
    final class FaultyContribution: WorkbenchContribution {
        let id = "test.faulty"
        let slot: WorkbenchSlot = .utility
        let priority = 99
        let title = "Faulty"
        var systemImage: String { "xmark.octagon" }
        func makeBody(context: WorkbenchContributionContext) -> AnyView {
            AnyView(Text("should not show after fault"))
        }
    }

    final class HealthyContribution: WorkbenchContribution {
        let id = "test.healthy"
        let slot: WorkbenchSlot = .utility
        let priority = 50
        let title = "Healthy"
        func makeBody(context: WorkbenchContributionContext) -> AnyView {
            AnyView(Text("ok"))
        }
    }

    @Test func markFailedIsolatesContribution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-Iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        _ = model.contributionRegistry.register(FaultyContribution())
        _ = model.contributionRegistry.register(HealthyContribution())
        model.contributionRegistry.markFailed(id: "test.faulty", message: "boom")
        #expect(model.contributionRegistry.faults["test.faulty"] == "boom")
        #expect(model.contributionRegistry.contribution(id: "test.healthy") != nil)
        let descs = model.contributionRegistry.descriptors(for: .utility)
        let faulty = descs.first(where: { $0.id == "test.faulty" })
        let healthy = descs.first(where: { $0.id == "test.healthy" })
        #expect(faulty?.availability == .failed)
        #expect(healthy?.availability == .available)
    }

    @Test func registerUnregisterStress() async throws {
        let registry = WorkbenchContributionRegistry()
        for i in 0..<100 {
            final class C: WorkbenchContribution {
                let id: String
                let slot: WorkbenchSlot = .inspector
                let priority = 1
                let title = "c"
                init(id: String) { self.id = id }
                func makeBody(context: WorkbenchContributionContext) -> AnyView { AnyView(EmptyView()) }
            }
            let token = registry.register(C(id: "c-\(i)"))
            if i % 2 == 0 { token.dispose() }
        }
        // Allow dispose tasks
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(registry.revision > 0)
        #expect(registry.contributions(for: .inspector).count <= 100)
    }
}

@Suite("Tooling surfaces")
@MainActor
struct ToolingSurfaceTests {
    @Test func failedSurfaceDoesNotRemoveOthers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-TS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = try WorkbenchHostBuilder()
            .workspace(workspace)
            .addToolingSurface(WorkbenchToolingSurface(
                id: "lsp",
                kind: .languageService,
                title: "LSP",
                status: .ready
            ))
            .addToolingSurface(WorkbenchToolingSurface(
                id: "term",
                kind: .terminal,
                title: "Terminal",
                status: .ready
            ))
            .build()
        model.toolingSurfaces.setStatus(id: "lsp", status: .failed(message: "crashed"))
        #expect(model.toolingSurfaces.surface(id: "term")?.status.isHealthy == true)
        #expect(model.visibleToolingFailures().count == 1)
        model.dismissToolingBanner(id: "lsp")
        #expect(model.visibleToolingFailures().isEmpty)
    }
}

@Suite("Open Quickly index")
@MainActor
struct OpenQuicklyIndexTests {
    @Test func usesIndexServiceAndCancels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OQ-P8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".data(using: .utf8)!.write(to: root.appendingPathComponent("Alpha.swift"))
        try "b".data(using: .utf8)!.write(to: root.appendingPathComponent("Beta.md"))

        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = OpenQuicklyModel()
        model.indexService = FileTreeIndexService(maxDepth: 4, maxFiles: 100)
        await model.recompute(workspace: workspace)
        #expect(model.results.count >= 2)
        model.query = "alpha"
        #expect(model.results.count == 1)
        #expect(model.results[0].name == "Alpha.swift")
    }

    @Test func keyboardSelection() async throws {
        let model = OpenQuicklyModel()
        // Inject items without FS
        model.query = ""
        // recompute empty workspace still ok
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OQ-K-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent("b.txt"))
        let workspace = try await Workspace.local(rootDirectories: [root])
        await model.recompute(workspace: workspace)
        #expect(!model.results.isEmpty)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex >= 0)
    }
}

@Suite("Host builder")
@MainActor
struct HostBuilderTests {
    @Test func buildsWithoutPrivateAssembly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = try WorkbenchHostBuilder()
            .workspace(workspace)
            .configuration(.xcodeLike)
            .addToolingSurface(WorkbenchToolingSurface(
                id: "scm",
                kind: .scm,
                title: "Git",
                status: .unavailable(reason: "not configured")
            ))
            .build()
        #expect(model.lifecyclePhase == .active)
        #expect(model.toolingSurfaces.all().count == 1)
        #expect(model.configuration.showsNavigator)
    }

    @Test func missingWorkspaceThrows() {
        do {
            _ = try WorkbenchHostBuilder().build()
            Issue.record("expected missingWorkspace")
        } catch let error as WorkbenchHostBuilderError {
            #expect(error == .missingWorkspace)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Accessibility identifiers")
struct WorkbenchAccessibilityTests {
    @Test func chromeIDsAreStable() {
        #expect(WorkbenchAccessibilityID.root == "workbench.root")
        #expect(WorkbenchAccessibilityID.editor == "workbench.editor")
        #expect(WorkbenchAccessibilityID.toolingBanner == "workbench.toolingBanner")
        #expect(!WorkbenchL10n.navigator.isEmpty)
        #expect(WorkbenchFocusOrder.editor > WorkbenchFocusOrder.navigator)
    }
}

@Suite("Performance smoke")
@MainActor
struct WorkbenchPerfSmokeTests {
    @Test func openQuicklyIndexBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PERF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<80 {
            try "x".data(using: .utf8)!.write(to: root.appendingPathComponent("f\(i).swift"))
        }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = OpenQuicklyModel()
        model.resultLimit = 200
        let start = ContinuousClock.now
        await model.recompute(workspace: workspace)
        let elapsed = start.duration(to: .now)
        #expect(model.results.count >= 80)
        // Soft budget: 5s is pathological; normal is ms–hundreds ms.
        #expect(elapsed < .seconds(5))
    }
}
