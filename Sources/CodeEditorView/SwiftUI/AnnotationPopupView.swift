import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// MARK: - Border / shadow (mchakravarty MessageBorder)

private struct MessageBorder: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shadow =
            colorScheme == .dark
            ? Color(.sRGBLinear, white: 0, opacity: 0.66)
            : Color(.sRGBLinear, white: 0, opacity: 0.33)

        if colorScheme == .dark {
            content
                .shadow(color: shadow, radius: 2, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .padding(1)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.black, lineWidth: 1)
                )
        } else {
            content
                .shadow(color: shadow, radius: 1, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.black.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - Public popup (mchakravarty MessagePopupView)

/// Full message popup matching mchakravarty `MessagePopupView` / `MessagePopupCategoryView`.
///
/// Groups annotations by severity; each group is a rounded card with a coloured icon strip
/// on the left and summary (+ optional detail) text on the right. Floats over the editor —
/// not an `NSPopover` system chrome.
///
/// **Sizing:** The root is always `.fixedSize()` so `NSHostingView.fittingSize` is the
/// intrinsic content size. Flexible (`vertical: false`) strips were blowing height to infinity
/// inside an unconstrained hosting view.
public struct AnnotationPopupView: View {
    public let annotations: [LineAnnotation]

    public init(annotations: [LineAnnotation]) {
        self.annotations = annotations
    }

    public var body: some View {
        let groups = Self.grouped(annotations)
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                CategoryCard(severity: group.severity, messages: group.messages)
            }
        }
        // Critical: intrinsic size for NSHostingView / floating subview placement.
        .fixedSize()
    }

    private struct Group {
        var severity: DiagnosticSeverity
        var messages: [LineAnnotation]
    }

    private static func grouped(_ anns: [LineAnnotation]) -> [Group] {
        let order: [DiagnosticSeverity] = [.live, .error, .warning, .info]
        var buckets: [DiagnosticSeverity: [LineAnnotation]] = [:]
        for a in anns {
            buckets[a.severity, default: []].append(a)
        }
        return order.compactMap { sev in
            guard let list = buckets[sev], !list.isEmpty else { return nil }
            return Group(severity: sev, messages: list)
        }
    }
}

// MARK: - Category card (mchakravarty MessagePopupCategoryView)

private struct CategoryCard: View {
    let severity: DiagnosticSeverity
    let messages: [LineAnnotation]
    private let cornerRadius: CGFloat = 10
    private let textColumnWidth: CGFloat = 260

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = platformColor(severity.color)
        let cardBG = colorScheme == .dark ? Color.black : Color.white

        // Layout: fixed text width drives height; icon strip stretches to that height
        // via background (no flexible `vertical: false` / `maxHeight: .infinity` that
        // expand to fill an unconstrained NSHostingView).
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: severity.systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.95))
                .frame(width: 28, alignment: .top)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages) { ann in
                    Text(ann.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = ann.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: textColumnWidth, alignment: .leading)
        }
        .background(
            HStack(spacing: 0) {
                tint.opacity(0.5).frame(width: 28)
                tint.opacity(0.3)
            }
        )
        .background(cardBG)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .fixedSize()
        .modifier(MessageBorder(cornerRadius: cornerRadius))
    }

    private func platformColor(_ color: PlatformColor) -> Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            Color(nsColor: color)
        #else
            Color(uiColor: color)
        #endif
    }
}
