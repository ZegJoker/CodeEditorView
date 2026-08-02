import CodeEditorCommands
import CodeEditorView
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Top-level SwiftUI workbench shell with Xcode-like chrome.
public struct WorkbenchView: View {
    @Bindable public var model: WorkbenchModel

    public init(model: WorkbenchModel) {
        self.model = model
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    public var body: some View {
        let _ = model.contributionRegistry.revision
        let _ = model.toolingSurfaces.revision
        VStack(spacing: 0) {
            if !model.visibleToolingFailures().isEmpty {
                toolingFailureBanner
            }
            if model.configuration.showsToolbar {
                toolbar
                    .accessibilityIdentifier(WorkbenchAccessibilityID.toolbar)
                    .accessibilitySortPriority(Double(WorkbenchFocusOrder.toolbar))
                    .transition(reduceMotion ? .opacity : .opacity)
            }

            // Xcode layout: utility/debug area sits under the *editor column* only,
            // not under the project navigator / activity bar.
            HStack(spacing: 0) {
                if model.configuration.showsActivityBar {
                    activityBar
                        .accessibilityIdentifier(WorkbenchAccessibilityID.activityBar)
                        .accessibilitySortPriority(Double(WorkbenchFocusOrder.activityBar))
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
                if model.isNavigatorVisible {
                    navigatorChrome
                        .accessibilityIdentifier(WorkbenchAccessibilityID.navigator)
                        .accessibilityLabel(WorkbenchL10n.navigator)
                        .accessibilitySortPriority(Double(WorkbenchFocusOrder.navigator))
                        .transition(reduceMotion ? .opacity : WorkbenchMotion.navigatorInsert)
                }

                editorColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(WorkbenchAccessibilityID.editor)
                    .accessibilityLabel(WorkbenchL10n.editor)
                    .accessibilitySortPriority(Double(WorkbenchFocusOrder.editor))

                if model.isInspectorVisible {
                    inspectorChrome
                        .accessibilityIdentifier(WorkbenchAccessibilityID.inspector)
                        .accessibilityLabel(WorkbenchL10n.inspector)
                        .accessibilitySortPriority(Double(WorkbenchFocusOrder.inspector))
                        .transition(reduceMotion ? .opacity : WorkbenchMotion.inspectorInsert)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : WorkbenchMotion.pane, value: model.isNavigatorVisible)
            .animation(reduceMotion ? nil : WorkbenchMotion.pane, value: model.isInspectorVisible)
            .animation(reduceMotion ? nil : WorkbenchMotion.pane, value: model.isUtilityVisible)

            if model.configuration.showsStatusBar {
                statusBar
                    .accessibilityIdentifier(WorkbenchAccessibilityID.statusBar)
                    .accessibilitySortPriority(Double(WorkbenchFocusOrder.statusBar))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackground)
        .environment(\.layoutDirection, layoutDirection)
        .accessibilityIdentifier(WorkbenchAccessibilityID.root)
        .onAppear {
            model.ensureActiveNavigator()
            model.ensureActiveUtility()
            model.enterForeground()
        }
        .onChange(of: model.contributionRegistry.revision) { _, _ in
            model.ensureActiveNavigator()
            model.ensureActiveUtility()
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
                .accessibilityIdentifier(WorkbenchAccessibilityID.commandPalette)
            } else {
                VStack(spacing: 12) {
                    Text(WorkbenchL10n.noActiveEditor)
                        .font(.headline)
                    Text(WorkbenchL10n.openFileHint)
                        .foregroundStyle(.secondary)
                    Button("Close") { model.isCommandPalettePresented = false }
                }
                .padding(24)
                .accessibilityIdentifier(WorkbenchAccessibilityID.commandPalette)
            }
        }
        .overlay {
            if model.isOpenQuicklyPresented {
                OpenQuicklyOverlay(model: model)
                    .transition(.opacity)
                    .zIndex(100)
                    .accessibilityIdentifier(WorkbenchAccessibilityID.openQuickly)
            }
        }
        .animation(reduceMotion ? nil : WorkbenchMotion.chrome, value: model.isOpenQuicklyPresented)
    }

    private var toolingFailureBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.visibleToolingFailures()), id: \.id) { surface in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(surface.title)
                            .font(.subheadline.weight(.semibold))
                        if let message = surface.status.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if surface.canRetry {
                        Button(WorkbenchL10n.retry) {
                            model.retryTooling(id: surface.id)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button(WorkbenchL10n.dismiss) {
                        model.dismissToolingBanner(id: surface.id)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15))
        .accessibilityIdentifier(WorkbenchAccessibilityID.toolingBanner)
        .accessibilityLabel(WorkbenchL10n.toolingFailed)
    }

    /// Editor + optional utility split (does not span navigator).
    private var editorColumn: some View {
        Group {
            if model.isUtilityVisible {
                #if os(macOS)
                    VSplitView {
                        WorkbenchEditorArea(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .animation(reduceMotion ? nil : WorkbenchMotion.content, value: model.workspace.revision)
                        utilityArea
                            .frame(minHeight: 100)
                            .accessibilityIdentifier(WorkbenchAccessibilityID.utility)
                            .accessibilityLabel(WorkbenchL10n.utility)
                    }
                #else
                    VStack(spacing: 0) {
                        WorkbenchEditorArea(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        utilityArea
                            .frame(height: model.utilityHeight)
                            .accessibilityIdentifier(WorkbenchAccessibilityID.utility)
                            .accessibilityLabel(WorkbenchL10n.utility)
                    }
                #endif
            } else {
                WorkbenchEditorArea(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(reduceMotion ? nil : WorkbenchMotion.content, value: model.workspace.revision)
            }
        }
    }

    // MARK: - Background

    private var windowBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemGroupedBackground)
        #endif
    }

    @ViewBuilder
    private var paneBackground: some View {
        #if os(macOS)
            if model.configuration.navigatorStyle == .floating {
                Rectangle().fill(.regularMaterial)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(WorkbenchMotion.pane) {
                    model.isNavigatorVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Navigator")

            Button {
                model.navigateBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .help("Go Back")
            .disabled(!model.canNavigateBack)

            Button {
                model.navigateForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .help("Go Forward")
            .disabled(!model.canNavigateForward)

            Button {
                model.presentOpenQuickly()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Open Quickly")

            Button {
                model.presentCommandPalette()
            } label: {
                Image(systemName: "command")
            }
            .help("Command Palette")

            Spacer()

            Button {
                withAnimation(WorkbenchMotion.pane) {
                    _ = model.workspace.splitActivePane(axis: .horizontal)
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split Right")

            Button {
                withAnimation(WorkbenchMotion.pane) {
                    _ = model.workspace.splitActivePane(axis: .vertical)
                }
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split Down")

            Button {
                withAnimation(WorkbenchMotion.pane) {
                    model.isInspectorVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle Inspector")

            Button {
                withAnimation(WorkbenchMotion.pane) {
                    model.isUtilityVisible.toggle()
                }
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .help("Toggle Utility Area")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Activity bar

    private var activityBar: some View {
        let navigators = model.contributionRegistry.contributions(for: .navigator)
        return VStack(spacing: 4) {
            ForEach(navigators, id: \.id) { contrib in
                activityButton(
                    systemImage: contrib.systemImage,
                    selected: model.isNavigatorVisible && model.activeNavigatorID == contrib.id,
                    help: contrib.title
                ) {
                    withAnimation(WorkbenchMotion.pane) {
                        if model.activeNavigatorID == contrib.id, model.isNavigatorVisible {
                            model.isNavigatorVisible = false
                        } else {
                            model.selectNavigator(id: contrib.id)
                            model.isNavigatorVisible = true
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            activityButton(
                systemImage: "magnifyingglass",
                selected: false,
                help: "Open Quickly"
            ) {
                model.presentOpenQuickly()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 48)
        .background(.bar.opacity(0.55))
    }

    private func activityButton(
        systemImage: String,
        selected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.18 : 0))
                }
                .animation(WorkbenchMotion.chrome, value: selected)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Navigator

    private var navigatorChrome: some View {
        Group {
            if model.configuration.navigatorStyle == .floating {
                navigator
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    .frame(maxHeight: .infinity)
                    .background { paneBackground }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                    .padding(.trailing, 4)
            } else {
                navigator
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    .frame(maxHeight: .infinity)
                    .background { paneBackground }
                Divider()
            }
        }
    }

    private var navigator: some View {
        let contribs = model.contributionRegistry.contributions(for: .navigator)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        let active = contribs.first(where: { $0.id == model.activeNavigatorID }) ?? contribs.first
        return Group {
            if let active {
                model.contributionRegistry.makeBodyIsolated(id: active.id, context: ctx)
                    .id(active.id)
            } else {
                ContentUnavailableView("No Navigator", systemImage: "sidebar.left")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Inspector

    private var inspectorChrome: some View {
        Group {
            if model.configuration.navigatorStyle == .floating {
                inspector
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    .frame(maxHeight: .infinity)
                    .background { paneBackground }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
            } else {
                Divider()
                inspector
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    .frame(maxHeight: .infinity)
                    .background { paneBackground }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contribs, id: \.id) { c in
                        model.contributionRegistry.makeBodyIsolated(id: c.id, context: ctx)
                    }
                }
            }
        }
    }

    // MARK: - Utility

    private var utilityArea: some View {
        let contribs = model.contributionRegistry.contributions(for: .utility)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        let activeID = model.activeUtilityID
        let active = contribs.first(where: { $0.id == activeID }) ?? contribs.first

        return VStack(spacing: 0) {
            if !contribs.isEmpty {
                HStack(spacing: 0) {
                    ForEach(contribs, id: \.id) { c in
                        Button {
                            model.selectUtility(id: c.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: c.systemImage)
                                    .font(.caption)
                                Text(c.title)
                                    .font(.caption.weight(c.id == active?.id ? .semibold : .regular))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                if c.id == active?.id {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(c.title)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(WorkbenchMotion.pane) {
                            model.isUtilityVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("Hide Utility Area")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                Divider()
            }

            Group {
                if let active {
                    model.contributionRegistry.makeBodyIsolated(id: active.id, context: ctx)
                        .id(active.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(WorkbenchMotion.editorContent)
                } else {
                    ContentUnavailableView(
                        "Utility",
                        systemImage: "terminal",
                        description: Text("Register utility contributions (problems, terminal, output).")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(WorkbenchMotion.content, value: model.activeUtilityID)
        }
        .background(.bar)
        .frame(minHeight: 100)
    }

    // MARK: - Status

    private var statusBar: some View {
        let contribs = model.contributionRegistry.contributions(for: .statusBar)
        let ctx = WorkbenchContributionContext(workspace: model.workspace, model: model)
        // Single shared chrome so host status items (e.g. git branch) match the bar fill.
        return HStack(spacing: 0) {
            if contribs.isEmpty {
                EmptyView()
            } else {
                if let first = contribs.first {
                    model.contributionRegistry.makeBodyIsolated(id: first.id, context: ctx)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(contribs.dropFirst(), id: \.id) { c in
                    model.contributionRegistry.makeBodyIsolated(id: c.id, context: ctx)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
