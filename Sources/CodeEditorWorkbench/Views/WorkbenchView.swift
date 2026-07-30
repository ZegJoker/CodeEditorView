import SwiftUI
import CodeEditorCommands
import CodeEditorView

/// Top-level SwiftUI workbench shell.
public struct WorkbenchView: View {
    @Bindable public var model: WorkbenchModel

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.configuration.showsToolbar {
                toolbar
                Divider()
            }
            HStack(spacing: 0) {
                if model.configuration.showsActivityBar {
                    activityBar
                    Divider()
                }
                if model.isNavigatorVisible {
                    navigator
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    Divider()
                }
                WorkbenchEditorArea(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isInspectorVisible {
                    Divider()
                    inspector
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
                }
            }
            if model.isUtilityVisible {
                Divider()
                utilityArea
                    .frame(minHeight: 120, idealHeight: 160)
            }
            if model.configuration.showsStatusBar {
                Divider()
                statusBar
            }
        }
        .sheet(isPresented: $model.isCommandPalettePresented) {
            if let context = model.makeCommandContext() {
                CommandPaletteView(
                    model: model.commandPalette,
                    dispatcher: model.commandDispatcher,
                    context: context,
                    onDismiss: { model.isCommandPalettePresented = false }
                )
                .padding()
            } else {
                VStack(spacing: 12) {
                    Text("No active editor")
                        .font(.headline)
                    Text("Open a text file to run editor commands.")
                        .foregroundStyle(.secondary)
                    Button("Close") { model.isCommandPalettePresented = false }
                }
                .padding(24)
            }
        }
        .sheet(isPresented: $model.isOpenQuicklyPresented) {
            OpenQuicklyView(
                model: model.openQuickly,
                onSelect: { model.openURI($0, preview: true) },
                onDismiss: { model.isOpenQuicklyPresented = false }
            )
            .padding()
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                model.isNavigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Navigator")

            Button {
                model.presentOpenQuickly()
            } label: {
                Label("Open Quickly", systemImage: "magnifyingglass")
            }

            Button {
                model.presentCommandPalette()
            } label: {
                Label("Commands", systemImage: "command")
            }

            Spacer()

            Button {
                _ = model.workspace.splitActivePane(axis: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split Right")

            Button {
                _ = model.workspace.splitActivePane(axis: .vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split Down")

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle Inspector")

            Button {
                model.isUtilityVisible.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .help("Toggle Utility Area")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var activityBar: some View {
        VStack(spacing: 12) {
            Button {
                model.isNavigatorVisible.toggle()
            } label: {
                Image(systemName: "folder")
            }
            Button {
                model.presentOpenQuickly()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(8)
        .frame(width: 40)
        .background(.bar)
    }

    private var navigator: some View {
        let contribs = model.contributionRegistry.contributions(for: .navigator)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        return Group {
            if let first = contribs.first {
                first.makeBody(context: ctx)
            } else {
                ContentUnavailableView("No Navigator", systemImage: "sidebar.left")
            }
        }
    }

    private var inspector: some View {
        let contribs = model.contributionRegistry.contributions(for: .inspector)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        return Group {
            if contribs.isEmpty {
                ContentUnavailableView(
                    "Inspector",
                    systemImage: "sidebar.right",
                    description: Text("No inspector contributions registered.")
                )
            } else {
                VStack(alignment: .leading) {
                    ForEach(contribs, id: \.id) { c in
                        c.makeBody(context: ctx)
                    }
                }
            }
        }
    }

    private var utilityArea: some View {
        VStack(spacing: 0) {
            Picker("Utility", selection: $model.utilitySelectedTab) {
                ForEach(UtilityAreaTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue.capitalized).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()
            let contribs = model.contributionRegistry.contributions(for: .utility)
            if contribs.isEmpty {
                ContentUnavailableView(
                    model.utilitySelectedTab.rawValue.capitalized,
                    systemImage: "terminal",
                    description: Text("Utility contributions (problems, terminal, …) register here.")
                )
            } else {
                let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
                ForEach(contribs, id: \.id) { c in
                    c.makeBody(context: ctx)
                }
            }
        }
        .background(.bar)
    }

    private var statusBar: some View {
        let contribs = model.contributionRegistry.contributions(for: .statusBar)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        return Group {
            if let first = contribs.first {
                first.makeBody(context: ctx)
            } else {
                EmptyView()
            }
        }
    }
}
