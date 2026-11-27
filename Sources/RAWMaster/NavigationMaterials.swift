import AppKit
import SwiftUI

/// A resolved material choice shared by floating control surfaces. Accessibility
/// preferences take precedence over the platform's available translucent material.
enum FloatingControlSurfacePolicy: Equatable {
    case opaque, glass, material
    static func resolve(reduceTransparency: Bool, increasedContrast: Bool, supportsGlass: Bool) -> Self {
        if reduceTransparency || increasedContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

struct ResolvedFloatingControlSurface: ViewModifier {
    let policy: FloatingControlSurfacePolicy
    var cornerRadius: CGFloat = 12
    @Environment(\.controlActiveState) private var windowActivity

    func body(content: Content) -> some View {
        content.background { background.allowsHitTesting(false).accessibilityHidden(true) }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch policy {
        case .opaque:
            shape.fill(AppPalette.panel)
                .overlay(shape.strokeBorder(.primary.opacity(0.45), lineWidth: 1))
        case .glass:
            if #available(macOS 26.0, *) {
                // Rebind only the compositor surface when returning from another app, sheet or Graph.
                Color.clear.glassEffect(.regular, in: shape).id(windowActivity == .key)
            } else { material }
        case .material:
            material
        }
    }
    private var material: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(AppPalette.boundary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

/// Read actual preferences at the control surface. Photo pixels and metadata keep
/// their opaque content backgrounds independently of this navigation material.
private struct FloatingSelectionSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var supportsGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }
    func body(content: Content) -> some View {
        content.modifier(ResolvedFloatingControlSurface(policy: .resolve(
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased, supportsGlass: supportsGlass),
            cornerRadius: cornerRadius))
    }
}
struct NativeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar; view.blendingMode = .withinWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
extension View {
    func floatingSelectionSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(FloatingSelectionSurface(cornerRadius: cornerRadius))
    }
}
