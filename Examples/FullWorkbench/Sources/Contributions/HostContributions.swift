import SwiftUI
import CodeEditorWorkbench
import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorSearch

// MARK: - Find navigator

@MainActor
final class FindNavigatorContribution: WorkbenchContribution {
    let id = "fullworkbench.navigator.find"
    let slot: WorkbenchSlot = .navigator
    let priority = 80
    let title = "Find"
    let systemImage = "magnifyingglass"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(FindNavigatorView(host: host, workbench: context.model))
    }
}

struct FindNavigatorView: View {
    @Bindable var host: HostServices
    var workbench: WorkbenchModel
    @FocusState private var focusedField: FindField?

    private enum FindField {
        case search
        case replace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(host.isReplaceMode ? "FIND AND REPLACE" : "FIND IN FILES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: $host.isReplaceMode) {
                    Text("Find").tag(false)
                    Text("Replace").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 6) {
                // Search — Enter runs find (no Find button on macOS).
                findTextFieldRow(
                    placeholder: host.searchIsRegex ? "Regular Expression" : "Search",
                    text: $host.searchPattern,
                    field: .search,
                    isPrimary: focusedField == .search || focusedField == nil
                ) {
                    findOptionButton(title: "Aa", help: "Case Sensitive", isOn: host.searchCaseSensitive) {
                        host.searchCaseSensitive.toggle()
                    }
                    findOptionButton(title: "ab", help: "Match Whole Word", isOn: host.searchWholeWord, underline: true) {
                        host.searchWholeWord.toggle()
                    }
                    findOptionButton(title: ".*", help: "Regular Expression", isOn: host.searchIsRegex, monospaced: true) {
                        host.searchIsRegex.toggle()
                    }
                }
                .onSubmit {
                    host.runSearch()
                }

                if host.isReplaceMode {
                    // Replace — Enter = replace next; trailing AB + replace-all.
                    HStack(spacing: 4) {
                        TextField("Replace", text: $host.replacePattern)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .replace)
                            .onSubmit {
                                host.replaceNextMatch()
                            }

                        findOptionButton(
                            title: "AB",
                            help: "Preserve Case",
                            isOn: host.searchPreserveCase
                        ) {
                            host.searchPreserveCase.toggle()
                        }

                        Button {
                            host.replaceAllMatches()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    host.searchMatches.isEmpty ? Color.secondary.opacity(0.4) : Color.secondary
                                )
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(host.searchMatches.isEmpty || host.isSearching)
                        .help("Replace All")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                focusedField == .replace ? Color.accentColor.opacity(0.85) : Color.clear,
                                lineWidth: 1.5
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    )
                }

