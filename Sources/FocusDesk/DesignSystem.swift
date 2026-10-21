import AppKit
import FocusCore
import SwiftUI

// MARK: - Colors

enum Palette {
    static let background = Color(red: 0.050, green: 0.062, blue: 0.080)
    static let sidebar = Color(red: 0.038, green: 0.047, blue: 0.062)
    static let surface = Color(red: 0.085, green: 0.104, blue: 0.128)
    static let elevated = Color(red: 0.112, green: 0.134, blue: 0.162)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color(red: 0.93, green: 0.95, blue: 0.96)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.64)
    static let mint = Color(red: 0.64, green: 0.89, blue: 0.73)
    static let mintBright = Color(red: 0.73, green: 0.95, blue: 0.81)
    static let coral = Color(red: 1, green: 0.65, blue: 0.48)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)

    static func category(_ name: String, in categories: [CategoryItem] = CategoryItem.defaults) -> Color {
        if let found = categories.first(where: { $0.name == name }) {
            return Color(red: found.red, green: found.green, blue: found.blue)
        }
        switch name {
        case "Contenido": return coral
        case "Estudio": return .init(red: 0.65, green: 0.69, blue: 0.98)
        case "Tienda": return mint
        default: return .init(red: 0.7, green: 0.78, blue: 0.87)
        }
    }
}

// MARK: - Navigation

enum AppPage: String, CaseIterable, Identifiable {
    case today = "Hoy"
    case week = "Semana"
    case history = "Historial"
    case settings = "Ajustes"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .week: return "calendar"
        case .history: return "chart.bar.xaxis"
        case .settings: return "slider.horizontal.3"
        }
    }

    var shortcut: String {
        switch self {
        case .today: return "⌘1"
        case .week: return "⌘2"
        case .history: return "⌘3"
        case .settings: return "⌘4"
        }
    }

    var headline: String {
        switch self {
        case .today: return "Haz espacio para lo importante."
        case .week: return "Una semana con intención."
        case .history: return "Lo que has hecho cuenta."
        case .settings: return "A tu manera."
        }
    }
}

// MARK: - Buttons

enum FocusButtonKind {
    case primary, secondary, ghost, warning, destructive
}

/// Shared button body with hover, press and disabled states.
private struct FocusButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FocusButtonKind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous) }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.background
        case .secondary: return Palette.text
        case .ghost: return hovering ? Palette.text : Palette.muted
        case .warning: return Palette.coral
        case .destructive: return Palette.danger
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return hovering ? Palette.mintBright : Palette.mint
        case .secondary: return Color.white.opacity(hovering ? 0.11 : 0.06)
        case .ghost: return Color.white.opacity(hovering ? 0.06 : 0)
        case .warning: return Palette.coral.opacity(hovering ? 0.18 : 0.10)
        case .destructive: return Palette.danger.opacity(hovering ? 0.18 : 0.09)
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary: return Color.white.opacity(0.08)
        case .warning: return Palette.coral.opacity(0.28)
        case .destructive: return Palette.danger.opacity(0.28)
        }
    }
}

struct FocusButtonStyle: ButtonStyle {
    var kind: FocusButtonKind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        FocusButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

/// Kept for compatibility with existing call sites.
struct FocusPrimaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        FocusButtonBody(configuration: configuration, kind: .primary, compact: compact)
    }
}

extension ButtonStyle where Self == FocusButtonStyle {
    static var focusSecondary: FocusButtonStyle { FocusButtonStyle(kind: .secondary) }
    static var focusGhost: FocusButtonStyle { FocusButtonStyle(kind: .ghost) }
    static var focusDestructive: FocusButtonStyle { FocusButtonStyle(kind: .destructive) }
    static func focus(_ kind: FocusButtonKind, compact: Bool = false) -> FocusButtonStyle {
        FocusButtonStyle(kind: kind, compact: compact)
    }
}

private struct FocusIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(hovering ? Palette.text : tint)
            .background(Color.white.opacity(hovering ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct FocusIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = Palette.muted
    func makeBody(configuration: Configuration) -> some View {
        FocusIconBody(configuration: configuration, size: size, tint: tint)
    }
}

extension ButtonStyle where Self == FocusIconButtonStyle {
    static var focusIcon: FocusIconButtonStyle { FocusIconButtonStyle() }
}

/// Toggle-like chip used for presets, profiles and weekday pickers.
private struct SelectableChipBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    var tint: Color
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Palette.background : (hovering ? Palette.text : Palette.muted))
            .background(selected ? tint : Color.white.opacity(hovering ? 0.10 : 0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

struct SelectableChipStyle: ButtonStyle {
    var selected: Bool
    var tint: Color = Palette.mint
    func makeBody(configuration: Configuration) -> some View {
        SelectableChipBody(configuration: configuration, selected: selected, tint: tint)
    }
}

// MARK: - Containers and labels

struct Card<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let icon: String?
    let trailing: Trailing

    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.mint)
            }
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil) {
        self.init(title, icon: icon) { EmptyView() }
    }
}

struct Chip: View {
    let text: String
    var icon: String?
    var color: Color = Palette.muted

    init(_ text: String, icon: String? = nil, color: Color = Palette.muted) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct StatPill: View {
    let label: String
    let value: String
    let icon: String
    var tint: Color = Palette.mint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

struct ProgressRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: progress)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.mint)
                .frame(width: 54, height: 54)
                .background(Palette.mint.opacity(0.08), in: Circle())
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(Palette.stroke))
    }
}

private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 12) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    func fieldLabelStyle() -> some View {
        font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.muted)
    }
}
