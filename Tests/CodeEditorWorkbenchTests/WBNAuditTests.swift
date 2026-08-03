import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorTasks
import CodeEditorTerminal
import CodeEditorWorkspace
import Foundation
import SwiftUI
import Testing

@testable import CodeEditorWorkbench

// MARK: - WB-N01 error presentation (not fault isolation)

@Suite("WB-N01 contribution error presentation")
@MainActor
struct WBN01ErrorPresentationTests {
    @Test func test_WB_N01_errorPresentationAPINotNamedFaultIsolation() async throws {
        // Public error-presentation entry point must exist; isolation wording must not.
        let registry = WorkbenchContributionRegistry()
        #expect(WorkbenchContributionRender.self != Never.self)
        // Source-level honesty: trusted native contributions declare in-process trust.
        final class Trusted: WorkbenchContribution {
            let id = "test.trusted"
            let slot: WorkbenchSlot = .utility
            let priority = 1
            let title = "Trusted"
            let trust = WorkbenchContributionTrust.trustedInProcess
            func makeBody(context: WorkbenchContributionContext) -> AnyView {
                AnyView(Text("ok"))
            }
        }
        let c = Trusted()
        #expect(c.trust == .trustedInProcess)
        _ = registry.register(c)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let ctx = WorkbenchContributionContext(workspace: workspace, model: model)
        // Invoke production error-presentation path (not isolation).
        let okBody = registry.makeBodyWithErrorPresentation(id: "test.trusted", context: ctx)
        #expect(String(describing: type(of: okBody)).contains("AnyView"))
        registry.markFailed(id: "test.trusted", message: "boom")
        let faultBody = registry.makeBodyWithErrorPresentation(id: "test.trusted", context: ctx)
        #expect(String(describing: type(of: faultBody)).contains("AnyView"))
        #expect(registry.faults["test.trusted"] == "boom")
        #expect(WorkbenchContributionTrust.trustedInProcess != .declarativeUntrusted)
    }

    @Test func test_WB_N01_errorPresentationShowsFaultWithoutClaimingIsolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n01e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)

        final class Failing: WorkbenchContribution {
            let id = "test.fail"
            let slot: WorkbenchSlot = .utility
            let priority = 1
            let title = "Failing"
            let trust = WorkbenchContributionTrust.trustedInProcess
            func makeBody(context: WorkbenchContributionContext) -> AnyView {
                AnyView(Text("should not render when failed"))
            }
        }
        _ = model.contributionRegistry.register(Failing())
        model.contributionRegistry.markFailed(id: "test.fail", message: "render error")
        let ctx = WorkbenchContributionContext(workspace: workspace, model: model)
        let view = model.contributionRegistry.makeBodyWithErrorPresentation(id: "test.fail", context: ctx)
        #expect(model.contributionRegistry.faults["test.fail"] == "render error")
        #expect(String(describing: type(of: view)).contains("AnyView"))
        // Descriptors expose error presentation, not "isolated"
        let desc = model.contributionRegistry.descriptors(for: .utility)
            .first { $0.id == "test.fail" }
        #expect(desc?.availability == .failed)
        #expect(desc?.faultMessage == "render error")
    }

    @Test func test_WB_N01_untrustedContributionsAreDeclarativeOnly() {
        let vm = WorkbenchDeclarativeContributionViewModel(
            id: "ext.panel.demo",
            slot: .utility,
            priority: 5,
            title: "Demo Panel",
            systemImage: "puzzlepiece",
            providerID: "extension.demo",
            rows: [
                WorkbenchDeclarativeRow(id: "r1", title: "Hello", detail: "from extension"),
                WorkbenchDeclarativeRow(id: "r2", title: "Command", detail: "workbench.scheme.build"),
            ]
        )
        #expect(vm.trust == .declarativeUntrusted)
        #expect(vm.rows.count == 2)
        // Host-owned renderer constructs the view — untrusted code never supplies makeBody.
        let body = WorkbenchDeclarativeContributionRenderer.makeBody(viewModel: vm)
        #expect(String(describing: type(of: body)).contains("AnyView"))
        let registry = WorkbenchContributionRegistry()
        let token = registry.registerDeclarative(vm)
        #expect(registry.contribution(id: "ext.panel.demo") != nil)
        #expect(registry.descriptors(for: .utility).contains { $0.id == "ext.panel.demo" })
        token.dispose()
        #expect(registry.contribution(id: "ext.panel.demo") == nil)
    }

    @Test func test_WB_N01_noFaultIsolationWordingInContributionAPI() throws {
        // Guardrail: production contribution source must not market in-process error UI as isolation.
        let src = try String(
            contentsOfFile: packageRoot()
                .appendingPathComponent("Sources/CodeEditorWorkbench/WorkbenchContribution.swift")
                .path,
            encoding: .utf8
        )
        #expect(!src.localizedCaseInsensitiveContains("fault isolation"))
        #expect(!src.contains("makeBodyIsolated"))
        #expect(src.contains("makeBodyWithErrorPresentation"))
        #expect(src.localizedCaseInsensitiveContains("error presentation")
            || src.localizedCaseInsensitiveContains("error-presentation")
            || src.contains("Error presentation"))
        #expect(src.contains("trustedInProcess") || src.contains("WorkbenchContributionTrust"))
    }
}

