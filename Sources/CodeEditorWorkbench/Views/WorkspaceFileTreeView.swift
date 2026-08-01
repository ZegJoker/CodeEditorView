import CodeEditorDocuments
import CodeEditorWorkspace
import SwiftUI

/// Project navigator bound to ``Workspace/fileTree`` with Xcode-like interactions.
public struct WorkspaceFileTreeView: View {
    @Bindable var model: WorkbenchModel
    @State private var expansion: Set<String> = []
    @State private var childrenCache: [String: [WorkspaceItem]] = [:]
    @State private var loadError: String?
    @State private var isPresentingNewFile = false
    @State private var isPresentingNewFolder = false
    @State private var isPresentingRename = false
    @State private var newItemName = ""
    @State private var createParent: WorkspaceItemID?
    @State private var createParentIsDirectory = true
    @State private var renameTarget: WorkspaceItemID?
    @State private var filterText: String = ""

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterField
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.workspace.fileTree.roots, id: \.id.rawValue) { root in
                        rootRow(root)
                    }
                }
                .padding(.vertical, 4)
                .animation(WorkbenchMotion.fold, value: expansion)
                .animation(WorkbenchMotion.selection, value: model.selectedNavigatorItem)
            }
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .task {
            // Expand roots by default (Xcode opens the project group).
            for root in model.workspace.fileTree.roots {
                let key = rootKey(root.id)
                if !expansion.contains(key) {
                    expansion.insert(key)
                }
            }
            await loadExpandedNodes()
        }
        .task(id: expansion) {
            await loadExpandedNodes()
        }
        // Do NOT reload the tree on workspace.revision — open/select bumps revision and
        // wiping the cache made selection appear only after a slow async re-fetch.
        .alert("New File", isPresented: $isPresentingNewFile) {
            TextField("File name", text: $newItemName)
            Button("Cancel", role: .cancel) { newItemName = "" }
            Button("Create") {
                let name = sanitizedFileName(newItemName, defaultName: "Untitled.swift")
                model.createFile(named: name, in: resolvedCreateParent())
                newItemName = ""
            }
        } message: {
            Text("The file will be created in the selected folder (or project root).")
        }
        .alert("New Folder", isPresented: $isPresentingNewFolder) {
            TextField("Folder name", text: $newItemName)
            Button("Cancel", role: .cancel) { newItemName = "" }
            Button("Create") {
                let name = sanitizedFileName(newItemName, defaultName: "New Folder")
                model.createFolder(named: name, in: resolvedCreateParent())
                newItemName = ""
            }
        } message: {
            Text("The folder will be created under the selected folder (or project root).")
        }
        .alert("Rename", isPresented: $isPresentingRename) {
            TextField("Name", text: $newItemName)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                newItemName = ""
            }
            Button("Rename") {
                if let target = renameTarget {
                    let name = sanitizedFileName(newItemName, defaultName: target.name)
                    model.renameItem(target, to: name)
                }
                renameTarget = nil
                newItemName = ""
            }
        } message: {
            Text("Enter a new name.")
        }
        .alert(
            "Navigator Error",
            isPresented: Binding(
                get: { model.navigatorError != nil },
                set: { if !$0 { model.navigatorError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.navigatorError = nil }
        } message: {
            Text(model.navigatorError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("PROJECT NAVIGATOR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Spacer(minLength: 0)
            Menu {
                Button("New File…") {
                    prepareCreate(isDirectoryTarget: true)
                    newItemName = "Untitled.swift"
                    isPresentingNewFile = true
                }
                Button("New Folder…") {
                    prepareCreate(isDirectoryTarget: true)
                    newItemName = "New Folder"
                    isPresentingNewFolder = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Add")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Rows
    // Recursive rows return AnyView to avoid opaque-type self-reference errors.

    private func rootRow(_ root: WorkspaceRoot) -> AnyView {
        let key = rootKey(root.id)
        let itemID = WorkspaceItemID(rootID: root.id, path: "")
        let isExpanded = expansion.contains(key)
        let isSelected = model.selectedNavigatorItem == itemID

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                rowChrome(selected: isSelected) {
                    disclosureButton(key: key, expanded: isExpanded)
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 12))
                    Text(root.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // Immediate select (no exclusive double-tap delay). Double-click toggles.
                .onTapGesture {
                    withAnimation(WorkbenchMotion.selection) {
                        model.selectedNavigatorItem = itemID
                    }
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { toggleExpansion(key) }
                )
                .contextMenu {
                    Button("New File…") {
                        createParent = itemID
                        createParentIsDirectory = true
                        newItemName = "Untitled.swift"
                        isPresentingNewFile = true
                    }
                    Button("New Folder…") {
                        createParent = itemID
                        createParentIsDirectory = true
                        newItemName = "New Folder"
                        isPresentingNewFolder = true
                    }
                    Button(isExpanded ? "Collapse" : "Expand") {
                        toggleExpansion(key)
                    }
                }

                if isExpanded {
                    childrenStack(for: itemID, depth: 1)
                        .transition(WorkbenchMotion.foldChildren)
                }
            }
        )
    }

    private func childrenStack(for parent: WorkspaceItemID, depth: Int) -> AnyView {
        let kids = filteredChildren(of: parent)
        return AnyView(
            ForEach(kids, id: \.id.path) { item in
                itemRow(item, depth: depth)
                    .transition(WorkbenchMotion.foldChildren)
            }
        )
    }

    /// Prefer live file-tree cache (updates after create) over local snapshot.
    private func displayedChildren(of parent: WorkspaceItemID) -> [WorkspaceItem] {
        if let live = model.workspace.fileTree.cachedChildren(of: parent) {
            return live
        }
        return childrenCache[itemKey(parent)] ?? []
    }

    private func filteredChildren(of parent: WorkspaceItemID) -> [WorkspaceItem] {
        let kids = displayedChildren(of: parent)
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return kids }
        return kids.filter { item in
            if item.name.lowercased().contains(q) { return true }
            if item.isDirectory {
                // Keep folders that have matching descendants already loaded.
                return filteredChildren(of: item.id).isEmpty == false
                    || item.name.lowercased().contains(q)
            }
            return false
        }
    }

    private func itemContextMenu(for item: WorkspaceItem, isDirectory: Bool) -> some View {
        Group {
            if !isDirectory {
                Button("Open") { selectFile(item, preview: false) }
                Button("Open as Preview") { selectFile(item, preview: true) }
                Divider()
            }
            Button("New File…") {
                createParent =
                    isDirectory
                    ? item.id
                    : WorkspaceItemID(rootID: item.id.rootID, path: item.id.parentPath ?? "")
                createParentIsDirectory = true
                newItemName = "Untitled.swift"
                isPresentingNewFile = true
            }
            Button("New Folder…") {
                createParent =
                    isDirectory
                    ? item.id
                    : WorkspaceItemID(rootID: item.id.rootID, path: item.id.parentPath ?? "")
                createParentIsDirectory = true
                newItemName = "New Folder"
                isPresentingNewFolder = true
            }
            Divider()
            Button("Rename…") {
                renameTarget = item.id
                newItemName = item.name
                isPresentingRename = true
            }
            Button("Delete", role: .destructive) {
                model.deleteItem(item.id)
            }
            #if os(macOS)
                Divider()
                Button("Reveal in Finder") {
                    model.revealInFinder(item.id)
                }
            #endif
        }
    }

    private func itemRow(_ item: WorkspaceItem, depth: Int) -> AnyView {
        let key = itemKey(item.id)
        let isSelected = model.selectedNavigatorItem == item.id

        if item.isDirectory {
            let isExpanded = expansion.contains(key)
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    rowChrome(selected: isSelected) {
                        indent(depth)
                        disclosureButton(key: key, expanded: isExpanded)
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .foregroundStyle(.blue)
                            .font(.system(size: 12))
                        Text(item.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(WorkbenchMotion.selection) {
                            model.selectedNavigatorItem = item.id
                        }
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { toggleExpansion(key) }
                    )
                    .contextMenu {
                        itemContextMenu(for: item, isDirectory: true)
                        Divider()
                        Button(isExpanded ? "Collapse" : "Expand") {
                            toggleExpansion(key)
                        }
                    }

                    if isExpanded {
                        childrenStack(for: item.id, depth: depth + 1)
                            .transition(WorkbenchMotion.foldChildren)
                    }
                }
            )
        } else {
            return AnyView(
                rowChrome(selected: isSelected) {
                    indent(depth)
                    Color.clear.frame(width: 14, height: 14)
                    Image(systemName: fileIcon(for: item.name))
                        .foregroundStyle(fileIconColor(for: item.name))
                        .font(.system(size: 12))
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // Select immediately on first click; open preview. Double-click promotes permanent tab.
                .onTapGesture {
                    selectFile(item, preview: true)
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        selectFile(item, preview: false)
                    }
                )
                .contextMenu {
                    itemContextMenu(for: item, isDirectory: false)
                }
            )
        }
    }

    private func selectFile(_ item: WorkspaceItem, preview: Bool) {
        withAnimation(WorkbenchMotion.selection) {
            model.selectedNavigatorItem = item.id
        }
        model.openURI(item.uri, preview: preview)
    }

    // MARK: - Chrome helpers

    private func rowChrome<Content: View>(
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(selected ? 0.22 : 0))
                .padding(.horizontal, 4)
        }
        .animation(WorkbenchMotion.selection, value: selected)
    }

    private func disclosureButton(key: String, expanded: Bool) -> some View {
        Button {
            toggleExpansion(key)
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(WorkbenchMotion.fold, value: expanded)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func indent(_ depth: Int) -> some View {
        Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md", "txt": return "doc.plaintext"
        case "json", "yml", "yaml", "plist", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private func fileIconColor(for name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "json", "yml", "yaml": return .purple
        default: return .secondary
        }
    }

    // MARK: - Expansion / loading

    private func toggleExpansion(_ key: String) {
        withAnimation(WorkbenchMotion.fold) {
            if expansion.contains(key) {
                expansion.remove(key)
            } else {
                expansion.insert(key)
            }
        }
    }

    private func rootKey(_ id: WorkspaceRootID) -> String {
        "root:\(id.rawValue.uuidString)"
    }

    private func itemKey(_ id: WorkspaceItemID) -> String {
        "\(id.rootID.rawValue.uuidString)/\(id.path)"
    }

    private func prepareCreate(isDirectoryTarget: Bool) {
        createParentIsDirectory = isDirectoryTarget
        if let selected = model.selectedNavigatorItem {
            createParent = selected
        } else if let root = model.workspace.fileTree.roots.first {
            createParent = WorkspaceItemID(rootID: root.id, path: "")
        } else {
            createParent = nil
        }
    }

    private func resolvedCreateParent() -> WorkspaceItemID? {
        guard
            let parent = createParent ?? model.selectedNavigatorItem
                ?? model.workspace.fileTree.roots.first.map({
                    WorkspaceItemID(rootID: $0.id, path: "")
                })
        else { return nil }

        // If the selection is a file, create beside it (in its parent folder).
        if !createParentIsDirectory, !parent.path.isEmpty {
            // Check cache: if item is a file, use parent path.
            // createParent is set from context menus with correct flag; for header +,
            // infer from selection against cache.
        }

        if let selected = createParent ?? model.selectedNavigatorItem {
            // Walk cache to see if selected is a file.
            if isKnownFile(selected) {
                return WorkspaceItemID(rootID: selected.rootID, path: selected.parentPath ?? "")
            }
        }
        return parent
    }

    private func isKnownFile(_ id: WorkspaceItemID) -> Bool {
        if id.path.isEmpty { return false }
        let parent = WorkspaceItemID(rootID: id.rootID, path: id.parentPath ?? "")
        let kids = displayedChildren(of: parent)
        if kids.contains(where: { $0.id == id && !$0.isDirectory }) {
            return true
        }
        if kids.contains(where: { $0.id == id && $0.isDirectory }) {
            return false
        }
        // Heuristic: has path extension and not currently expanded as directory.
        return !expansion.contains(itemKey(id))
            && !(id.name as NSString).pathExtension.isEmpty
    }

    private func sanitizedFileName(_ raw: String, defaultName: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultName }
        // Block path separators.
        return
            trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func loadExpandedNodes() async {
        loadError = nil
        for root in model.workspace.fileTree.roots {
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            if expansion.contains(rootKey(root.id)) {
                await loadChildren(rootItem)
            }
        }
        for key in expansion where !key.hasPrefix("root:") {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                let uuid = UUID(uuidString: parts[0])
            else { continue }
            let item = WorkspaceItemID(rootID: WorkspaceRootID(rawValue: uuid), path: parts[1])
            await loadChildren(item)
        }
    }

    private func loadChildren(_ id: WorkspaceItemID) async {
        do {
            try await model.workspace.fileTree.expand(id)
            let kids = try await model.workspace.fileTree.children(of: id)
            childrenCache[itemKey(id)] = kids
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Built-in contribution

@MainActor
final class FileTreeNavigatorContribution: WorkbenchContribution {
    let id = "workbench.navigator.files"
    let slot: WorkbenchSlot = .navigator
    let priority = 100
    let title = "Project"
    let systemImage = "folder"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkspaceFileTreeView(model: context.model))
    }
}

@MainActor
final class StatusBarContribution: WorkbenchContribution {
    let id = "workbench.status.default"
    let slot: WorkbenchSlot = .statusBar
    let priority = 100
    let title = "Status"
    let systemImage = "info.circle"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkbenchStatusBar(model: context.model))
    }
}

@MainActor
final class UtilityPlaceholderContribution: WorkbenchContribution {
    let id: String
    let slot: WorkbenchSlot = .utility
    let priority: Int
    let title: String
    let systemImage: String
    let emptyDescription: String

    init(id: String, title: String, systemImage: String, priority: Int, emptyDescription: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.priority = priority
        self.emptyDescription = emptyDescription
    }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

/// Path control for a **specific** editor pane (not the workspace-active document).
struct WorkbenchBreadcrumbBar: View {
    @Bindable var model: WorkbenchModel
    let paneID: EditorPaneID

    var body: some View {
        let _ = model.workspace.revision
        HStack(spacing: 4) {
            if let doc = documentForThisPane {
                let fullPath = doc.uri.fileURL?.path ?? doc.uri.rawValue
                let parts = fullPath.split(separator: "/").map(String.init)
                let tail = Array(parts.suffix(4))
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Array(tail.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.forward")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = index == tail.count - 1
                    Text(part)
                        .font(.caption.weight(isLast ? .medium : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .lineLimit(1)
                        .help(isLast ? fullPath : part)
                }
                if doc.isDirty {
                    Circle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
            } else {
                Text("No Editor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar.opacity(0.6))
        .help(documentForThisPane.map { $0.uri.fileURL?.path ?? $0.uri.rawValue } ?? "No editor")
    }

    private var documentForThisPane: TextDocument? {
        guard let pane = model.workspace.panes[paneID],
            let tab = pane.selectedTab
        else { return nil }
        return model.workspace.documents.document(id: tab.documentID)
    }
}

struct WorkbenchStatusBar: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        // No per-contribution background — shell `statusBar` paints a single shared `.bar`.
        HStack(spacing: 12) {
            if let doc = model.activeDocument {
                Text(doc.uri.fileURL?.lastPathComponent ?? doc.uri.rawValue)
                if doc.isDirty {
                    Text("●").foregroundStyle(.orange)
                }
                Text(lineColumnLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("No file")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let language = languageLabel {
                Text(language)
                    .foregroundStyle(.secondary)
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var lineColumnLabel: String {
        guard let session = model.activeSession,
            let sel = session.selections.first,
            let doc = model.activeDocument
        else { return "Ln — Col —" }
        let text = doc.text as NSString
        let loc = min(max(sel.location, 0), text.length)
        var line = 1
        var col = 1
        var i = 0
        while i < loc {
            let ch = text.character(at: i)
            if ch == 10 {  // \n
                line += 1
                col = 1
            } else if ch == 13 {  // \r
                line += 1
                col = 1
                if i + 1 < loc, text.character(at: i + 1) == 10 {
                    i += 1
                }
            } else {
                col += 1
            }
            i += 1
        }
        return "Ln \(line), Col \(col)"
    }

    private var languageLabel: String? {
        guard let doc = model.activeDocument else { return nil }
        let ext = doc.uri.fileURL?.pathExtension.lowercased() ?? ""
        if ext.isEmpty { return nil }
        return ext.uppercased()
    }
}
