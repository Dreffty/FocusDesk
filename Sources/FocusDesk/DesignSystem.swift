import AppKit
import FocusCore
import SwiftUI

// MARK: - Colors

/// Colour tokens with a role each, resolved for the current appearance: dark, light, and the Increase Contrast
/// variant of both. Text tokens reach at least 4.5:1 and control borders 3:1 on every surface (see
/// docs/REVISION-DISENO.md for the figures). One colour, one meaning: the accent is for primary actions and the
/// running session, `warning` for things that need attention, `danger` for destructive actions; category colours
/// live apart and never stand in for a state.
enum Palette {
    static let background = dynamic(dark: rgb(0.050, 0.062, 0.080), light: rgb(0.957, 0.961, 0.969), darkHC: rgb(0, 0, 0), lightHC: rgb(1, 1, 1))
    static let sidebar = dynamic(dark: rgb(0.038, 0.047, 0.062), light: rgb(0.922, 0.929, 0.941), darkHC: rgb(0, 0, 0), lightHC: rgb(0.95, 0.95, 0.96))
    static let surface = dynamic(dark: rgb(0.085, 0.104, 0.128), light: rgb(1, 1, 1), darkHC: rgb(0.07, 0.08, 0.10), lightHC: rgb(1, 1, 1))
    static let elevated = dynamic(dark: rgb(0.112, 0.134, 0.162), light: rgb(0.945, 0.949, 0.957), darkHC: rgb(0.11, 0.12, 0.14), lightHC: rgb(0.93, 0.94, 0.95))
    /// Decorative separators and card outlines.
    static let stroke = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.09), darkHC: NSColor(white: 1, alpha: 0.30), lightHC: NSColor(white: 0, alpha: 0.35))
    /// Outline of something you type into or press: 3:1 against its surface.
    static let fieldStroke = dynamic(dark: NSColor(white: 1, alpha: 0.36), light: NSColor(white: 0, alpha: 0.42), darkHC: NSColor(white: 1, alpha: 0.60), lightHC: NSColor(white: 0, alpha: 0.65))
    /// Quiet fills for secondary controls and hover states.
    static let fill = dynamic(dark: NSColor(white: 1, alpha: 0.055), light: NSColor(white: 0, alpha: 0.045), darkHC: NSColor(white: 1, alpha: 0.12), lightHC: NSColor(white: 0, alpha: 0.10))
    static let fillHover = dynamic(dark: NSColor(white: 1, alpha: 0.10), light: NSColor(white: 0, alpha: 0.08), darkHC: NSColor(white: 1, alpha: 0.20), lightHC: NSColor(white: 0, alpha: 0.16))
    /// Hours outside the working day in the hourly grid.
    static let offHours = dynamic(dark: NSColor(white: 0, alpha: 0.16), light: NSColor(white: 0, alpha: 0.035), darkHC: NSColor(white: 0, alpha: 0.30), lightHC: NSColor(white: 0, alpha: 0.08))
    static let text = dynamic(dark: rgb(0.93, 0.95, 0.96), light: rgb(0.106, 0.122, 0.141), darkHC: rgb(1, 1, 1), lightHC: rgb(0, 0, 0))
    static let muted = dynamic(dark: rgb(0.60, 0.65, 0.68), light: rgb(0.345, 0.376, 0.416), darkHC: rgb(0.78, 0.81, 0.84), lightHC: rgb(0.22, 0.24, 0.27))
    /// The accent: primary actions and the running session.
    static let mint = dynamic(dark: rgb(0.64, 0.89, 0.73), light: rgb(0.075, 0.45, 0.27), darkHC: rgb(0.70, 0.95, 0.79), lightHC: rgb(0.03, 0.33, 0.19))
    static let mintBright = dynamic(dark: rgb(0.73, 0.95, 0.81), light: rgb(0.06, 0.38, 0.23), darkHC: rgb(0.80, 1.0, 0.86), lightHC: rgb(0.02, 0.26, 0.15))
    /// Text and icons drawn on top of the accent.
    static let onAccent = dynamic(dark: rgb(0.050, 0.062, 0.080), light: rgb(1, 1, 1), darkHC: rgb(0, 0, 0), lightHC: rgb(1, 1, 1))
    /// Needs attention: overdue, overlapping, paused by the system, overtime.
    static let warning = dynamic(dark: rgb(0.98, 0.78, 0.30), light: rgb(0.55, 0.32, 0.0), darkHC: rgb(1.0, 0.84, 0.40), lightHC: rgb(0.42, 0.24, 0.0))
    static let danger = dynamic(dark: rgb(1.0, 0.50, 0.50), light: rgb(0.75, 0.15, 0.15), darkHC: rgb(1.0, 0.60, 0.60), lightHC: rgb(0.60, 0.08, 0.08))

    static func category(_ name: String, in categories: [CategoryItem] = CategoryItem.defaults) -> Color {
        if let found = categories.first(where: { $0.name == name }) {
            return Color(red: found.red, green: found.green, blue: found.blue)
        }
        let fallback = CategoryItem.defaults.first { $0.name == name } ?? CategoryItem.defaults[0]
        return Color(red: fallback.red, green: fallback.green, blue: fallback.blue)
    }

    /// `color` adjusted until it reads at 4.5:1 on the current surface: category colours are chosen freely
    /// (a blue or violet "Universidad" became dark text on a dark background) and must still be legible as text.
    static func readable(_ color: Color) -> Color {
        let base = NSColor(color)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            let dark = isDark(appearance)
            let surface: (CGFloat, CGFloat, CGFloat) = dark ? (0.085, 0.104, 0.128) : (1, 1, 1)
            let target: (CGFloat, CGFloat, CGFloat) = dark ? (1, 1, 1) : (0, 0, 0)
            var value = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
            var steps = 0
            while contrast(value, surface) < 4.8 && steps < 12 {
                value = (value.0 + (target.0 - value.0) * 0.15, value.1 + (target.1 - value.1) * 0.15, value.2 + (target.2 - value.2) * 0.15)
                steps += 1
            }
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }

    private static func dynamic(dark: NSColor, light: NSColor, darkHC: NSColor? = nil, lightHC: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua?: return darkHC ?? dark
            case .accessibilityHighContrastAqua?: return lightHC ?? light
            case .darkAqua?: return dark
            default: return light
            }
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func contrast(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat { 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2) }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }
}