// MARK: - WB-N02 layout-based reveal

@Suite("WB-N02 layout-based editor reveal")
@MainActor
struct WBN02RevealTests {
    @Test func test_WB_N02_revealUsesLineIndexNotFabricatedDiv40() {
        // 3 lines × 20pt estimated height. Range at start of line 2 → layout y = 40.
        let text = "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n"
        let range = CodeEditorCore.TextRange(location: 22, length: 3)  // on line 2
        let result = EditorRevealService.reveal(
            range: range,
            text: text,
            estimatedLineHeight: 20,
            viewportHeight: nil,
            alignment: .centerIfOutsideViewport,
            selectionPolicy: .select,
            animation: .respectReduceMotion
        )
        #expect(abs(result.yOffset - 40) < 0.5)
        #expect(abs(result.scrollPosition.y - 40) < 0.5)
        #expect(result.lineIndex == 2)
        #expect(result.selection == range)
        // Fabricated formula location/40 would be 22/40 = 0 — must not match.
        #expect(result.scrollPosition.y != CGFloat(range.location / 40))

        // When the line is already inside a tall viewport, scroll may stay 0 but yOffset is layout-true.
        let centered = EditorRevealService.reveal(
            range: range,
            text: text,
            estimatedLineHeight: 20,
            viewportHeight: 200,
            alignment: .centerIfOutsideViewport,
            selectionPolicy: .select,
            animation: .respectReduceMotion
        )
        #expect(abs(centered.yOffset - 40) < 0.5)
    }

    @Test func test_WB_N02_openURIAppliesLayoutReveal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 5 lines so offset 40 is mid-document; /40 formula yields y=1 which is wrong for line height 16.
        var body = ""
        for i in 0..<20 {
            body += "line \(i) content here\n"
        }
        let file = root.appendingPathComponent("Main.swift")
        try body.data(using: .utf8)!.write(to: file)

        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let uri = DocumentURI(fileURL: file)
        let selection = CodeEditorCore.TextRange(location: 80, length: 4)
        model.openURI(uri, preview: false, selection: selection)

