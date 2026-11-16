import SwiftUI
import WUDCore

/// Small, deliberately narrow design system: a couple of brand colors, one accent gradient,
/// consistent corner radii/shadows, and per-category colors/icons so the list, detail, and
/// queue views all agree on how a "Game" vs "DLC" vs "Update" should look.
enum Theme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10

    static let accentGradient = LinearGradient(
        colors: [Color(hue: 0.58, saturation: 0.85, brightness: 0.95), Color(hue: 0.66, saturation: 0.75, brightness: 0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.12) : Color(white: 1.0)
    }

    static func color(for category: TitleCategory) -> Color {
        switch category {
        case .game: return .blue
        case .update: return .green
        case .dlc: return .purple
        case .demo: return .orange
        case .all: return .gray
        case .disc: return .gray
        }
    }

    static func icon(for category: TitleCategory) -> String {
        switch category {
        case .game: return "gamecontroller.fill"
        case .update: return "arrow.triangle.2.circlepath"
        case .dlc: return "shippingbox.fill"
        case .demo: return "sparkles"
        case .all: return "square.grid.2x2.fill"
        case .disc: return "opticaldisc.fill"
        }
    }

    static func label(for category: TitleCategory) -> String {
        switch category {
        case .game: return "Game"
        case .update: return "Update"
        case .dlc: return "DLC"
        case .demo: return "Demo"
        case .all: return "All"
        case .disc: return "Disc"
        }
    }
}

/// A rounded, softly-shadowed container used for every "card" in the app so spacing/elevation
/// stays consistent without repeating modifiers everywhere.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.cardBackground(scheme))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.08), radius: 8, x: 0, y: 3)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

/// A small colored badge with an icon, used anywhere a category needs a compact visual identity.
struct CategoryBadge: View {
    let category: TitleCategory
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Theme.color(for: category).gradient)
            Image(systemName: Theme.icon(for: category))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Horizontally-scrolling row of category filter pills, replacing a plain menu with something
/// that shows the current selection and every option at a glance.
struct CategoryPillRow: View {
    @Binding var selection: TitleCategory
    let categories: [TitleCategory]

    @Namespace private var glassNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassGroup {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { category in
                        CategoryPill(category: category, isSelected: category == selection, namespace: glassNamespace) {
                            withAnimation(.snappy) { selection = category }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct CategoryPill: View {
    let category: TitleCategory
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(Theme.label(for: category), systemImage: Theme.icon(for: category))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule().fill(Theme.color(for: category).gradient)
                    .modifier(GlassEffectIDModifier(id: "selectedPill", namespace: namespace))
            }
        }
        .liquidGlassCapsule(tint: isSelected ? nil : Theme.color(for: category).opacity(0.3))
    }
}

/// Applies `glassEffectID` (for the morph transition between pills) only on iOS 26+; a plain
/// no-op elsewhere, since the modifier itself doesn't exist pre-26.
private struct GlassEffectIDModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

/// A circular progress indicator sized for a list row's leading edge, with the category icon
/// showing through the middle so a queue row reads at a glance even before it starts moving.
struct RingProgressView: View {
    let progress: Double
    let category: TitleCategory
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.color(for: category).opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Theme.color(for: category).gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
            Image(systemName: Theme.icon(for: category))
                .font(.system(size: size * 0.32))
                .foregroundStyle(Theme.color(for: category))
        }
        .frame(width: size, height: size)
    }
}
