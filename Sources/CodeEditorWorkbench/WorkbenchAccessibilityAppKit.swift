import SwiftUI

#if canImport(AppKit)
import AppKit

/// Transparent AppKit accessibility element for workbench chrome (REL-N04).
///
/// SwiftUI `accessibilityIdentifier` alone is not always materialised on the
/// AppKit accessibility tree under `NSHostingView` in automated hosts. These
/// anchors place real `NSView` accessibility elements so VoiceOver / XCUI /
/// in-process AX probes observe the same identifiers as production chrome.
public final class WorkbenchAccessibilityNSAnchorView: NSView {
    public init(
        identifier: String,
        label: String? = nil,
        role: NSAccessibility.Role = .group
    ) {
        super.init(frame: .zero)
        // Expand to parent bounds without participating in layout.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        apply(identifier: identifier, label: label, role: role)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func apply(
        identifier: String,
        label: String?,
        role: NSAccessibility.Role
    ) {
        setAccessibilityElement(true)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityRole(role)
        setAccessibilityEnabled(true)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Fill parent so AT hit-testing / bounds are non-zero when parent lays out.
        if let superview {
            frame = superview.bounds
            autoresizingMask = [.width, .height]
        }
    }
}

/// SwiftUI wrapper that hosts ``WorkbenchAccessibilityNSAnchorView``.
public struct WorkbenchAccessibilityAnchor: NSViewRepresentable {
    public var identifier: String
    public var label: String?
    public var role: NSAccessibility.Role

    public init(
        identifier: String,
        label: String? = nil,
        role: NSAccessibility.Role = .group
    ) {
        self.identifier = identifier
        self.label = label
        self.role = role
    }

    public func makeNSView(context: Context) -> WorkbenchAccessibilityNSAnchorView {
        WorkbenchAccessibilityNSAnchorView(identifier: identifier, label: label, role: role)
    }

    public func updateNSView(_ nsView: WorkbenchAccessibilityNSAnchorView, context: Context) {
        nsView.apply(identifier: identifier, label: label, role: role)
    }
}

extension View {
    /// Declare chrome accessibility for VoiceOver **and** the AppKit AX tree.
    ///
    /// Combines SwiftUI accessibility modifiers with a live AppKit anchor so
    /// XCUI / `WorkbenchAccessibilityTreeProbe` observe real identifiers.
    public func workbenchAccessibilityChrome(
        id: String,
        label: String? = nil,
        role: NSAccessibility.Role = .group
    ) -> some View {
        self
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
            .modifier(_WorkbenchOptionalAXLabel(label: label))
            .background {
                WorkbenchAccessibilityAnchor(identifier: id, label: label, role: role)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) // avoid duplicate VO nodes; AppKit walk still sees NSView
            }
    }
}

/// Applies `accessibilityLabel` only when non-nil / non-empty.
private struct _WorkbenchOptionalAXLabel: ViewModifier {
    var label: String?
    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}
#endif
