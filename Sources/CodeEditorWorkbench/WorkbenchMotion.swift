import SwiftUI

/// Shared motion curves for workbench chrome (Xcode-like, short and snappy).
public enum WorkbenchMotion {
    /// Sidebar / inspector / utility show-hide.
    public static let pane: Animation = .snappy(duration: 0.22, extraBounce: 0)

    /// Folder expand / collapse in the project navigator.
    public static let fold: Animation = .snappy(duration: 0.18, extraBounce: 0)

    /// Tab strip insert / remove / selection chrome.
    public static let tab: Animation = .easeInOut(duration: 0.16)

    /// Subtle content cross-fade (empty ↔ editor, tab content).
    public static let content: Animation = .easeInOut(duration: 0.14)

    /// Activity bar / toolbar selection highlights.
    public static let chrome: Animation = .easeInOut(duration: 0.12)

    /// Navigator row selection.
    public static let selection: Animation = .easeOut(duration: 0.1)

    // MARK: - Transitions

    public static var navigatorInsert: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    public static var inspectorInsert: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    public static var utilityInsert: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

    public static var foldChildren: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    public static var tabInsert: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
        )
    }

    public static var editorContent: AnyTransition {
        .opacity
    }
}
