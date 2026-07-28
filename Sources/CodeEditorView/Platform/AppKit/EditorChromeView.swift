#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

/// Root container: optional find panel stacked above the editor scroll view.
final class EditorChromeView: NSView {
    let scrollView: NSScrollView
    let editorView: AppKitEditorView
    let controller: EditorController
    private let findBridge = FindPanelBridge()
    private var findHosting: NSHostingView<FindPanelView>?
    private var findHeightConstraint: NSLayoutConstraint?
    private var pendingFocusWorkItems: [DispatchWorkItem] = []
    /// Last `fieldFocusToken` we scheduled AppKit focus for (only act on new requests).
    private var lastScheduledFocusToken: Int = -1
    /// Bumped to invalidate deferred focus work (user clicked the document).
    private var focusGeneration: Int = 0
    private var wasShowingFindPanel = false
    private var lastPanelMode: FindPanelMode?

    init(controller: EditorController, editorView: AppKitEditorView, wrapLines: Bool) {
        self.controller = controller
        self.editorView = editorView
        self.scrollView = NSScrollView()
        super.init(frame: .zero)

        wantsLayer = true
        findBridge.controller = controller

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = editorView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        editorView.autoresizingMask = wrapLines ? [.width] : []

        // When the user clicks the document, cancel any deferred panel focus steal.
        editorView.onWillBecomeFirstResponder = { [weak self] in
            self?.cancelPendingPanelFieldFocus()
        }

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
        ])

        controller.onFindSessionChange = { [weak self] in
            guard let self else { return }
            let token = self.controller.findSession.fieldFocusToken
            let shouldFocus = token != self.lastScheduledFocusToken
            self.syncFindPanel()
            self.editorView.onSelectionChange?(self.controller.selectedRange)
            self.editorView.relayout()
            // Only force field focus for *new* focus requests (⌘F / ⌘R), never on every
            // session notify (e.g. panel losing focus when the user clicks the document).
            if shouldFocus, self.controller.findSession.isShowing {
                self.schedulePanelFieldFocus()
            }
        }
        syncFindPanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncFindPanel() {
        findBridge.syncFromController()
        let showing = controller.findSession.isShowing
        let mode = controller.findSession.mode
        if showing {
            installFindPanelIfNeeded()
            findHeightConstraint?.constant = controller.findSession.panelHeight
            findHosting?.isHidden = false
            // Rebuild the hosted view only when the panel structure changes — not on every
            // match/focus notify (rebuilding re-runs onAppear and can re-steal key focus).
            let structureChanged = !wasShowingFindPanel || lastPanelMode != mode
            if structureChanged {
                findHosting?.rootView = FindPanelView(bridge: findBridge)
                layoutSubtreeIfNeeded()
            }
        } else {
            findHeightConstraint?.constant = 0
            findHosting?.isHidden = true
            cancelPendingPanelFieldFocus()
        }
        wasShowingFindPanel = showing
        lastPanelMode = mode
        needsLayout = true
    }

    private func installFindPanelIfNeeded() {
        if findHosting != nil { return }
        let hosting = NSHostingView(rootView: FindPanelView(bridge: findBridge))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        let height = hosting.heightAnchor.constraint(equalToConstant: controller.findSession.panelHeight)
        findHeightConstraint = height
        // Re-pin scroll below panel.
        for c in constraints where (c.firstItem as? NSView) == scrollView && c.firstAttribute == .top {
            removeConstraint(c)
        }
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            height,
            scrollView.topAnchor.constraint(equalTo: hosting.bottomAnchor),
        ])
        findHosting = hosting
    }

    func updateWrapLines(_ wrap: Bool) {
        scrollView.hasHorizontalScroller = !wrap
        scrollView.horizontalScrollElasticity = wrap ? .none : .allowed
        editorView.autoresizingMask = wrap ? [.width] : []
    }

    // MARK: - AppKit field focus

    /// Cancels deferred panel focus (call when the user activates the document).
    func cancelPendingPanelFieldFocus() {
        focusGeneration &+= 1
        for item in pendingFocusWorkItems {
            item.cancel()
        }
        pendingFocusWorkItems.removeAll()
    }

    /// Focus the find/replace NSTextField after SwiftUI has built the panel.
    /// Only for new ``fieldFocusToken`` values (explicit ⌘F / ⌘R), never on unfocus notifies.
    private func schedulePanelFieldFocus() {
        guard controller.findSession.isShowing else { return }
        let token = controller.findSession.fieldFocusToken
        guard token != lastScheduledFocusToken else { return }
        lastScheduledFocusToken = token

        for item in pendingFocusWorkItems { item.cancel() }
        pendingFocusWorkItems.removeAll()
        focusGeneration &+= 1
        let generation = focusGeneration

        let target = controller.findSession.fieldFocusTarget
        let selectAll = controller.findSession.selectFieldTextOnFocus

        let immediate = DispatchWorkItem { [weak self] in
            guard let self, self.focusGeneration == generation else { return }
            self.focusPanelTextField(target: target, selectAll: selectAll, expectedToken: token)
        }
        // Second pass after replace row layout (⌘R expand from find mode).
        let delayed = DispatchWorkItem { [weak self] in
            guard let self, self.focusGeneration == generation else { return }
            self.focusPanelTextField(target: target, selectAll: selectAll, expectedToken: token)
        }
        pendingFocusWorkItems = [immediate, delayed]
        DispatchQueue.main.async(execute: immediate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: delayed)
    }

    private func focusPanelTextField(
        target: FindSession.FieldFocusTarget,
        selectAll: Bool,
        expectedToken: Int
    ) {
        guard controller.findSession.isShowing,
              controller.findSession.fieldFocusToken == expectedToken,
              let hosting = findHosting,
              let window
        else { return }

        hosting.layoutSubtreeIfNeeded()
        let fields = Self.collectTextFields(in: hosting)
        let index: Int
        switch target {
        case .find:
            index = 0
        case .replace:
            index = fields.count > 1 ? 1 : 0
        }
        guard fields.indices.contains(index) else { return }
        let field = fields[index]
        window.makeKeyAndOrderFront(nil)
        if window.makeFirstResponder(field) {
            if selectAll {
                field.currentEditor()?.selectAll(nil)
                if field.currentEditor() == nil {
                    field.selectText(nil)
                }
            }
        }
    }

    private static func collectTextFields(in root: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable {
                result.append(field)
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(root)
        return result
    }
}
#endif