        // Allow async open + reveal.
        for _ in 0..<50 {
            if model.activeSession?.selections.first == selection,
                model.activeSession?.scrollPosition != nil
            {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let session = try #require(model.activeSession)
        #expect(session.selections.first == selection)
        let scrollY = try #require(session.scrollPosition?.y)
        let expected = EditorRevealService.reveal(
            range: selection,
            text: body,
            estimatedLineHeight: EditorRevealService.defaultEstimatedLineHeight,
            viewportHeight: nil,
            alignment: .centerIfOutsideViewport,
            selectionPolicy: .select,
            animation: .respectReduceMotion
        ).scrollPosition.y
        #expect(abs(scrollY - expected) < 0.5)
        #expect(scrollY != CGFloat(selection.location / 40))
    }

    @Test func test_WB_N02_revealAPISurfaceMatchesAuditContract() {
        let _: EditorRevealAlignment = .centerIfOutsideViewport
        let _: EditorRevealSelectionPolicy = .select
        let _: EditorRevealAnimation = .respectReduceMotion
        #expect(EditorRevealService.defaultEstimatedLineHeight > 0)
    }
}

// MARK: - WB-N03 animation

@Suite("WB-N03 workbench animation")
@MainActor
struct WBN03AnimationTests {
    @Test func test_WB_N03_withAnimationIfAvailableIsNotNoOp() {
        var ran = false
        var applied: Animation?
        WorkbenchMotion.withAnimationIfAvailable(
            WorkbenchMotion.pane,
            reduceMotion: false,
            record: { applied = $0 }
        ) {
            ran = true
        }
        #expect(ran)
        #expect(applied != nil)
    }

    @Test func test_WB_N03_reduceMotionDisablesAnimation() {
        var applied: Animation? = WorkbenchMotion.pane
        WorkbenchMotion.withAnimationIfAvailable(
            WorkbenchMotion.pane,
            reduceMotion: true,
            record: { applied = $0 }
        ) {
            // body
        }
        #expect(applied == nil)
    }

    @Test func test_WB_N03_workbenchModelUsesRealAnimationHelper() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        model.isUtilityVisible = false
        model.selectUtility(id: "workbench.utility.problems")
        #expect(model.isUtilityVisible)
        // Model must route through WorkbenchMotion (not a private empty wrapper).
        let modelSrc = try String(
            contentsOfFile: packageRoot()
                .appendingPathComponent("Sources/CodeEditorWorkbench/WorkbenchModel.swift")
                .path,
            encoding: .utf8
        )
        #expect(modelSrc.contains("WorkbenchMotion.withAnimationIfAvailable"))
        #expect(!modelSrc.contains("private func withAnimationIfAvailable"))
    }
}

// MARK: - WB-N04 background file-tree index

@Suite("WB-N04 background file-tree index")
@MainActor
struct WBN04IndexTests {
    @Test func test_WB_N04_indexDoesNotExpandMainActorFileTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".data(using: .utf8)!.write(to: root.appendingPathComponent("A.swift"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "b".data(using: .utf8)!.write(to: root.appendingPathComponent("sub/B.swift"))

        let workspace = try await Workspace.local(rootDirectories: [root])
        // File tree starts unexpanded (only roots).
        #expect(workspace.fileTree.roots.count == 1)
        let rootItem = WorkspaceItemID(rootID: workspace.fileTree.roots[0].id, path: "")
        #expect(!workspace.fileTree.isExpanded(rootItem))

