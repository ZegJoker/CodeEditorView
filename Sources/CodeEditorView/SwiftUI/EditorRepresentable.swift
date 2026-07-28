import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var configuration: EditorConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = EditorController(text: text, configuration: configuration)
        context.coordinator.controller = controller

        let editor = AppKitEditorView(controller: controller)
        editor.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.text.wrappedValue = newText
        }
        editor.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.selection.wrappedValue = range
        }
        context.coordinator.editorView = editor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = editor
        editor.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        controller.configuration = configuration
        if controller.text != text {
            controller.text = text
        }
        if controller.selectedRange != selection {
            controller.setSelectedRange(selection)
        }
        context.coordinator.editorView?.relayout()
    }

    @MainActor
    final class Coordinator {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var controller: EditorController?
        var editorView: AppKitEditorView?

        init(text: Binding<String>, selection: Binding<NSRange>) {
            self.text = text
            self.selection = selection
        }
    }
}

#elseif canImport(UIKit)
import UIKit

struct EditorRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var configuration: EditorConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let controller = EditorController(text: text, configuration: configuration)
        context.coordinator.controller = controller

        let editor = UIKitEditorView(controller: controller)
        editor.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.text.wrappedValue = newText
        }
        editor.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.selection.wrappedValue = range
        }
        context.coordinator.editorView = editor

        let scroll = UIScrollView()
        scroll.addSubview(editor)
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            editor.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        controller.configuration = configuration
        if controller.text != text {
            controller.text = text
        }
        if controller.selectedRange != selection {
            controller.setSelectedRange(selection)
        }
        context.coordinator.editorView?.relayout()
        if let editor = context.coordinator.editorView {
            scrollView.contentSize = CGSize(
                width: scrollView.bounds.width,
                height: max(controller.contentSize.height, scrollView.bounds.height)
            )
            editor.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        }
    }

    @MainActor
    final class Coordinator {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var controller: EditorController?
        var editorView: UIKitEditorView?

        init(text: Binding<String>, selection: Binding<NSRange>) {
            self.text = text
            self.selection = selection
        }
    }
}
#endif