                #if !os(macOS)
                HStack(spacing: 8) {
                    Button(host.isSearching ? "Searching…" : "Find") {
                        host.runSearch()
                    }
                    .disabled(host.isSearching || host.searchPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .font(.caption)
                #endif
            }
            .padding(8)

            if !host.searchStatus.isEmpty || !host.searchMatches.isEmpty {
                HStack(spacing: 4) {
                    if host.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(host.searchStatus.isEmpty ? " " : host.searchStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !host.searchMatches.isEmpty {
                        Text("–")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Open in Editor") {
                            host.openAllSearchMatchesInEditor()
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Divider().opacity(0.35)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(host.searchGroups) { group in
                        searchFileGroup(group)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func findTextFieldRow<Trailing: View>(
        placeholder: String,
        text: Binding<String>,
        field: FindField,
        isPrimary: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
            trailing()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isPrimary ? Color.accentColor.opacity(0.85) : Color.clear,
                    lineWidth: 1.5
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        )
    }

    @ViewBuilder
    private func searchFileGroup(_ group: SearchFileGroup) -> some View {
        let expanded = host.expandedSearchFiles.contains(group.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded {
                    host.expandedSearchFiles.remove(group.id)
                } else {
                    host.expandedSearchFiles.insert(group.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(group.fileName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(group.matches.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(group.matches) { match in
                    Button {
                        host.openSearchMatch(match)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            replaceAwarePreview(match)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 22)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Find: yellow highlight. Replace: red removed + green inserted (Xcode style).
    @ViewBuilder
    private func replaceAwarePreview(_ match: SearchMatch) -> some View {
        let preview = match.preview
        let pattern = host.searchPattern
        if host.isReplaceMode {
            let replacement = host.previewReplacement(for: match)
            if let range = matchRange(in: preview, pattern: pattern) {
                let before = String(preview[..<range.lowerBound])
                let matched = String(preview[range])
                let after = String(preview[range.upperBound...])
                replacePreviewAttributed(
                    before: before,
                    matched: matched,
                    replacement: replacement,
                    after: after
                )
            } else {
                Text(preview).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            highlightedPreview(preview, pattern: pattern)
        }
    }

    private func replacePreviewAttributed(
        before: String,
        matched: String,
        replacement: String,
        after: String
    ) -> Text {
        var result = AttributedString()
        var beforeAttr = AttributedString(before)
        beforeAttr.font = .caption2
        beforeAttr.foregroundColor = .secondary
        result += beforeAttr

        var red = AttributedString(matched)
        red.font = .caption2.weight(.semibold)
        red.foregroundColor = .white
        red.backgroundColor = Color.red.opacity(0.75)
        red.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .white)
        result += red

        var green = AttributedString(replacement)
        green.font = .caption2.weight(.semibold)
        green.foregroundColor = .white
        green.backgroundColor = Color.green.opacity(0.75)
        result += green

        var afterAttr = AttributedString(after)
        afterAttr.font = .caption2
        afterAttr.foregroundColor = .secondary
        result += afterAttr

        return Text(result)
    }

    private func matchRange(in preview: String, pattern: String) -> Range<String.Index>? {
        guard !pattern.isEmpty else { return nil }
        var options: String.CompareOptions = []
        if !host.searchCaseSensitive { options.insert(.caseInsensitive) }
        if host.searchIsRegex { options.insert(.regularExpression) }
        return preview.range(of: pattern, options: options)
    }

    private func findOptionButton(
        title: String,
        help: String,
        isOn: Bool,
        underline: Bool = false,
        monospaced: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(monospaced ? .system(size: 11, weight: .semibold, design: .monospaced) : .system(size: 11, weight: .semibold))
                .underline(underline && isOn)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(minWidth: 22, minHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func highlightedPreview(_ preview: String, pattern: String) -> Text {
        guard !pattern.isEmpty, let range = matchRange(in: preview, pattern: pattern) else {
            return Text(preview).font(.caption2).foregroundStyle(.secondary)
        }
        var attributed = AttributedString(preview)
        if let attrRange = Range(range, in: attributed) {
            attributed[attrRange].foregroundColor = .primary
            attributed[attrRange].backgroundColor = Color.yellow.opacity(0.35)
            attributed[attrRange].font = .caption2.weight(.semibold)
        }
        return Text(attributed).font(.caption2).foregroundStyle(.secondary)
    }
}

// MARK: - SCM navigator

@MainActor
final class SCMNavigatorContribution: WorkbenchContribution {
    let id = "fullworkbench.navigator.scm"
    let slot: WorkbenchSlot = .navigator
    let priority = 70
    let title = "Source Control"
    let systemImage = "arrow.triangle.branch"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(SCMNavigatorView(host: host))
    }
}

struct SCMNavigatorView: View {
    @Bindable var host: HostServices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SOURCE CONTROL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await host.refreshSCM() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(8)
            Divider().opacity(0.35)
            if let branch = host.scmBranch {
                Text("branch: \(branch)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if let err = host.scmError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            List(host.scmStatuses) { status in
                Button {
                    host.openSCMFile(status)
                } label: {
                    HStack {
                        Text(statusBadge(status.state))
                            .font(.caption.monospaced())
                            .foregroundStyle(statusColor(status.state))
                            .frame(width: 16)
                        Text(status.path)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if status.staged {
                            Text("S").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
        .task {
            await host.refreshSCM()
        }
    }

    private func statusBadge(_ state: SCMState) -> String {
        switch state {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .untracked: return "?"
        case .conflicted: return "C"
        case .renamed: return "R"
        case .copied: return "C"
        case .ignored: return "I"
        case .submodule: return "S"
        case .unmodified: return " "
        }
    }

    private func statusColor(_ state: SCMState) -> Color {
        switch state {
        case .modified, .renamed, .copied: return .orange
        case .added: return .green
        case .deleted, .conflicted: return .red
        case .untracked, .submodule: return .secondary
        default: return .primary
        }
    }
}

// MARK: - Utilities

@MainActor
final class OutputUtilityContribution: WorkbenchContribution {
    let id = "workbench.utility.output"
    let slot: WorkbenchSlot = .utility
    let priority = 10
    let title = "Output"
    let systemImage = "list.bullet.rectangle"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(OutputPanelView(host: host))
    }
}

struct OutputPanelView: View {
    @Bindable var host: HostServices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Run Sample Task") {
                    Task { await host.runDemoTask() }
                }
                .font(.caption)
                Button("Clear") {
                    host.outputLines.removeAll()
                }
                .font(.caption)
            }
            .padding(6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(host.outputLines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.isError ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
    }
}

@MainActor
final class ProblemsUtilityContribution: WorkbenchContribution {
    let id = "workbench.utility.problems"
    let slot: WorkbenchSlot = .utility
    let priority = 20
    let title = "Problems"
    let systemImage = "exclamationmark.triangle"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(ProblemsPanelView(host: host, workbench: context.model))
    }
}

struct ProblemsPanelView: View {
    @Bindable var host: HostServices
    var workbench: WorkbenchModel

    var body: some View {
        Group {
            if host.problems.isEmpty {
                ContentUnavailableView(
                    "No Problems",
                    systemImage: "checkmark.circle",
                    description: Text("Run “Sample Diagnostics” from Output to generate a sample warning.")
                )
            } else {
                List(host.problems) { problem in
                    Button {
                        if let uri = problem.uri {
                            workbench.openURI(uri, preview: true)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: problem.severity == "error" ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(problem.severity == "error" ? .red : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem.message)
                                    .font(.caption)
                                Text((problem.path as NSString).lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }
}

@MainActor
final class TerminalUtilityContribution: WorkbenchContribution {
    let id = "workbench.utility.terminal"
    let slot: WorkbenchSlot = .utility
    let priority = 30
    let title = "Terminal"
    let systemImage = "terminal"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(TerminalPanelView(host: host))
    }
}

struct TerminalPanelView: View {
    @Bindable var host: HostServices

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal")
                    .font(.caption.weight(.semibold))
                Text(host.terminalStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restart") {
                    Task {
                        if let id = host.terminalSessionID {
                            await host.terminal.close(id)
                            host.terminalSessionID = nil
                            host.terminalOutput = ""
                        }
                        await host.ensureTerminalSession()
                    }
                }
                .font(.caption)
            }
            .padding(6)
            Divider()
            ScrollView {
                Text(host.terminalOutput.isEmpty ? " " : host.terminalOutput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            Divider()
            HStack {
                TextField("Command", text: $host.terminalInput)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { host.sendTerminalInput() }
                Button("Send") { host.sendTerminalInput() }
                    .font(.caption)
            }
            .padding(6)
        }
        .task {
            await host.ensureTerminalSession()
        }
    }
}

// MARK: - Status branch

@MainActor
final class SCMStatusContribution: WorkbenchContribution {
    let id = "fullworkbench.status.scm"
    let slot: WorkbenchSlot = .statusBar
    let priority = 50
    let title = "SCM"
    let systemImage = "arrow.triangle.branch"
    let host: HostServices

    init(host: HostServices) { self.host = host }

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        // Transparent contribution — bar background comes from WorkbenchView.statusBar.
        AnyView(
            HStack(spacing: 6) {
                if let branch = host.scmBranch {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch)
                } else if host.scmError != nil {
                    Text("no git")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        )
    }
}
