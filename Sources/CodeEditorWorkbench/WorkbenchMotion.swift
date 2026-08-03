import SwiftUI

/// Shared motion curves for workbench chrome (Xcode-like, short and snappy).
///
/// All helpers honor reduce-motion: when `reduceMotion` is true, animations are
/// omitted so content updates apply immediately (WB-N03).
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

    // MARK: - Resolve / apply (WB-N03)

    /// Returns `preferred` unless reduce-motion is enabled (then `nil`).
    public static func resolveAnimation(
        preferred: Animation?,
        reduceMotion: Bool
    ) -> Animation? {
        reduceMotion ? nil : preferred
    }

    /// Run `body` inside `withAnimation` when motion is allowed; otherwise run immediately.
    ///
    /// - Parameter record: Optional test/observability hook that receives the animation
    ///   actually applied (`nil` when reduce-motion or preferred is nil).
    public static func withAnimationIfAvailable(
        _ preferred: Animation? = WorkbenchMotion.pane,
        reduceMotion: Bool = false,
        record: ((Animation?) -> Void)? = nil,
        _ body: () -> Void
    ) {
        let resolved = resolveAnimation(preferred: preferred, reduceMotion: reduceMotion)
        record?(resolved)
        if let resolved {
            withAnimation(resolved, body)
        } else {
            body()
        }
    }

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