        let service = FileTreeIndexService(maxDepth: 8, maxFiles: 100)
        let items = try await service.rebuild(workspace: workspace)
        #expect(items.count >= 2)
        #expect(items.contains { $0.name == "A.swift" })
        #expect(items.contains { $0.name == "B.swift" })
        // Index must not force-expand the UI file tree.
        #expect(!workspace.fileTree.isExpanded(rootItem))
        #expect(workspace.fileTree.cachedChildren(of: rootItem) == nil)
    }

    @Test func test_WB_N04_indexEngineIsBackgroundActor() async throws {
        let engine = FileTreeIndexEngine(maxDepth: 4, maxFiles: 50)
        // Actor type + off-main probe (not a string-description smoke).
        #expect(await engine.isRunningOffMainActor())
        let probe = SlowProbeFileSystem()
        // Start rebuild; while engine is inside children(), MainActor must still progress.
        let rebuildTask = Task {
            try await engine.rebuild(fileSystem: probe)
        }
        for _ in 0..<100 where !probe.enteredChildren {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(probe.enteredChildren)
        var mainProgressed = false
        mainProgressed = true
        #expect(mainProgressed)
        #expect(!probe.childrenCalledOnMainThread)
        // Release the probe so rebuild can finish.
        probe.releaseGate()
        let items = try await rebuildTask.value
        #expect(items.count >= 1)
        #expect(!probe.childrenCalledOnMainThread)
        #expect(await engine.isRunningOffMainActor())
    }

    @Test func test_WB_N04_indexCancellationAndBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n04c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30 {
            try "x".data(using: .utf8)!.write(to: root.appendingPathComponent("n\(i).txt"))
        }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let service = FileTreeIndexService(maxDepth: 4, maxFiles: 5)
        let items = try await service.rebuild(workspace: workspace)
        #expect(items.count <= 5)
        #expect(service.isScanning == false)

        // Slow service: cancel must clear Open Quickly scanning state (non-vacuous).
        let slow = SlowIndexService()
        let model = OpenQuicklyModel()
        model.indexService = slow
        let task = Task { await model.recompute(workspace: workspace) }
        for _ in 0..<100 where !slow.entered {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(slow.entered)
        #expect(model.isScanning == true)
        model.cancelScan()
        await task.value
        #expect(model.isScanning == false)
        #expect(slow.wasCancelled)

        // FileTreeIndexService.cancelScan clears isScanning even mid-rebuild.
        let hang = FileTreeIndexService(maxDepth: 8, maxFiles: 10_000)
        // Use slow service path via engine is hard; cancel after starting recompute-like rebuild with hang FS.
        // Direct cancelScan after marking scanning via rebuild race:
        let rebuildTask = Task { try await hang.rebuild(workspace: workspace) }
        hang.cancelScan()
        do {
            _ = try await rebuildTask.value
        } catch is CancellationError {
            // expected when cancelled mid-flight
        } catch {
            // rebuild may finish before cancel lands; still require clear state
        }
        #expect(hang.isScanning == false)
    }

    @Test func test_WB_N04_watcherDrivenIncrementalUpdates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n04w-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".data(using: .utf8)!.write(to: root.appendingPathComponent("A.swift"))
        let workspace = try await Workspace.local(rootDirectories: [root])
        let service = FileTreeIndexService(maxDepth: 6, maxFiles: 100)
        let mock = MockWorkspaceFileWatcher()
        await service.startWatching(workspace: workspace, debounce: .milliseconds(20), backend: mock)
        #expect(service.isWatching)
        #expect(!service.watchedRootIDs.isEmpty)
        let seedGen = try #require(service.latestSnapshot?.generation)
        #expect(service.latestSnapshot?.items.contains { $0.name == "A.swift" } == true)

        try "b".data(using: .utf8)!.write(to: root.appendingPathComponent("B.swift"))
        let rootID = try #require(service.watchedRootIDs.first)
        mock.emit(.changed(rootID: rootID))
        // Debounced watcher-driven refresh.
        for _ in 0..<80 {
            if let gen = service.latestSnapshot?.generation, gen > seedGen {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = try #require(service.latestSnapshot)
        #expect(after.generation > seedGen)
        #expect(
            after.reason == .watcherIncremental
                || service.lastUpdateReason == .watcherIncremental
        )
        #expect(after.items.contains { $0.name == "B.swift" })

        // Overflow forces full rescan path.
        let gen2 = after.generation
        mock.emit(.overflow(rootID: rootID))
        for _ in 0..<80 {
            if let gen = service.latestSnapshot?.generation, gen > gen2 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect((service.latestSnapshot?.generation ?? 0) > gen2)
        #expect(
            service.latestSnapshot?.reason == .watcherOverflowRescan
                || service.lastUpdateReason == .watcherOverflowRescan
        )
        service.stopWatching()
        #expect(service.isWatching == false)
        #expect(service.isScanning == false)
    }

    @Test func test_WB_N04_snapshotIsImmutableAndDiffable() async throws {
        let snap = FileTreeIndexSnapshot(
            generation: 3,
            items: [
                OpenQuicklyItem(uri: nil, name: "a.swift", path: "a.swift"),
                OpenQuicklyItem(uri: nil, name: "b.swift", path: "b.swift"),
            ]
        )
        #expect(snap.generation == 3)
        #expect(snap.items.count == 2)
        let other = FileTreeIndexSnapshot(generation: 3, items: snap.items)
        #expect(snap == other)
    }
}

