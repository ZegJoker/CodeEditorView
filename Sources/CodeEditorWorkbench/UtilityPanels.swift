import CodeEditorCore
import CodeEditorDocuments
import CodeEditorTerminal
import CodeEditorTerminalGhostty
import Observation
import SwiftUI

// MARK: - Output panel

@MainActor
public final class WorkbenchOutputPanelModel: ObservableObject {
    @Published public private(set) var lines: [String] = []
    @Published public var channelName: String = "Output"
    private let maxLines = 10_000

    public init() {}

    public func append(_ text: String) {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append(contentsOf: parts)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    public func clear() { lines.removeAll() }
}

@MainActor
public final class WorkbenchOutputPanelContribution: WorkbenchContribution {
    public let id = "workbench.utility.output"
    public let slot: WorkbenchSlot = .utility
    public let title = "Output"
    public let systemImage = "list.bullet.rectangle"
    public let priority: Int = 10
    private let model: WorkbenchOutputPanelModel

    public init(model: WorkbenchOutputPanelModel = WorkbenchOutputPanelModel()) {
        self.model = model
    }

    public func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkbenchOutputPanelView(model: model))
    }
}

struct WorkbenchOutputPanelView: View {
    @ObservedObject var model: WorkbenchOutputPanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.channelName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clear() }.font(.caption).buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .workbenchAccessibilityChrome(id: "workbench.utility.output", label: "Output", role: .textArea)
        #else
        .accessibilityIdentifier("workbench.utility.output")
        #endif
    }
}

// MARK: - Problems panel

@MainActor
public final class WorkbenchProblemsPanelModel: ObservableObject {
    public struct Item: Identifiable, Hashable {
        public var id: String
        public var severity: String
        public var message: String
        public var path: String
        public var line: Int
        public var column: Int

        public init(
            id: String = UUID().uuidString,
            severity: String,
            message: String,
            path: String,
            line: Int,
            column: Int
        ) {
            self.id = id
            self.severity = severity
            self.message = message
            self.path = path
            self.line = line
            self.column = column
        }
    }

    @Published public private(set) var items: [Item] = []
    public init() {}
    public func setItems(_ items: [Item]) { self.items = items }
    public func append(_ item: Item) { items.append(item) }
    public func clear() { items.removeAll() }
}

@MainActor
public final class WorkbenchProblemsPanelContribution: WorkbenchContribution {
    public let id = "workbench.utility.problems"
    public let slot: WorkbenchSlot = .utility
    public let title = "Problems"
    public let systemImage = "exclamationmark.triangle"
    public let priority: Int = 20
    private let model: WorkbenchProblemsPanelModel

    public init(model: WorkbenchProblemsPanelModel = WorkbenchProblemsPanelModel()) {
        self.model = model
    }

    public func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkbenchProblemsPanelView(model: model, context: context))
    }
}

