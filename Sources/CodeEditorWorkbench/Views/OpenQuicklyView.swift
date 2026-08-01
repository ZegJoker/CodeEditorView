import CodeEditorDocuments
import SwiftUI

/// Centered HUD for Open Quickly (Xcode-like floating panel, not a modal sheet).
public struct OpenQuicklyView: View {
    @Bindable var model: OpenQuicklyModel
    var onSelect: (DocumentURI) -> Void
    var onDismiss: () -> Void

    @FocusState private var queryFocused: Bool

    public init(
        model: OpenQuicklyModel,
        onSelect: @escaping (DocumentURI) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open Quickly", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                    .onSubmit { confirmSelection() }
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Text("\(model.results.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.results.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Type to filter files" : "No Matching Files",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "Search by file name or path."
                            : "Try a shorter or fuzzy query (e.g. “wsv” for WorkspaceView)."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.selectIndex(index)
                            confirmSelection()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 13))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(index == model.selectedIndex ? 0.16 : 0))
                                .padding(.horizontal, 4)
                        )
                        .id(index)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 380)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            queryFocused = true
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirmSelection()
            return .handled
        }
    }

    private func confirmSelection() {
        guard let item = model.selectedItem else { return }
        onSelect(item.uri)
        onDismiss()
    }
}

/// Dimmed full-window backdrop hosting the Open Quickly HUD.
struct OpenQuicklyOverlay: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    model.isOpenQuicklyPresented = false
                }

            OpenQuicklyView(
                model: model.openQuickly,
                onSelect: { model.openURI($0, preview: true) },
                onDismiss: { model.isOpenQuicklyPresented = false }
            )
            .offset(y: -36)
            .transition(
                .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
