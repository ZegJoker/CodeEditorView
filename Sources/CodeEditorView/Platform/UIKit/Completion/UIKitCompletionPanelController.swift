#if canImport(UIKit) && !os(macOS)
    import UIKit
    import SwiftUI

    /// Floating completion list anchored near the caret (UIKit parity with AppKit).
    @MainActor
    final class UIKitCompletionPanelController {
        private weak var controller: EditorController?
        private weak var editorView: UIView?
        private var container: UIView?
        private var hosting: UIHostingController<CompletionListView>?
        private var lastRevision: Int = -1

        func attach(controller: EditorController, editorView: UIView) {
            self.controller = controller
            self.editorView = editorView
            controller.onCompletionSessionChange = { [weak self] in
                self?.sync()
            }
        }

        func detach() {
            hide()
            controller?.onCompletionSessionChange = nil
            controller = nil
            editorView = nil
        }

        func sync() {
            guard let controller, let editorView else { return }
            let session = controller.completionSession
            guard session.isVisible, !session.items.isEmpty else {
                hide()
                return
            }
            lastRevision = session.revision
            let items = session.items.map { CompletionListItem(entry: $0) }
            let selected = session.selectedIndex
            let applyOnSelect = controller.isJumpLinkPopoverVisible
            let root = CompletionListView(
                items: items,
                selectedIndex: selected,
                applyOnSelect: applyOnSelect,
                onSelect: { [weak self, weak controller] index in
                    controller?.selectCompletionIndex(index)
                    self?.sync()
                },
                onApply: { [weak self, weak controller] index in
                    guard let controller else { return }
                    controller.completionSession.selectIndex(index)
                    if let item = controller.completionSession.selectedItem as? JumpToDefinitionLink {
                        controller.jumpToDefinitionModel.open(link: item)
                    } else {
                        controller.applyCompletionSelection()
                    }
                    self?.sync()
                }
            )
            ensureContainer(in: editorView)
            hosting?.rootView = root
            positionPanel(in: editorView, controller: controller)
            container?.isHidden = false
        }

        private func hide() {
            container?.isHidden = true
            lastRevision = -1
        }

        private func ensureContainer(in editorView: UIView) {
            if container != nil { return }
            let hostView = editorView.window ?? editorView.superview ?? editorView

            let hosting = UIHostingController(
                rootView: CompletionListView(
                    items: [],
                    selectedIndex: 0,
                    applyOnSelect: false,
                    onSelect: { _ in },
                    onApply: { _ in }
                ))
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            hosting.view.layer.cornerRadius = 8
            hosting.view.layer.masksToBounds = true
            hosting.view.layer.shadowOpacity = 0.2
            hosting.view.layer.shadowRadius = 8

            // Attach to the nearest window root so the panel floats over the editor.
            let parent = editorView.window?.rootViewController?.view ?? hostView
            parent.addSubview(hosting.view)
            self.hosting = hosting
            self.container = hosting.view
        }

        private func positionPanel(in editorView: UIView, controller: EditorController) {
            guard let container, let parent = container.superview else { return }
            let width = max(1, editorView.bounds.width)
            // Prefer session anchor (jump-to-definition press site) over the live caret.
            guard let caret = controller.completionAnchorRect(containerWidth: width) else { return }
            let caretInParent = editorView.convert(caret, to: parent)

            let panelWidth: CGFloat = min(320, parent.bounds.width - 16)
            let rowCount = CGFloat(max(1, controller.completionSession.items.count))
            let panelHeight: CGFloat = min(260, 36 + rowCount * 28)

            var origin = CGPoint(
                x: caretInParent.minX,
                y: caretInParent.maxY + 4
            )
            if origin.y + panelHeight > parent.bounds.maxY - 8 {
                origin.y = caretInParent.minY - panelHeight - 4
            }
            origin.x = min(max(8, origin.x), parent.bounds.maxX - panelWidth - 8)
            origin.y = min(max(8, origin.y), parent.bounds.maxY - panelHeight - 8)

            container.frame = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))
        }
    }

    // Shared list UI types (duplicated for UIKit module visibility without cross-platform import issues).
    struct CompletionListItem: Identifiable {
        let id = UUID()
        let label: String
        let detail: String?
        let systemImage: String
        let deprecated: Bool

        init(entry: any CodeSuggestionEntry) {
            label = entry.label
            detail = entry.detail
            systemImage = entry.systemImage
            deprecated = entry.deprecated
        }
    }

    struct CompletionListView: View {
        var items: [CompletionListItem]
        var selectedIndex: Int
        /// When true (jump-to-definition), a single click applies the row immediately.
        var applyOnSelect: Bool = false
        var onSelect: (Int) -> Void
        var onApply: (Int) -> Void

        var body: some View {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                Button {
                                    if applyOnSelect {
                                        onApply(index)
                                    } else {
                                        onSelect(index)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: item.systemImage)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(item.label)
                                            .font(.system(.body, design: .monospaced))
                                            .strikethrough(item.deprecated)
                                        if let detail = item.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                                .id(index)
                                .onTapGesture(count: 2) {
                                    if !applyOnSelect {
                                        onApply(index)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(2)
        }
    }
#endif