struct WorkbenchProblemsPanelView: View {
    @ObservedObject var model: WorkbenchProblemsPanelModel
    let context: WorkbenchContributionContext

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.items.count) problems").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clear() }.font(.caption).buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            if model.items.isEmpty {
                Text("No problems")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(
                            systemName: item.severity == "warning"
                                ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
                        )
                        .foregroundStyle(item.severity == "warning" ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.message).font(.caption)
                            Text("\(item.path):\(item.line + 1):\(item.column + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let url = URL(fileURLWithPath: item.path)
                        Task { @MainActor in
                            _ = try? await context.workspace.openInActivePane(
                                uri: DocumentURI(fileURL: url),
                                preview: true
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .workbenchAccessibilityChrome(id: "workbench.utility.problems", label: "Problems", role: .list)
        #else
        .accessibilityIdentifier("workbench.utility.problems")
        #endif
    }
}

// MARK: - Terminal panel (Ghostty-backed, TER-004 / E13)

@MainActor
public final class WorkbenchTerminalPanelModel: ObservableObject {
    @Published public private(set) var sessionID: TerminalSessionID?
    @Published public private(set) var snapshot: String = ""
    @Published public private(set) var title: String = "Terminal"
    @Published public var errorMessage: String?
    @Published public private(set) var isRunning: Bool = false

    public let service: TerminalService
    private var controller: GhosttySessionController?
    private var pollTask: Task<Void, Never>?

    public init(service: TerminalService? = nil) {
        // REL-N08: production workbench terminal fails closed unless Ghostty is linked.
        self.service = service ?? TerminalService(
            securityPolicy: .restricted,
            requireGhosttyLinked: true,
            isGhosttyLinked: { GhosttySessionController.isLinked }
        )
    }

    public func startIfNeeded() {
        guard sessionID == nil else { return }
        #if os(macOS)
            Task { await self.startMacSession() }
        #else
            errorMessage = "Local PTY is unavailable on this platform profile; use remote transport."
        #endif
    }

    #if os(macOS)
        private func startMacSession() async {
            do {
                // Production path requires linked Ghostty (default requireLinked: true).
                // Production path requires linked Ghostty (default requireLinked: true).
                // Hard-unavailable when unlinked — never present a fake terminal as Ghostty (TER-N01/N02).
                let ghostty = try GhosttySessionController(cols: 80, rows: 24, requireLinked: true)
                self.controller = ghostty
                let supervisor = ProcessSupervisor()
                let transport = LocalPTYTransport(
                    securityPolicy: .forProfile(.macOSDirect),
                    supervisor: supervisor
                )
                final class SessionBox: @unchecked Sendable {
                    var id: TerminalSessionID?
                }
                let sessionBox = SessionBox()
                let id = try await service.create(
                    metadata: TerminalMetadata(kind: .terminal, title: "Terminal"),
                    configuration: TerminalConfiguration(cols: 80, rows: 24),
                    transport: transport,
                    onOutput: { [weak self] data in
                        // TER-N05: raw bytes into Ghostty only — never String(data:encoding:).
                        guard let self else { return }
                        do {
                            try await ghostty.write(data)
                            let gen = await ghostty.currentGeneration()
                            let snap = try await ghostty.snapshotUTF8()
                            if let sid = sessionBox.id {
                                await self.service.updateViewport(plainText: snap, generation: gen, for: sid)
                            }
                            await MainActor.run {
                                self.snapshot = snap
                                self.isRunning = true
                            }
                        } catch {
                            await MainActor.run {
                                self.errorMessage = String(describing: error)
                            }
                        }
                    }
                )
                sessionBox.id = id
                await MainActor.run {
                    self.sessionID = id
                    self.title = GhosttySessionController.integrationClaim
                    self.isRunning = true
                    self.errorMessage = nil
                    // Dirty generation pull — not a full O(n²) string rebuild (TER-N06).
                    self.pollTask = Task { @MainActor in
                        var lastGen: UInt64 = 0
                        while !Task.isCancelled {
                            if let c = self.controller {
                                let gen = await c.currentGeneration()
                                if gen != lastGen {
                                    lastGen = gen
                                    if let snap = try? await c.snapshotUTF8() {
                                        self.snapshot = snap
                                    }
                                }
                            }
                            if let id = self.sessionID {
                                let states = await self.service.allSessions()
                                if let s = states.first(where: { $0.id == id }) {
                                    self.isRunning = s.isRunning
                                }
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = String(describing: error)
                }
            }
        }
    #endif

    public func writeKey(_ data: Data) {
        guard let id = sessionID else { return }
        Task {
            if let c = controller {
                do {
                    let encoded = try await c.keyInput(data)
                    try await service.write(encoded, to: id)
                } catch {
                    await MainActor.run { self.errorMessage = String(describing: error) }
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Terminal unavailable: Ghostty not linked"
                }
            }
        }
    }

    public func writeKeyEvent(_ event: GhosttyKeyEvent) {
        guard let id = sessionID else { return }
        Task {
            if let c = controller {
                do {
                    let encoded = try await c.encodeKey(event)
                    if !encoded.isEmpty {
                        try await service.write(encoded, to: id)
                    }
                } catch {
                    await MainActor.run { self.errorMessage = String(describing: error) }
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Terminal unavailable: Ghostty not linked"
                }
            }
        }
    }

    public func killSession() {
        guard let id = sessionID else { return }
        Task {
            await service.close(id, reason: .user)
            await controller?.shutdown()
            await MainActor.run {
                self.sessionID = nil
                self.isRunning = false
                self.pollTask?.cancel()
            }
        }
    }

    deinit { pollTask?.cancel() }
}

@MainActor
public final class WorkbenchTerminalPanelContribution: WorkbenchContribution {
    public let id = "workbench.utility.terminal"
    public let slot: WorkbenchSlot = .utility
    public let title = "Terminal"
    public let systemImage = "terminal"
    public let priority: Int = 30
    private let model: WorkbenchTerminalPanelModel

    public init(model: WorkbenchTerminalPanelModel = WorkbenchTerminalPanelModel()) {
        self.model = model
    }

    public func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkbenchTerminalPanelView(model: model).onAppear { self.model.startIfNeeded() })
    }
}

struct WorkbenchTerminalPanelView: View {
    @ObservedObject var model: WorkbenchTerminalPanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isRunning {
                    Button("Kill") { model.killSession() }
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            if let err = model.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(8)
            }
            #if os(macOS)
                if let id = model.sessionID {
                    GhosttySurfaceRepresentable(
                        sessionID: id,
                        snapshot: model.snapshot,
                        integrationLevel: GhosttySessionController.currentIntegrationLevel,
                        onKeyEvent: { model.writeKeyEvent($0) },
                        onKeyData: { model.writeKey($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Starting Terminal…",
                        systemImage: "terminal",
                        description: Text("Ghostty-backed session")
                    )
                }
            #else
                Text(model.snapshot)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            #endif
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .workbenchAccessibilityChrome(
            id: "workbench.utility.terminal",
            label: GhosttyAccessibilityAdapter.from(
                snapshot: model.snapshot, title: model.title, isRunning: model.isRunning
            ).accessibilityLabel,
            role: .textArea
        )
        #else
        .accessibilityIdentifier("workbench.utility.terminal")
        .accessibilityLabel(
            GhosttyAccessibilityAdapter.from(
                snapshot: model.snapshot, title: model.title, isRunning: model.isRunning
            ).accessibilityLabel
        )
        #endif
        .accessibilityValue(model.snapshot)
    }
}