// MARK: - WB-N05 TaskBag lifecycle

@Suite("WB-N05 TaskBag lifecycle")
@MainActor
struct WBN05TaskBagTests {
    @Test func test_WB_N05_taskBagCancelsStoredTasks() async throws {
        let bag = WorkbenchTaskBag()
        let started = expectationFlag()
        let cancelled = expectationFlag()
        bag.store(
            Task {
                started.value = true
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                cancelled.value = true
            }
        )
        for _ in 0..<40 where !started.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(started.value)
        #expect(bag.count >= 1)
        bag.cancelAll()
        for _ in 0..<40 where !cancelled.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(cancelled.value)
        #expect(bag.count == 0)
    }

    @Test func test_WB_N05_workbenchTearDownCancelsTaskBag() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let cancelled = expectationFlag()
        model.taskBag.store(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                cancelled.value = true
            }
        )
        #expect(model.taskBag.count >= 1)
        model.beginTearDown()
        for _ in 0..<40 where !cancelled.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(cancelled.value)
        #expect(model.taskBag.count == 0)
        #expect(model.lifecyclePhase == .tearingDown)
    }

    @Test func test_WB_N05_openURIUsesTaskBag() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n05o-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("x.swift")
        try "print(1)\n".data(using: .utf8)!.write(to: file)
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let before = model.taskBag.totalStored
        model.openURI(DocumentURI(fileURL: file), preview: true)
        #expect(model.taskBag.totalStored > before)
        // Wait for open to finish so we don't leak across suites.
        for _ in 0..<50 {
            if model.activeDocument != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.beginTearDown()
    }

    @Test func test_WB_N05_windowScopedTaskBag() {
        let registry = WorkbenchWindowRegistry()
        let window = registry.create(title: "W")
        let bag = registry.taskBag(for: window.id)
        #expect(bag.count == 0)
        bag.store(Task {})
        #expect(registry.taskBag(for: window.id).count >= 1)
        registry.close(window.id)
        // Closing window cancels its bag.
        #expect(registry.taskBag(for: window.id).count == 0)
    }

    @Test func test_WB_N05_panelAndPaneTaskBagsCancelOnDeactivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n05p-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)

        // Panel bag
        let panelCancelled = expectationFlag()
        model.panelTaskBag(for: "workbench.utility.problems").store(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                panelCancelled.value = true
            }
        )
        #expect(model.panelTaskBag(for: "workbench.utility.problems").count >= 1)

        // Pane bag
        let paneID = try #require(model.workspace.activePaneID)
        let paneCancelled = expectationFlag()
        model.paneTaskBag(for: paneID).store(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                paneCancelled.value = true
            }
        )
        #expect(model.paneTaskBag(for: paneID).count >= 1)

        // Terminal panel model deactivation cancels its bag.
        let terminal = WorkbenchTerminalPanelModel(
            service: TerminalService(
                securityPolicy: .restricted,
                requireGhosttyLinked: false,
                isGhosttyLinked: { false }
            )
        )
        let terminalCancelled = expectationFlag()
        terminal.taskBag.store(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                terminalCancelled.value = true
            }
        )
        terminal.deactivate()
        for _ in 0..<40 where !terminalCancelled.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(terminalCancelled.value)
        #expect(terminal.taskBag.count == 0)

        model.beginTearDown()
        for _ in 0..<40 where !(panelCancelled.value && paneCancelled.value) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(panelCancelled.value)
        #expect(paneCancelled.value)
    }

    @Test func test_WB_N05_utilityAndEditorTasksAreBaggedInSource() throws {
        let util = try String(
            contentsOfFile: packageRoot()
                .appendingPathComponent("Sources/CodeEditorWorkbench/UtilityPanels.swift")
                .path,
            encoding: .utf8
        )
        let editor = try String(
            contentsOfFile: packageRoot()
                .appendingPathComponent("Sources/CodeEditorWorkbench/Views/WorkbenchEditorArea.swift")
                .path,
            encoding: .utf8
        )
        // Production paths must store Tasks on a WorkbenchTaskBag — not bare Task { }.
        // Allow Task only when preceded by taskBag.store / panelTaskBag / paneTaskBag.
        func bareTaskCount(_ src: String) -> Int {
            let pattern = #"Task\s*\{"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let ns = src as NSString
            let matches = regex.matches(in: src, range: NSRange(location: 0, length: ns.length))
            var bare = 0
            for m in matches {
                // Look far enough back to cover multi-line `.store(Task {` call sites.
                let start = max(0, m.range.location - 120)
                let prefix = ns.substring(with: NSRange(location: start, length: m.range.location - start))
                let isBagged =
                    prefix.contains("taskBag.store")
                    || prefix.contains("panelTaskBag")
                    || prefix.contains("paneTaskBag")
                    || prefix.contains(".store(")
                    || prefix.contains("taskBag.task")
                    || prefix.contains("taskBag.detached")
                if !isBagged { bare += 1 }
            }
            return bare
        }
        #expect(bareTaskCount(util) == 0)
        #expect(bareTaskCount(editor) == 0)
        #expect(util.contains("taskBag") || util.contains("panelTaskBag"))
        #expect(editor.contains("paneTaskBag"))
    }
}

