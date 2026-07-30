import SwiftUI
import CodeEditorDocuments
import CodeEditorWorkspace
import CodeEditorView

/// Recursively renders the workspace editor layout tree.
public struct WorkbenchEditorArea: View {
    @Bindable var model: WorkbenchModel

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        layoutView(model.workspace.layout.root)
    }

    private func layoutView(_ node: EditorLayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            return AnyView(WorkbenchPaneView(model: model, paneID: paneID))
        case .split(_, let axis, let children, let fractions):
            return AnyView(splitView(axis: axis, children: children, fractions: fractions))
        }
    }

    private func splitView(
        axis: EditorSplitAxis,
        children: [EditorLayoutNode],
        fractions: [Double]
    ) -> AnyView {
        #if os(macOS)
        if axis == .horizontal {
            return AnyView(
                HSplitView {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        layoutView(child)
                    }
                }
            )
        } else {
            return AnyView(
                VSplitView {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        layoutView(child)
                    }
                }
            )
        }
        #else
        return AnyView(
            GeometryReader { geo in
                let total = axis == .horizontal ? geo.size.width : geo.size.height
                let fracs = fractions.isEmpty
                    ? Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
                    : fractions
                if axis == .horizontal {
                    HStack(spacing: 1) {
                        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                            layoutView(child)
                                .frame(width: total * fracs[min(index, fracs.count - 1)])
                        }
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                            layoutView(child)
                                .frame(height: total * fracs[min(index, fracs.count - 1)])
                        }
                    }
                }
            }
        )
        #endif
    }
}

public struct WorkbenchPaneView: View {
    @Bindable var model: WorkbenchModel
    let paneID: EditorPaneID

    public var body: some View {
        VStack(spacing: 0) {
            if let pane = model.workspace.panes[paneID] {
                WorkbenchTabBar(model: model, pane: pane)
                Divider()
                content(for: pane)
            } else {
                ContentUnavailableView("Missing pane", systemImage: "rectangle.split.3x1")
            }
        }
        .background(paneID == model.workspace.activePaneID ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.workspace.setActivePane(paneID)
        }
    }

    @ViewBuilder
    private func content(for pane: EditorPane) -> some View {
        if let tab = pane.selectedTab,
           let document = model.workspace.documents.document(id: tab.documentID),
           let session = model.workspace.sessions[tab.sessionID] {
            let context = DocumentViewContext(
                workspace: model.workspace,
                document: document,
                session: session,
                paneID: paneID,
                tabID: tab.id,
                commandDispatcher: model.commandDispatcher,
                editorConfiguration: model.configuration.editorConfiguration,
                clientRegistry: model.editorClientRegistry
            )
            model.documentViewRegistry.makeView(context: context)
        } else {
            ContentUnavailableView(
                "No Editor",
                systemImage: "doc.text",
                description: Text("Open a file from the explorer or Open Quickly.")
            )
        }
    }
}

struct WorkbenchTabBar: View {
    @Bindable var model: WorkbenchModel
    let pane: EditorPane

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(pane.tabs, id: \.id.rawValue) { tab in
                    tabButton(tab)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Split Right") {
                        model.workspace.setActivePane(pane.id)
                        _ = model.workspace.splitActivePane(axis: .horizontal)
                    }
                    Button("Split Down") {
                        model.workspace.setActivePane(pane.id)
                        _ = model.workspace.splitActivePane(axis: .vertical)
                    }
                    Divider()
                    Button("Close Pane", role: .destructive) {
                        model.workspace.closePane(pane.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .padding(6)
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }

    @ViewBuilder
    private func tabButton(_ tab: EditorTab) -> some View {
        let selected = pane.selectedTabID == tab.id
        let title = tab.documentURI.fileURL?.lastPathComponent
            ?? tab.documentURI.rawValue
        HStack(spacing: 6) {
            if tab.isPreview {
                Text(title).italic()
            } else {
                Text(title)
            }
            if tab.isPinned {
                Image(systemName: "pin.fill").font(.caption2)
            }
            Button {
                model.workspace.closeTab(tab.id, in: pane.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
        .onTapGesture {
            model.workspace.setActivePane(pane.id)
            pane.select(tab: tab.id)
        }
        .contextMenu {
            Button("Pin Tab") { model.workspace.pinTab(tab.id, in: pane.id) }
            Button("Close") { model.workspace.closeTab(tab.id, in: pane.id) }
            Button("Close Others") {
                model.workspace.closeOtherTabs(keeping: tab.id, in: pane.id)
            }
            Button("Close to the Right") {
                model.workspace.closeTabsToTheRight(of: tab.id, in: pane.id)
            }
        }
    }
}
