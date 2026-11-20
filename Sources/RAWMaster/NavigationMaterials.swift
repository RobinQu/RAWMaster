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
    @ViewBuilder func body(content: Content) -> some View {
        switch policy {
        case .opaque:
            content.background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.45), lineWidth: 1))
        case .glass:
            if #available(macOS 26.0, *) { content.glassEffect(.regular, in: .rect(cornerRadius: 12)) }
            else { material(content) }
        case .material:
            material(content)
        }
    }
    private func material(_ content: Content) -> some View {
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.boundary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

/// Read actual preferences at the control surface. Photo pixels and metadata keep
/// their opaque content backgrounds independently of this navigation material.
private struct FloatingSelectionSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var supportsGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }
    func body(content: Content) -> some View {
        content.modifier(ResolvedFloatingControlSurface(policy: .resolve(
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased, supportsGlass: supportsGlass)))
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
    func floatingSelectionSurface() -> some View { modifier(FloatingSelectionSurface()) }
}
