#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Floating completion / jump-to-definition list (AppKit table for reliable clicks).
///
/// Uses a nonactivating `NSPanel` + `NSTableView` (not SwiftUI hosting, which delayed clicks).
/// Jump multi-target and typing completions share this panel.
///
/// **Re-entrancy:** `NSTableView.selectRowIndexes` posts `tableViewSelectionDidChange`
/// synchronously. Calling back into `EditorController.notifyCompletionSessionChange` from
/// that callback used to recurse until stack overflow when typing. Selection callbacks only
/// update the model *silently* and never re-notify.
@MainActor
final class AppKitCompletionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: EditorController?
    private weak var editorView: NSView?
    private var panel: NSPanel?
    private var scrollView: NSScrollView?
    private var tableView: NSTableView?
    private var visualEffect: NSVisualEffectView?
    private var lastRevision: Int = -1
    private var cachedRows: [Row] = []
    /// Jump mode: single click applies. Typing completions: single click selects, double applies.
    private var applyOnSelect = false
    /// True for the entire body of `sync()` (including nested AppKit selection notifications).
    private var isSyncing = false
    /// Coalesce bursty session notifies onto one panel refresh per turn.
    private var syncScheduled = false

    private struct Row {
        let label: String
        let detail: String?
        let systemImage: String
        let deprecated: Bool
    }

    private enum Column {
        static let main = NSUserInterfaceItemIdentifier("main")
    }

    func attach(controller: EditorController, editorView: NSView) {
        self.controller = controller
        self.editorView = editorView
        controller.onCompletionSessionChange = { [weak self] in
            self?.scheduleSync()
        }
    }

    func detach() {
        hide()
        controller?.onCompletionSessionChange = nil
        controller = nil
        editorView = nil
    }

    /// Always async — never run panel table mutations on the same stack as a table
    /// selection notification or typing insert.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.sync()
        }
    }

    func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard let controller else { return }
        let session = controller.completionSession
        guard session.isVisible, !session.items.isEmpty else {
            hide()
            return
        }

        let revision = session.revision
        let needsReload = revision != lastRevision || cachedRows.count != session.items.count
        lastRevision = revision
        applyOnSelect = controller.isJumpLinkPopoverVisible
        cachedRows = session.items.map { entry in
            Row(
                label: entry.label,
                detail: entry.detail,
                systemImage: entry.systemImage,
                deprecated: entry.deprecated
            )
        }
        ensurePanel()
        if needsReload {
            // Temporarily drop delegate so reload/select cannot re-enter controller.
            let table = tableView
            table?.delegate = nil
            table?.reloadData()
            let selected = min(max(0, session.selectedIndex), max(0, cachedRows.count - 1))
            if !cachedRows.isEmpty {
                table?.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
                table?.scrollRowToVisible(selected)
            }
            table?.delegate = self
        } else if let tableView {
            let selected = min(max(0, session.selectedIndex), max(0, cachedRows.count - 1))
            if tableView.selectedRow != selected {
                tableView.delegate = nil
                tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
                tableView.scrollRowToVisible(selected)
                tableView.delegate = self
            }
        }
        positionPanel()
        panel?.orderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
        lastRevision = -1
        cachedRows = []
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
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.doubleAction = #selector(tableDoubleClicked(_:))

        let column = NSTableColumn(identifier: Column.main)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.sizeLastColumnToFit()

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = effect.bounds

        effect.addSubview(scroll)
        panel.contentView = effect

        self.panel = panel
        self.visualEffect = effect
        self.scrollView = scroll
        self.tableView = table

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
        guard let caret = controller.completionAnchorRect(containerWidth: width) else { return }
        let caretInWindow = editorView.convert(caret, to: nil)
        let caretOnScreen = window.convertToScreen(caretInWindow)

        let rowCount = CGFloat(max(1, controller.completionSession.items.count))
        let size = CGSize(width: 320, height: min(260, 12 + rowCount * 28))
        var origin = CGPoint(x: caretOnScreen.minX, y: caretOnScreen.minY - size.height - 4)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = caretOnScreen.maxY + 4
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        scrollView?.frame = panel.contentView?.bounds ?? .zero
        tableView?.tableColumns.first?.width = size.width - 8
    }

    // MARK: - Actions

    @objc private func tableClicked(_ sender: Any?) {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        let row = tableView.clickedRow
        guard let controller, row < controller.completionSession.items.count else { return }

        if applyOnSelect || controller.isJumpLinkPopoverVisible {
            applyRow(row)
        } else {
            // Silent model update — table already shows the selection.
            controller.completionSession.selectIndex(row)
            if let item = controller.completionSession.selectedItem {
                controller.completionDelegate?.completionWindowDidSelect(item: item)
            }
        }
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        if applyOnSelect || controller?.isJumpLinkPopoverVisible == true { return }
        applyRow(tableView.clickedRow)
    }

    private func applyRow(_ row: Int) {
        guard let controller else { return }
        guard row >= 0, row < controller.completionSession.items.count else {
            controller.hideCompletions()
            return
        }
        controller.completionSession.selectIndex(row)
        if let link = controller.completionSession.selectedItem as? JumpToDefinitionLink {
            controller.jumpToDefinitionModel.open(link: link)
        } else {
            controller.applyCompletionSelection()
        }
        hide()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        cachedRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard cachedRows.indices.contains(row) else { return nil }
        let item = cachedRows[row]
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CompletionCellView)
            ?? CompletionCellView()
        cell.identifier = id
        cell.configure(label: item.label, detail: item.detail, systemImage: item.systemImage, deprecated: item.deprecated)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // CRITICAL: never call notifyCompletionSessionChange / sync from here.
        // That path was a stack-overflow when typing (selectRowIndexes → didChange → notify → sync → …).
        guard !isSyncing else { return }
        guard !applyOnSelect else { return }
        guard let tableView, tableView.selectedRow >= 0 else { return }
        let row = tableView.selectedRow
        guard let controller, row < controller.completionSession.items.count else { return }
        // Silent model update only.
        if controller.completionSession.selectedIndex != row {
            controller.completionSession.selectIndex(row)
            if let item = controller.completionSession.selectedItem {
                controller.completionDelegate?.completionWindowDidSelect(item: item)
            }
        }
    }
}

// MARK: - Cell

private final class CompletionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        labelField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelField)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailField.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(label: String, detail: String?, systemImage: String, deprecated: Bool) {
        iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        labelField.stringValue = label
        if deprecated {
            labelField.attributedStringValue = NSAttributedString(
                string: label,
                attributes: [
                    .font: labelField.font as Any,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
        detailField.stringValue = detail ?? ""
        detailField.isHidden = (detail?.isEmpty ?? true)
    }
}
#endif