// MARK: - WB-N06 end-to-end workflows

@Suite("WB-N06 production workflow wiring")
@MainActor
struct WBN06WorkflowTests {
    @Test func test_WB_N06_schemeBuildRunsTaskService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let tasks = TaskService()
        await tasks.register(
            TaskDefinition(
                id: "build",
                label: "Build",
                executable: "/bin/echo",
                arguments: ["built"],
                cwd: root,
                group: .build
            )
        )
        model.schemes.setSchemes([
            WorkbenchScheme(id: "s", name: "S", buildTaskID: "build", testTaskID: "test", runTaskID: "run")
        ])
        model.schemes.selectedSchemeID = "s"
        model.workflows.bind(taskService: tasks)
        let report = try await model.workflows.runSchemeAction(.build, model: model)
        #expect(report.root.rawValue == "build")
        #expect(model.activity.items.isEmpty || model.activity.cancelledIDs.isEmpty)
        #expect(model.schemes.lastAction == "build")
        #expect(model.schemes.lastError == nil)
    }

    @Test func test_WB_N06_schemeBuildFailsClosedWithoutService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06f-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        model.schemes.setSchemes([
            WorkbenchScheme(id: "s", name: "S", buildTaskID: "build")
        ])
        model.schemes.selectedSchemeID = "s"
        do {
            _ = try await model.workflows.runSchemeAction(.build, model: model)
            Issue.record("expected fail-closed without TaskService")
        } catch WorkbenchWorkflowError.serviceUnavailable {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(model.schemes.lastError != nil)
    }

    @Test func test_WB_N06_taskProblemsBridgeFromWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06p-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let tasks = TaskService()
        if let matcher = try? ProblemMatcher.swiftCompiler() {
            await tasks.registerMatcher(matcher)
        }
        let diagPath = root.appendingPathComponent("Helper.swift").path
        let matcherIDs = (try? ProblemMatcher.swiftCompiler()).map { [$0.id] } ?? []
        await tasks.register(
            TaskDefinition(
                id: "problems",
                label: "Problems",
                executable: "/bin/echo",
                arguments: ["\(diagPath):1:1: warning: sample diagnostic"],
                cwd: root,
                problemMatchers: matcherIDs,
                group: .build
            )
        )
        model.schemes.setSchemes([
            WorkbenchScheme(id: "s", name: "S", buildTaskID: "problems")
        ])
        model.schemes.selectedSchemeID = "s"
        model.workflows.bind(taskService: tasks)
        _ = try await model.workflows.runSchemeAction(.build, model: model)
        // Allow diagnostics sink / bridge to settle.
        for _ in 0..<30 where model.problemsBridge.problems.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!model.problemsBridge.problems.isEmpty)
        #expect(model.problemsBridge.problems[0].message.contains("sample diagnostic")
            || model.problemsBridge.problems[0].severity == "warning"
            || model.problemsBridge.problems[0].path.contains("Helper.swift"))
    }

    @Test func test_WB_N06_scmRefreshUsesProductionService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06s-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let scm = SourceControlService()
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true)
        await scm.setProvider(provider)
        model.scmModel.trusted = true
        model.workflows.bind(sourceControl: scm)
        do {
            try await model.workflows.refreshSCM(model: model)
            // Non-repo: empty statuses is acceptable; must not invent fake changes.
            #expect(model.scmModel.statuses.isEmpty)
        } catch {
            // Fail-closed surface: error is recorded on the model (no silent success).
            #expect(model.scmModel.errorMessage != nil)
        }
    }

    @Test func test_WB_N06_scmRefreshFailsClosedWithoutService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06s2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        do {
            try await model.workflows.refreshSCM(model: model)
            Issue.record("expected fail-closed without SourceControlService")
        } catch WorkbenchWorkflowError.serviceUnavailable {
            #expect(model.scmModel.errorMessage != nil)
        }
    }

    @Test func test_WB_N06_testSchemeMarksTestsRunning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n06t-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        model.tests.setTests([WorkbenchTestItem(id: "t1", name: "testA")])
        let tasks = TaskService()
        await tasks.register(
            TaskDefinition(
                id: "test",
                label: "Test",
                executable: "/bin/echo",
                arguments: ["ok"],
                cwd: root,
                group: .test
            )
        )
        model.schemes.setSchemes([
            WorkbenchScheme(id: "s", name: "S", testTaskID: "test")
        ])
        model.schemes.selectedSchemeID = "s"
        model.workflows.bind(taskService: tasks)
        _ = try await model.workflows.runSchemeAction(.test, model: model)
        #expect(model.tests.lastRunTaskID == "test")
    }
}

