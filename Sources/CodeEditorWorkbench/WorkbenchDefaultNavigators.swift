import SwiftUI

/// Built-in navigator contributions with real list/empty models (Phase 10 E1 / E14).
@MainActor
enum WorkbenchDefaultNavigatorContributions {
    static var all: [any WorkbenchContribution] {
        [
            SymbolsNavigatorContribution(),
            SearchNavigatorContribution(),
            IssuesNavigatorContribution(),
            TestsNavigatorContribution(),
            DebugNavigatorContribution(),
            SCMNavigatorContribution(),
            BreakpointsNavigatorContribution(),
        ]
    }
}

// MARK: - Shared list chrome

@MainActor
struct WorkbenchNavigatorListChrome<Content: View>: View {
    let title: String
    let systemImage: String
    let emptyMessage: String
    let isEmpty: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
            }
            .padding(8)
            Divider()
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Symbols

@MainActor
final class SymbolsNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.symbols.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 20
    let title = "Symbols"
    let systemImage = "a.circle"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(SymbolsNavigatorView(model: context.model))
    }
}

@MainActor
struct SymbolsNavigatorView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        WorkbenchNavigatorListChrome(
            title: "Symbols",
            systemImage: "a.circle",
            emptyMessage: "No symbols indexed yet.",
            isEmpty: model.symbols.filtered.isEmpty
        ) {
            List(model.symbols.filtered) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.medium))
                    Text("\(item.kind) · \(item.path):\(item.line + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.symbols")
    }
}

// MARK: - Search (built-in shell; host may replace with richer find)

@MainActor
final class SearchNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.search.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 30
    let title = "Search"
    let systemImage = "magnifyingglass"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(SearchNavigatorPlaceholderView(model: context.model))
    }
}

@MainActor
struct SearchNavigatorPlaceholderView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        WorkbenchNavigatorListChrome(
            title: "Search",
            systemImage: "magnifyingglass",
            emptyMessage: "Run Find in Files from the host or command palette.",
            isEmpty: true
        ) {
            EmptyView()
        }
        .accessibilityIdentifier("workbench.navigator.search")
    }
}

// MARK: - Issues

@MainActor
final class IssuesNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.issues.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 40
    let title = "Issues"
    let systemImage = "exclamationmark.triangle"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(IssuesNavigatorView(model: context.model))
    }
}

@MainActor
struct IssuesNavigatorView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        let items = model.problemsBridge.problems
        WorkbenchNavigatorListChrome(
            title: "Issues",
            systemImage: "exclamationmark.triangle",
            emptyMessage: "No issues. Build or analyze to populate diagnostics.",
            isEmpty: items.isEmpty
        ) {
            List(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message).font(.body)
                    Text("\(item.path):\(item.line + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.issues")
    }
}

// MARK: - Tests

@MainActor
final class TestsNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.tests.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 50
    let title = "Tests"
    let systemImage = "checkmark.diamond"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(TestsNavigatorView(model: context.model))
    }
}

@MainActor
struct TestsNavigatorView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        WorkbenchNavigatorListChrome(
            title: "Tests",
            systemImage: "checkmark.diamond",
            emptyMessage: "No tests discovered. Run the test scheme to populate results.",
            isEmpty: model.tests.tests.isEmpty
        ) {
            List(model.tests.tests) { t in
                HStack {
                    Text(t.name)
                    Spacer()
                    Text(t.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.tests")
    }
}

// MARK: - Debug

@MainActor
final class DebugNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.debug.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 60
    let title = "Debug"
    let systemImage = "ladybug"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(DebugNavigatorView(model: context.model))
    }
}

@MainActor
struct DebugNavigatorView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        WorkbenchNavigatorListChrome(
            title: "Debug",
            systemImage: "ladybug",
            emptyMessage: "No debug sessions. Start debugging to see sessions here.",
            isEmpty: model.debugSessions.sessions.isEmpty
        ) {
            List(model.debugSessions.sessions) { s in
                HStack {
                    Text(s.name)
                    Spacer()
                    Text(s.state).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.debug")
    }
}

// MARK: - SCM

@MainActor
final class SCMNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.scm.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 70
    let title = "Source Control"
    let systemImage = "arrow.triangle.branch"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(SCMNavigatorShellView(model: context.model))
    }
}

@MainActor
struct SCMNavigatorShellView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        let statuses = model.scmModel.statuses
        WorkbenchNavigatorListChrome(
            title: "Source Control",
            systemImage: "arrow.triangle.branch",
            emptyMessage: model.scmModel.errorMessage
                ?? "Working tree clean, or refresh SCM from the host.",
            isEmpty: statuses.isEmpty
        ) {
            List(statuses, id: \.path) { s in
                Text(s.path)
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.scm")
    }
}

// MARK: - Breakpoints

@MainActor
final class BreakpointsNavigatorContribution: WorkbenchContribution {
    let id = WorkbenchNavigatorID.breakpoints.rawValue
    let slot: WorkbenchSlot = .navigator
    let priority = 80
    let title = "Breakpoints"
    let systemImage = "arrowtriangle.right.circle"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(BreakpointsNavigatorView(model: context.model))
    }
}

@MainActor
struct BreakpointsNavigatorView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        WorkbenchNavigatorListChrome(
            title: "Breakpoints",
            systemImage: "arrowtriangle.right.circle",
            emptyMessage: "No breakpoints. Click the gutter or add one from the debug session.",
            isEmpty: model.breakpoints.breakpoints.isEmpty
        ) {
            List(model.breakpoints.breakpoints) { bp in
                HStack {
                    Image(systemName: bp.enabled ? "circle.fill" : "circle")
                        .foregroundStyle(bp.enabled ? .red : .secondary)
                    Text("\(bp.path):\(bp.line)")
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("workbench.navigator.breakpoints")
    }
}
