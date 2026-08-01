import SwiftUI
import Observation
import CodeEditorDocuments
import CodeEditorTerminal

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
        .accessibilityIdentifier("workbench.utility.output")
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
                        Image(systemName: item.severity == "warning" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
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
        .accessibilityIdentifier("workbench.utility.problems")
    }
}

// MARK: - Terminal panel

@MainActor
public final class WorkbenchTerminalPanelModel: ObservableObject {
    @Published public private(set) var session: TerminalSession?
    @Published public private(set) var screenText: String = ""
    @Published public var errorMessage: String?
    public let manager = TerminalSessionManager()
    private var pollTask: Task<Void, Never>?
    private var sessionID: TerminalSessionID?

    public init() {}

    public func startIfNeeded() {
        guard session == nil else { return }
        #if os(macOS)
        Task {
            await manager.attach(backend: PTYTerminalBackend())
            do {
                let s = try await manager.create(title: "Terminal")
                await MainActor.run {
                    self.session = s
                    self.sessionID = s.id
                    self.pollTask = Task { @MainActor in
                        while !Task.isCancelled {
                            if let id = self.sessionID,
                               let screen = await manager.screen(for: id)
                            {
                                self.screenText = screen.accessibilityText(includeScrollback: true)
                                if let live = await manager.allSessions().first(where: { $0.id == id }) {
                                    self.session = live
                                }
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                }
            } catch {
                await MainActor.run { self.errorMessage = String(describing: error) }
            }
        }
        #else
        errorMessage = "Local PTY is unavailable on this platform profile"
        #endif
    }

    public func write(_ text: String) {
        guard let id = sessionID else { return }
        Task { try? await manager.write(text, to: id) }
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
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(8)
            }
            ScrollView {
                Text(model.screenText.isEmpty ? " " : model.screenText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            Divider()
            HStack {
                TextField("Send input…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        model.write(input + "\n")
                        input = ""
                    }
                Button("Send") {
                    model.write(input + "\n")
                    input = ""
                }
                .font(.caption)
            }
            .padding(8)
        }
        .accessibilityIdentifier("workbench.utility.terminal")
    }
}