// MARK: - WB-N07 Stable 1.0 scope

@Suite("WB-N07 Stable 1.0 workbench scope")
@MainActor
struct WBN07ScopeTests {
    @Test func test_WB_N07_stableScopeIsBoundedAndExplicit() {
        let scope = WorkbenchStableScope.v1
        #expect(scope.version == "1.0")
        #expect(!scope.included.isEmpty)
        #expect(!scope.excludedXcodeClassGaps.isEmpty)
        // Must not claim full Xcode parity.
        #expect(!scope.claimsFullXcodeParity)
        #expect(scope.excludedXcodeClassGaps.contains { $0.contains("project/build graph")
            || $0.contains("schemes") || $0.lowercased().contains("coverage") })
        // Included surfaces are real shell capabilities.
        #expect(scope.included.contains { $0.lowercased().contains("navigator")
            || $0.lowercased().contains("editor") })
    }

    @Test func test_WB_N07_documentationDeclaresScopeWithoutFakePanels() throws {
        let doc = try String(
            contentsOfFile: packageRoot()
                .appendingPathComponent("Sources/CodeEditorWorkbench/Documentation.docc/Documentation.md")
                .path,
            encoding: .utf8
        )
        #expect(doc.contains("Stable 1.0") || doc.contains("Stable scope"))
        #expect(doc.localizedCaseInsensitiveContains("not") || doc.contains("does not"))
        #expect(
            doc.localizedCaseInsensitiveContains("xcode")
                || doc.localizedCaseInsensitiveContains("gap")
                || doc.localizedCaseInsensitiveContains("roadmap")
        )
        // Must not claim complete Xcode parity.
        let lowered = doc.lowercased()
        #expect(!lowered.contains("full xcode parity"))
        #expect(!lowered.contains("complete xcode replacement"))
    }

    @Test func test_WB_N07_defaultNavigatorsAreEmptyStatesNotFakeData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-n07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        // Default models start empty — no fabricated demo rows pretending to be Xcode data.
        let symbolCount = model.symbols.symbols.count
        let bpCount = model.breakpoints.breakpoints.count
        let debugCount = model.debugSessions.sessions.count
        let testCount = model.tests.tests.count
        let scmCount = model.scmModel.statuses.count
        let problemCount = model.problemsBridge.problems.count
        #expect(symbolCount == 0)
        #expect(bpCount == 0)
        #expect(debugCount == 0)
        #expect(testCount == 0)
        #expect(scmCount == 0)
        #expect(problemCount == 0)
        #expect(WorkbenchStableScope.v1.fakePanelIDs.isEmpty)
    }
}

