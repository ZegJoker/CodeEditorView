import CodeEditorDocuments
import CodeEditorView
import CodeEditorWorkspace
import SwiftUI

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
        case .split(let id, let axis, let children, let fractions):
            return AnyView(
                WorkbenchSplitContainer(
                    model: model,
                    splitID: id,
                    axis: axis,
                    children: children,
                    fractions: fractions
                )
            )
        }
    }
}

/// Fraction-aware split that persists divider positions into ``EditorLayoutStore``.
/// Used on all platforms so macOS no longer ignores restored fractions via `HSplitView`.
struct WorkbenchSplitContainer: View {
    @Bindable var model: WorkbenchModel
    let splitID: EditorSplitID
    let axis: EditorSplitAxis
    let children: [EditorLayoutNode]
    let fractions: [Double]

    private let dividerThickness: CGFloat = 5
    private let minFraction: Double = 0.12

    var body: some View {
        GeometryReader { geo in
            let totalMain = axis == .horizontal ? geo.size.width : geo.size.height
            let fracs = Self.normalize(fractions, count: children.count)
            let dividerCount = max(children.count - 1, 0)
            let available = max(totalMain - CGFloat(dividerCount) * dividerThickness, 1)

            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                            layoutChild(child)
                                .frame(width: available * fracs[min(index, fracs.count - 1)])
                            if index < children.count - 1 {
                                WorkbenchSplitDivider(
                                    model: model,
                                    splitID: splitID,
                                    axis: axis,
                                    dividerIndex: index,
                                    available: available,
                                    currentFractions: fracs,
                                    thickness: dividerThickness,
                                    minFraction: minFraction
                                )
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                            layoutChild(child)
                                .frame(height: available * fracs[min(index, fracs.count - 1)])
                            if index < children.count - 1 {
                                WorkbenchSplitDivider(
                                    model: model,
                                    splitID: splitID,
                                    axis: axis,
                                    dividerIndex: index,
                                    available: available,
                                    currentFractions: fracs,
                                    thickness: dividerThickness,
                                    minFraction: minFraction
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
    }

    static func normalize(_ fractions: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if fractions.count == count {
            let sum = fractions.reduce(0, +)
            guard sum > 0 else {
                return Array(repeating: 1.0 / Double(count), count: count)
            }
            return fractions.map { $0 / sum }
        }
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    private func layoutChild(_ node: EditorLayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            return AnyView(
                WorkbenchPaneView(model: model, paneID: paneID)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            )
        case .split(let id, let axis, let kids, let fracs):
            return AnyView(
                WorkbenchSplitContainer(
                    model: model,
                    splitID: id,
                    axis: axis,
                    children: kids,
                    fractions: fracs
                )
            )
        }
    }
}

/// Drag handle between split panes; applies translation against fractions captured at drag start.
private struct WorkbenchSplitDivider: View {
    @Bindable var model: WorkbenchModel
    let splitID: EditorSplitID
    let axis: EditorSplitAxis
    let dividerIndex: Int
    let available: CGFloat
    let currentFractions: [Double]
    let thickness: CGFloat
    let minFraction: Double

    @State private var dragStartFractions: [Double]?

    var body: some View {
        let isHorizontal = axis == .horizontal
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(
                width: isHorizontal ? thickness : nil,
                height: isHorizontal ? nil : thickness
            )
            .frame(
                maxWidth: isHorizontal ? thickness : .infinity,
                maxHeight: isHorizontal ? .infinity : thickness
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartFractions == nil {
                            dragStartFractions = currentFractions
                        }
                        guard let base = dragStartFractions,
                            base.indices.contains(dividerIndex),
                            base.indices.contains(dividerIndex + 1)
                        else { return }
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let deltaFrac = Double(delta / max(available, 1))
                        var next = base
                        let pair = next[dividerIndex] + next[dividerIndex + 1]
                        var newLeft = next[dividerIndex] + deltaFrac
                        newLeft = min(max(newLeft, minFraction), pair - minFraction)
                        next[dividerIndex] = newLeft
                        next[dividerIndex + 1] = pair - newLeft
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            model.workspace.setSplitFractions(splitID, fractions: next)
                        }
                    }
                    .onEnded { _ in
                        dragStartFractions = nil
                    }
            )
            #if os(macOS)
                .onHover { hovering in
                    if hovering {
                        if isHorizontal {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.resizeUpDown.set()
                        }
                    } else {
                        NSCursor.arrow.set()
                    }
                }
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
                let session = model.workspace.sessions[tab.sessionID]
            {
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
    @State private var draggingTabID: EditorTabID?

    var body: some View {
        let _ = model.workspace.revision
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id.rawValue) { index, tab in
                    tabButton(tab, index: index)
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
                        model.paneTaskBag(for: pane.id).store(Task { @MainActor in
                            let result = await model.requestClosePane(pane.id)
                            if result == .closed {
                                withAnimation(WorkbenchMotion.pane) {
                                    // Layout already updated by requestClosePane.
                                    _ = model.workspace.revision
                                }
                            }
                        })
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
    private func tabButton(_ tab: EditorTab, index: Int) -> some View {
        let selected = pane.selectedTabID == tab.id
        let title = displayTitle(for: tab)
        let dirty = model.workspace.documents.document(id: tab.documentID)?.isDirty == true
        HStack(spacing: 6) {
            if dirty {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
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
                model.paneTaskBag(for: pane.id).store(Task { @MainActor in
                    let result = await model.workspace.requestCloseTab(tab.id, in: pane.id)
                    if result == .closed {
                        withAnimation(WorkbenchMotion.tab) {}
                    }
                })
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
        .onDrag {
            draggingTabID = tab.id
            return NSItemProvider(object: tab.id.rawValue.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let fromID = draggingTabID,
                let fromIndex = pane.tabs.firstIndex(where: { $0.id == fromID })
            else { return false }
            var toIndex = index
            if fromIndex < toIndex {
                toIndex = min(toIndex, pane.tabs.count - 1)
            }
            withAnimation(WorkbenchMotion.tab) {
                model.workspace.moveTab(from: fromIndex, to: toIndex, in: pane.id)
            }
            draggingTabID = nil
            return true
        }
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
                model.paneTaskBag(for: pane.id).store(Task { @MainActor in
                    let _: CloseTransactionResult = await model.workspace.requestCloseTab(
                        tab.id,
                        in: pane.id
                    )
                })
            }
            Button("Close Others") {
                model.paneTaskBag(for: pane.id).store(Task { @MainActor in
                    let _: CloseTransactionResult = await model.workspace.requestCloseOtherTabs(
                        keeping: tab.id,
                        in: pane.id
                    )
                })
            }
            Button("Close to the Right") {
                model.paneTaskBag(for: pane.id).store(Task { @MainActor in
                    let _: CloseTransactionResult = await model.workspace.requestCloseTabsToTheRight(
                        of: tab.id,
                        in: pane.id
                    )
                })
            }
        }
    }

    /// Disambiguate duplicate filenames with parent folder (Xcode-like).
    private func displayTitle(for tab: EditorTab) -> String {
        let name =
            tab.documentURI.fileURL?.lastPathComponent
            ?? tab.documentURI.rawValue
        let sameNameCount = pane.tabs.filter {
            ($0.documentURI.fileURL?.lastPathComponent ?? $0.documentURI.rawValue) == name
        }.count
        guard sameNameCount > 1,
            let parent = tab.documentURI.fileURL?.deletingLastPathComponent().lastPathComponent,
            !parent.isEmpty
        else { return name }
        return "\(parent)/\(name)"
    }
}