/// One place for every font size, so the text can grow with the "Tamaño del texto" setting (macOS has no Dynamic
/// Type: `typography.md › Desktop`) and never drops below the 10-point macOS minimum (`accessibility.md › Vision`).
enum TextScale {
    static var factor: CGFloat = 1
    static let options: [(label: String, value: Double)] = [("Normal", 1.0), ("Grande", 1.15), ("Muy grande", 1.3)]
}

extension Font {
    static func app(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: max(10, (size * TextScale.factor).rounded()), weight: weight, design: design)
    }
}

// MARK: - Navigation

enum AppPage: String, CaseIterable, Identifiable {
    case today = "Hoy"
    case week = "Semana"
    case history = "Historial"
    case blocking = "Bloquear ahora"
    case rules = "Reglas y límites"
    case breaks = "Descansos"
    case settings = "Ajustes"

    /// The two halves of the sidebar: planning the day, and keeping distractions out of it. Grouped and titled so
    /// the blocking tools are as visible as the agenda (`sidebars.md › Best practices`).
    enum Group: String, CaseIterable, Identifiable {
        case agenda = "Agenda"
        case protection = "Antidistracción"
        var id: String { rawValue }
        var pages: [AppPage] { AppPage.allCases.filter { $0 != .settings && $0.group == self } }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .blocking, .rules, .breaks: return .protection
        default: return .agenda
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .week: return "calendar"
        case .history: return "chart.bar.xaxis"
        case .blocking: return "bolt"
        case .rules: return "shield.lefthalf.filled"
        case .breaks: return "cup.and.saucer"
        case .settings: return "slider.horizontal.3"
        }
    }

    var shortcut: String {
        switch self {
        case .today: return "⌘1"
        case .week: return "⌘2"
        case .history: return "⌘3"
        case .blocking: return "⌘4"
        case .rules: return "⌘5"
        case .breaks: return "⌘6"
        case .settings: return "⌘,"
        }
    }

    var headline: String {
        switch self {
        case .today: return "Haz espacio para lo importante."
        case .week: return "Una semana con intención."
        case .history: return "Lo que has hecho cuenta."
        case .blocking: return "Corta las distracciones ahora mismo."
        case .rules: return "Tus límites, también fuera de las tareas."
        case .breaks: return "Descansa antes de necesitarlo."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.app(compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 15)
            .padding(.vertical, compact ? 6 : 9)
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = enabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous) }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.onAccent
        case .secondary: return Palette.text
        case .ghost: return hovering ? Palette.text : Palette.muted
        case .warning: return Palette.warning
        case .destructive: return Palette.danger
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return hovering ? Palette.mintBright : Palette.mint
        case .secondary: return hovering ? Palette.fillHover : Palette.fill
        case .ghost: return hovering ? Palette.fill : .clear
        case .warning: return Palette.warning.opacity(hovering ? 0.18 : 0.10)
        case .destructive: return Palette.danger.opacity(hovering ? 0.18 : 0.09)
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary: return hovering ? Palette.fieldStroke.opacity(0.65) : Palette.stroke
        case .warning: return Palette.warning.opacity(0.32)
        case .destructive: return Palette.danger.opacity(0.32)
        }
    }
}

// MARK: - Text Fields

