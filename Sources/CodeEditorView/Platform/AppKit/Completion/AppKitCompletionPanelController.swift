#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

/// Floating completion list anchored near the caret (CESE-style, no Combine).
@MainActor
final class AppKitCompletionPanelController {
    private weak var controller: EditorController?
    private weak var editorView: NSView?
    private var panel: NSPanel?
    private var hosting: NSHostingView<CompletionListView>?
    private var lastRevision: Int = -1

    func attach(controller: EditorController, editorView: NSView) {
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
        guard let controller else { return }
        let session = controller.completionSession
        guard session.isVisible, !session.items.isEmpty else {
            hide()
            return
        }
        lastRevision = session.revision
        let items = session.items.map { CompletionListItem(entry: $0) }
        let selected = session.selectedIndex
        let root = CompletionListView(
            items: items,
            selectedIndex: selected,
            onSelect: { [weak self, weak controller] index in
                controller?.selectCompletionIndex(index)
                self?.sync()
            },
            onApply: { [weak controller] index in
                controller?.selectCompletionIndex(index)
                controller?.applyCompletionSelection()
            }
        )
        ensurePanel()
        hosting?.rootView = root
        positionPanel()
        panel?.orderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
        lastRevision = -1
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: CompletionListView(
            items: [],
            selectedIndex: 0,
            onSelect: { _ in },
            onApply: { _ in }
        ))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let resigned = note.object as? NSWindow
            Task { @MainActor in
                guard let self, let editorWindow = self.editorView?.window else { return }
                if resigned === editorWindow {
                    self.controller?.hideCompletions()
                }
            }
        }
    }

    private func positionPanel() {
        guard let controller, let editorView, let panel, let window = editorView.window else { return }
        let width = max(1, editorView.bounds.width)
        guard let caret = controller.caretRect(containerWidth: width) else { return }
        let caretInWindow = editorView.convert(caret, to: nil)
        let caretOnScreen = window.convertToScreen(caretInWindow)

        let size = CGSize(width: 320, height: min(260, 36 + CGFloat(controller.completionSession.items.count) * 28))
        var origin = CGPoint(x: caretOnScreen.minX, y: caretOnScreen.minY - size.height - 4)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                // Place above caret
                origin.y = caretOnScreen.maxY + 4
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

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
    var onSelect: (Int) -> Void
    var onApply: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
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
                            .background(index == selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                onSelect(index)
                            }
                            .onTapGesture(count: 2) {
                                onApply(index)
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
