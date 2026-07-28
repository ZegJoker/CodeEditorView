import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Compact find / replace panel (CESE-inspired, functional parity).
public struct FindPanelView: View {
    @Bindable var bridge: FindPanelBridge
    @FocusState private var focus: Field?

    private enum Field {
        case find
        case replace
    }

    public init(bridge: FindPanelBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(spacing: 4) {
            findRow
            if bridge.mode == .replace {
                replaceRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: bridge.panelHeight)
        .background(.bar)
        .onChange(of: focus) { _, newValue in
            // Do not call setFocused(false) here in a way that re-triggers panel focus.
            // AppKit first-responder transfer is owned by EditorChromeView; we only mirror
            // "panel has a focused field" for emphasis visibility.
            if newValue != nil {
                bridge.setFocused(true)
            }
        }
        .onChange(of: bridge.fieldFocusToken) { _, _ in
            // Mirror intended focus target for SwiftUI focus rings; AppKit steals key focus.
            let target: Field = bridge.fieldFocusTarget == .replace ? .replace : .find
            DispatchQueue.main.async {
                self.focus = target
            }
        }
    }

    private var findRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: modeBinding) {
                ForEach(FindPanelMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            TextField("Find", text: findTextBinding)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .find)
                .onSubmit { bridge.findNext() }

            Picker("", selection: methodBinding) {
                ForEach(FindMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            Toggle(isOn: matchCaseBinding) {
                Image(systemName: "textformat")
            }
            .toggleStyle(.button)
            .help("Match Case")

            Toggle(isOn: wrapAroundBinding) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .help("Wrap Around")

            Text(matchLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Button(action: { bridge.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Find Previous")

            Button(action: { bridge.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Find Next")

            Button(action: { bridge.dismiss() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 90)
            TextField("Replace", text: replaceTextBinding)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .replace)
                .onSubmit { bridge.replace() }
            Button("Replace") { bridge.replace() }
                .disabled(bridge.matchCount == 0)
            Button("All") { bridge.replaceAll() }
                .disabled(bridge.matchCount == 0)
            Spacer(minLength: 0)
        }
    }

    private var matchLabel: String {
        if bridge.findText.isEmpty {
            return ""
        }
        if bridge.matchCount == 0 {
            return "No matches"
        }
        if let current = bridge.currentMatchIndex {
            return "\(current + 1)/\(bridge.matchCount)"
        }
        return "\(bridge.matchCount)"
    }

    private var findTextBinding: Binding<String> {
        Binding(
            get: { bridge.findText },
            set: { bridge.setFindText($0) }
        )
    }

    private var replaceTextBinding: Binding<String> {
        Binding(
            get: { bridge.replaceText },
            set: { bridge.setReplaceText($0) }
        )
    }

    private var modeBinding: Binding<FindPanelMode> {
        Binding(
            get: { bridge.mode },
            set: { bridge.setMode($0) }
        )
    }

    private var methodBinding: Binding<FindMethod> {
        Binding(
            get: { bridge.method },
            set: { bridge.setMethod($0) }
        )
    }

    private var matchCaseBinding: Binding<Bool> {
        Binding(
            get: { bridge.matchCase },
            set: { bridge.setMatchCase($0) }
        )
    }

    private var wrapAroundBinding: Binding<Bool> {
        Binding(
            get: { bridge.wrapAround },
            set: { bridge.setWrapAround($0) }
        )
    }
}
