import SwiftUI
import CodeEditorDocuments
import CodeEditorWorkspace
import CodeEditorView

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Recursively renders the workspace editor layout tree.
public struct WorkbenchEditorArea: View {
    @Bindable var model: WorkbenchModel

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        // Depend on revision so pane/tab mutations always refresh.
        let _ = model.workspace.revision
        layoutView(model.workspace.layout.root)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(WorkbenchMotion.pane, value: model.workspace.revision)
    }

    private func layoutView(_ node: EditorLayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            return AnyView(
                WorkbenchPaneView(model: model, paneID: paneID)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            )
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
                .transition(.opacity)
            )
        } else {
            return AnyView(
                VSplitView {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        layoutView(child)
                    }
                }
                .transition(.opacity)
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
            .transition(.opacity)
        )
        #endif
    }
}

public struct WorkbenchPaneView: View {
    @Bindable var model: WorkbenchModel
    let paneID: EditorPaneID

    public var body: some View {
        let _ = model.workspace.revision
        let _ = model.contributionRegistry.revision
        let paneCount = model.workspace.panes.count
        let isActive = paneID == model.workspace.activePaneID
        // Only emphasize the active editor group when more than one pane exists.
        let showActiveOutline = paneCount > 1 && isActive
        VStack(spacing: 0) {
            if let pane = model.workspace.panes[paneID] {
                WorkbenchTabBar(model: model, pane: pane)
                // Per-pane breadcrumb (not the global active document).
                WorkbenchBreadcrumbBar(model: model, paneID: paneID)
                Divider().opacity(0.4)
                content(for: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyEditorPlaceholder(
                    title: "Missing Pane",
                    systemImage: "rectangle.split.3x1",
                    description: "This editor pane is no longer available."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paneBackground)
        .overlay {
            if showActiveOutline {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.workspace.setActivePane(paneID)
        }
    }

    private var paneBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    @ViewBuilder
    private func content(for pane: EditorPane) -> some View {
        // Read selection explicitly so tab switches invalidate even if revision is missed.
        let selectedTabID = pane.selectedTabID
        let _ = selectedTabID
        ZStack {
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
                // Force a fresh document view per tab so NSViewRepresentable remounts.
                model.documentViewRegistry.makeView(context: context)
                    .id(tab.id.rawValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(WorkbenchMotion.editorContent)
            } else {
                emptyEditorPlaceholder(
                    title: "No Editor",
                    systemImage: "doc.text",
                    description: "Open a file from the navigator or Open Quickly."
                )
                .transition(WorkbenchMotion.editorContent)
            }
        }
        .animation(WorkbenchMotion.content, value: selectedTabID)
        .animation(WorkbenchMotion.content, value: model.workspace.revision)
    }

    private func emptyEditorPlaceholder(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paneBackground)
    }
}

struct WorkbenchTabBar: View {
    @Bindable var model: WorkbenchModel
    let pane: EditorPane

    var body: some View {
        let _ = model.workspace.revision
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(pane.tabs, id: \.id.rawValue) { tab in
                    tabButton(tab)
                        .transition(WorkbenchMotion.tabInsert)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Split Right") {
                        withAnimation(WorkbenchMotion.pane) {
                            model.workspace.setActivePane(pane.id)
                            _ = model.workspace.splitActivePane(axis: .horizontal)
                        }
                    }
                    Button("Split Down") {
                        withAnimation(WorkbenchMotion.pane) {
                            model.workspace.setActivePane(pane.id)
                            _ = model.workspace.splitActivePane(axis: .vertical)
                        }
                    }
                    Divider()
                    Button("Close Pane", role: .destructive) {
                        withAnimation(WorkbenchMotion.pane) {
                            model.workspace.closePane(pane.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .padding(6)
                }
                .menuStyle(.borderlessButton)
            }
            .animation(WorkbenchMotion.tab, value: pane.tabs.map(\.id.rawValue))
            .animation(WorkbenchMotion.tab, value: pane.selectedTabID)
        }
        .frame(height: 34)
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
                    .transition(.scale.combined(with: .opacity))
            }
            Button {
                withAnimation(WorkbenchMotion.tab) {
                    model.workspace.closeTab(tab.id, in: pane.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0))
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor.opacity(selected ? 1 : 0))
                .frame(height: 2)
        }
        .animation(WorkbenchMotion.tab, value: selected)
        .animation(WorkbenchMotion.tab, value: tab.isPreview)
        .contentShape(Rectangle())
        // Single-click selects; double-click keeps a preview tab open (no longer replaced).
        .onTapGesture {
            withAnimation(WorkbenchMotion.tab) {
                model.workspace.selectTab(tab.id, in: pane.id)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                withAnimation(WorkbenchMotion.tab) {
                    model.workspace.selectTab(tab.id, in: pane.id)
                    model.workspace.keepTabOpen(tab.id, in: pane.id)
                }
            }
        )
        .help(tab.isPreview ? "Preview tab — double-click to keep open" : title)
        .contextMenu {
            if tab.isPreview {
                Button("Keep Open") {
                    withAnimation(WorkbenchMotion.tab) {
                        model.workspace.keepTabOpen(tab.id, in: pane.id)
                    }
                }
            }
            if !tab.isPinned {
                Button("Pin Tab") {
                    withAnimation(WorkbenchMotion.tab) {
                        model.workspace.pinTab(tab.id, in: pane.id)
                    }
                }
            }
            Button("Close") {
                withAnimation(WorkbenchMotion.tab) {
                    model.workspace.closeTab(tab.id, in: pane.id)
                }
            }
            Button("Close Others") {
                withAnimation(WorkbenchMotion.tab) {
                    model.workspace.closeOtherTabs(keeping: tab.id, in: pane.id)
                }
            }
            Button("Close to the Right") {
                withAnimation(WorkbenchMotion.tab) {
                    model.workspace.closeTabsToTheRight(of: tab.id, in: pane.id)
                }
            }
        }
    }
}
