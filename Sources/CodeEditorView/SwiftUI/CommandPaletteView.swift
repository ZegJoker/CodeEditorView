import CodeEditorCommands
import SwiftUI

/// Optional command-palette UI driven by ``CommandPaletteModel`` and a ``CommandDispatcher``.
public struct CommandPaletteView: View {
    @Bindable private var model: CommandPaletteModel
    private var dispatcher: CommandDispatcher
    private var context: CommandContext
    private var onDismiss: (() -> Void)?

    @State private var selection: CommandID?

    public init(
        model: CommandPaletteModel,
        dispatcher: CommandDispatcher,
        context: CommandContext,
        onDismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.dispatcher = dispatcher
        self.context = context
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let items = model.filteredCommands(from: dispatcher.commands, context: context)
        VStack(spacing: 0) {
            TextField("Run a command…", text: $model.query)
                .textFieldStyle(.plain)
                .padding(10)
            Divider()
            List(items, id: \.id.rawValue, selection: $selection) { command in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title)
                        Text(command.id.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let category = command.category {
                        Text(category.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    run(command.id)
                }
            }
            .listStyle(.plain)
            // Keyboard: Return runs the selected command (do not run on arrow-key selection change).
            .onKeyPress(.return) {
                if let selection {
                    run(selection)
                    return .handled
                }
                if let first = items.first {
                    run(first.id)
                    return .handled
                }
                return .ignored
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        .onChange(of: model.query) { _, _ in
            // Keep selection valid when filter shrinks.
            let ids = Set(model.filteredCommands(from: dispatcher.commands, context: context).map(\.id))
            if let selection, !ids.contains(selection) {
                self.selection = ids.first
            }
        }
    }

    private func run(_ id: CommandID) {
        try? dispatcher.execute(id, context: context)
        onDismiss?()
    }
}
