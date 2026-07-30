import SwiftUI
import CodeEditorDocuments

public struct OpenQuicklyView: View {
    @Bindable var model: OpenQuicklyModel
    var onSelect: (DocumentURI) -> Void
    var onDismiss: () -> Void

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
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open file…", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let first = model.results.first {
                            onSelect(first.uri)
                            onDismiss()
                        }
                    }
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            Divider()
            List(model.results) { item in
                Button {
                    onSelect(item.uri)
                    onDismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