private struct FocusTextFieldBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        content()
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(isFocused ? Palette.surface : Palette.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isFocused ? Palette.mint : (isHovered ? Palette.fieldStroke.opacity(0.75) : Palette.fieldStroke.opacity(0.45)),
                        lineWidth: isFocused ? 1.4 : 1
                    )
            )
            .shadow(color: isFocused ? Palette.mint.opacity(0.14) : .clear, radius: 5, y: 0)
            .focused($isFocused)
            .onHover { isHovered = enabled && $0 }
            .opacity(enabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

/// Consistent custom dark/light text field replacing Aqua's `.roundedBorder` in editors.
struct FocusTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FocusTextFieldBox {
            configuration
        }
    }
}

extension TextFieldStyle where Self == FocusTextFieldStyle {
    static var focusField: FocusTextFieldStyle { FocusTextFieldStyle() }
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
            .font(.app(size * 0.42, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(hovering ? Palette.text : tint)
            .background(hovering ? Palette.fillHover : Palette.fill, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
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
            .font(.app(12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Palette.onAccent : (hovering ? Palette.text : Palette.muted))
            .background(selected ? tint : (hovering ? Palette.fillHover : Palette.fill), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: selected)
            // Selection was only visible as a colour change: VoiceOver now says "seleccionado".
            .accessibilityAddTraits(selected ? .isSelected : [])
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

/// A card folded down to one line: its title and what is inside, so nothing that is set stays hidden.
struct FoldedCard<Content: View>: View {
    let title: String
    let icon: String
    let summary: String
    var attention = false
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.app(10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: icon).font(.app(12, weight: .semibold)).foregroundStyle(Palette.mint)
                        Text(title).font(.app(13, weight: .semibold))
                        Spacer(minLength: 12)
                        Text(summary)
                            .font(.app(11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(attention ? Palette.warning : Palette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(attention ? Palette.warning.opacity(0.12) : Palette.fill, in: Capsule())
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(summary)
                .accessibilityHint(isExpanded ? "Plegar" : "Desplegar")
                .accessibilityAddTraits(.isHeader)
                if isExpanded {
                    content
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                }
            }
        }
    }
}

/// Text on the left and the switch on the right edge, the way a Mac lays them out: pegged to their labels, each
/// switch ended up at a different place and a column of them zigzagged.
struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            // The label travels with the switch, hidden, so VoiceOver still says what it does.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == TrailingSwitchToggleStyle {
    static var trailingSwitch: TrailingSwitchToggleStyle { TrailingSwitchToggleStyle() }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let icon: String?
    let tint: Color
    let trailing: Trailing

    init(_ title: String, icon: String? = nil, tint: Color = Palette.mint, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.app(11, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(title.uppercased())
                .font(.app(11, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Palette.muted)
                // A heading for the VoiceOver rotor, read in normal case rather than spelled out.
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, tint: Color = Palette.mint) {
        self.init(title, icon: icon, tint: tint) { EmptyView() }
    }
}

/// The countdown changes every second: no rolling-digit motion when Reduce Motion is on (`motion.md`).
struct CountdownTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion { content } else { content.contentTransition(.numericText()) }
    }
}

/// A duration in words for VoiceOver: "24 minutos", "1 hora y 5 minutos". Rounded to the minute so the spoken
/// value does not change every second.
func spokenDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int((abs(seconds) / 60).rounded())
    if minutes < 1 { return "menos de un minuto" }
    let hours = minutes / 60, rest = minutes % 60
    let h = hours == 1 ? "1 hora" : "\(hours) horas"
    let m = rest == 1 ? "1 minuto" : "\(rest) minutos"
    if hours == 0 { return m }
    return rest == 0 ? h : "\(h) y \(m)"
}

/// Due date that has passed says so in words and with its own icon, not only by turning orange.
struct DueChip: View {
    let due: Date
    let now: Date
    var prefix = "Límite"

    var body: some View {
        let date = due.formatted(date: .abbreviated, time: .shortened)
        if due < now {
            Chip("Vencida · \(date)", icon: "exclamationmark.circle.fill", color: Palette.warning)
        } else {
            Chip("\(prefix) \(date)", icon: "flag", color: Palette.muted)
        }
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
        .font(.app(11, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // Category colours are picked freely; the text always reaches 4.5:1, the hue stays in the capsule.
        .foregroundStyle(Palette.readable(color))
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(.app(10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                .font(.app(13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.app(17, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.app(10, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.5), value: progress)
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
                .font(.app(24, weight: .regular))
                .foregroundStyle(Palette.mint)
                .frame(width: 54, height: 54)
                .background(Palette.mint.opacity(0.08), in: Circle())
            Text(title).font(.app(15, weight: .semibold))
            Text(detail)
                .font(.app(12))
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
            .background(hovering ? Palette.fill : .clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 12) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    func fieldLabelStyle() -> some View {
        font(.app(10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Palette.muted)
            .padding(.top, 2)
    }
}
