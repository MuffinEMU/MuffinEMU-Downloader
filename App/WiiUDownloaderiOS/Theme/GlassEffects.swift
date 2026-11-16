import SwiftUI

/// Wraps iOS 26's Liquid Glass APIs (`.glassEffect()`, `GlassEffectContainer`) behind an
/// availability check, falling back to a plain material on older systems so the same view
/// code runs everywhere without scattering `#available` checks through every screen.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill((tint ?? .clear).opacity(0.12)))
            )
        }
    }

    @available(iOS 26.0, *)
    private static func makeGlassStyle(tint: Color?, interactive: Bool) -> Glass {
        var style = Glass.regular
        if let tint { style = style.tint(tint) }
        if interactive { style = style.interactive() }
        return style
    }

    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(tint: tint, interactive: interactive, in: Capsule())
    }

    func liquidGlassRoundedRect(_ radius: CGFloat = Theme.cornerRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(tint: tint, interactive: interactive, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Groups a set of glass views so overlapping ones blend into each other (the "liquid" merge
/// effect) instead of stacking as separate frosted panes. On pre-26 systems this is a no-op.
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}