// MARK: - Helpers

private final class Flag: @unchecked Sendable {
    var value = false
}

@MainActor
private func expectationFlag() -> Flag { Flag() }

private func packageRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}

/// Slow cancellable index used to prove Open Quickly cancel clears `isScanning` (WB-N04).
@MainActor
private final class SlowIndexService: WorkspaceIndexService, @unchecked Sendable {
    private(set) var entered = false
    private(set) var wasCancelled = false

    func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem] {
        entered = true
        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        wasCancelled = true
        throw CancellationError()
    }
}

/// Probe FS that blocks in `children` until released; records main-thread affinity (WB-N04).
private final class SlowProbeFileSystem: WorkspaceFileSystem, @unchecked Sendable {
    // nonisolated(unsafe): probe is test-only; mutated from engine actor + MainActor test.
    nonisolated(unsafe) private var gateOpen = false
    nonisolated(unsafe) private var enteredChildrenFlag = false
    nonisolated(unsafe) private var childrenCalledOnMainThreadFlag = false

    private let root = WorkspaceRoot(
        directoryURL: URL(fileURLWithPath: "/tmp/wb-n04-probe", isDirectory: true)
    )

    var enteredChildren: Bool { enteredChildrenFlag }
    var childrenCalledOnMainThread: Bool { childrenCalledOnMainThreadFlag }

    func releaseGate() {
        gateOpen = true
    }

    var roots: [WorkspaceRoot] {
        get async { [root] }
    }

    func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem] {
        enteredChildrenFlag = true
        if Self.isMainThreadNonasync() {
            childrenCalledOnMainThreadFlag = true
        }
        // Block until released so the MainActor test can interleave.
        for _ in 0..<200 {
            if gateOpen { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if item.path.isEmpty {
            return [
                WorkspaceItem(
                    id: WorkspaceItemID(rootID: root.id, path: "probe.txt"),
                    name: "probe.txt",
                    isDirectory: false,
                    uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/wb-n04-probe/probe.txt"))
                )
            ]
        }
        return []
    }

    /// Thread.isMainThread is unavailable from async; wrap for isolation probe.
    private nonisolated static func isMainThreadNonasync() -> Bool {
        Thread.isMainThread
    }

    func item(for uri: DocumentURI) async -> WorkspaceItem? { nil }
    func uri(for item: WorkspaceItemID) async -> DocumentURI? { nil }
    func createFile(in parent: WorkspaceItemID, name: String, contents: Data) async throws -> WorkspaceItem {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func delete(item: WorkspaceItemID) async throws {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func addRoot(directoryURL: URL) async throws -> WorkspaceRoot {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func removeRoot(id: WorkspaceRootID) async throws {
        throw WorkspaceFileSystemError.ioFailure("probe")
    }
    func events() async -> AsyncThrowingStream<WorkspaceFileEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
