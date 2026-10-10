import SwiftUI

/// Text size of the main window (Settings → Window). macOS ignores `.dynamicTypeSize`, so the
/// window's views scale their own fonts through `appFont` and the `uiScale` environment value.
enum TextSize: String, CaseIterable, Identifiable {
    case small, standard, large, xlarge

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .xlarge: 1.3
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .xlarge: "Extra large"
        }
    }

    /// `ACTIVITYPLUS_TEXT_SIZE=small|standard|large|xlarge` (snapshot runs) wins over the stored setting.
    static func current(stored: String) -> TextSize {
        if let env = ProcessInfo.processInfo.environment["ACTIVITYPLUS_TEXT_SIZE"], let size = TextSize(rawValue: env) { return size }
        return TextSize(rawValue: stored) ?? .standard
    }
}

/// Spacing of the main window: gaps between cards and rows, card padding.
enum Density: String, CaseIterable, Identifiable {
    case compact, normal, spacious

    var id: String { rawValue }

    var factor: CGFloat {
        switch self {
        case .compact: 0.65
        case .normal: 1
        case .spacious: 1.35
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .compact: "Compact"
        case .normal: "Normal"
        case .spacious: "Spacious"
        }
    }

    /// A spacing or padding value for this density; Normal returns it unchanged.
    func space(_ value: CGFloat) -> CGFloat {
        self == .normal ? value : (value * factor).rounded()
    }

    /// Padding around a page's content.
    var page: CGFloat { space(20) }
    /// Gap between cards stacked on a page.
    var stack: CGFloat { space(16) }
    /// Gap between cards side by side or in a grid.
    var grid: CGFloat { space(14) }
    /// Padding inside a card.
    var card: CGFloat { space(16) }
    /// Gap between the lines inside a card.
    var cardLines: CGFloat { space(10) }

    /// `ACTIVITYPLUS_DENSITY=compact|normal|spacious` (snapshot runs) wins over the stored setting.
    static func current(stored: String) -> Density {
        if let env = ProcessInfo.processInfo.environment["ACTIVITYPLUS_DENSITY"], let density = Density(rawValue: env) { return density }
        return Density(rawValue: stored) ?? .normal
    }
}

extension EnvironmentValues {
    /// Font scale of the main window; 1 everywhere else (menu bar panel, share cards, Settings).
    @Entry var uiScale: CGFloat = 1
    @Entry var density: Density = .normal
}

/// Injects the stored text size and density at the root of the main window.
struct MainWindowAppearance: ViewModifier {
    @AppStorage("textSize") private var textSize = TextSize.standard.rawValue
    @AppStorage("density") private var density = Density.normal.rawValue

    func body(content: Content) -> some View {
        content
            .environment(\.uiScale, TextSize.current(stored: textSize).scale)
            .environment(\.density, Density.current(stored: density))
    }
}

/// A text style of the main window. At scale 1 it is exactly the system's semantic font, so the
/// Standard text size looks as before; other scales use the macOS point size of the style times the scale.
struct AppFont {
    enum Base {
        case style(Font.TextStyle)
        case size(CGFloat)
    }

    var base: Base
    var weight: Font.Weight?
    var design: Font.Design?
    var monospaced = false
    var monospacedDigit = false

    func font(scale: CGFloat) -> Font {
        var font: Font
        switch base {
        case .style(let style):
            if scale == 1 {
                font = design.map { Font.system(style, design: $0) } ?? Self.semantic(style)
                if let weight { font = font.weight(weight) }
            } else {
                font = .system(size: Self.pointSize(style) * scale, weight: weight ?? Self.defaultWeight(style), design: design ?? .default)
            }
        case .size(let size):
            font = .system(size: size * scale, weight: weight ?? .regular, design: design ?? .default)
        }
        if monospaced { font = font.monospaced() }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }

    private static func semantic(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        @unknown default: .body
        }
    }

    /// macOS point sizes (NSFont.preferredFont(forTextStyle:)).
    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    private static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline: .bold
        case .caption2: .medium
        default: .regular
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.uiScale) private var scale
    let appFont: AppFont

    func body(content: Content) -> some View {
        content.font(appFont.font(scale: scale))
    }
}

/// Applies the scaled body size to views that inherit the default font; nothing at scale 1.
private struct ScaledBaseFont: ViewModifier {
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        content.font(scale == 1 ? nil : .system(size: AppFont.pointSize(.body) * scale))
    }
}

extension View {
    /// A semantic text style that follows the main window's text size.
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil,
                 monospaced: Bool = false, monospacedDigit: Bool = false) -> some View {
        modifier(AppFontModifier(appFont: AppFont(base: .style(style), weight: weight, design: design,
                                                  monospaced: monospaced, monospacedDigit: monospacedDigit)))
    }

    /// A fixed point size (at Standard) that follows the main window's text size.
    func appFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(AppFontModifier(appFont: AppFont(base: .size(size), weight: weight, design: design, monospacedDigit: monospacedDigit)))
    }

    /// Scales text that has no explicit font (the body size) in the main window.
    func scaledBaseFont() -> some View { modifier(ScaledBaseFont()) }
}

private struct TextColumn: ViewModifier {
    @Environment(\.uiScale) private var scale
    let width: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width * scale, alignment: alignment)
    }
}

extension View {
    /// A fixed-width column for text (figures, names) that widens with the main window's text size.
    func textColumn(width: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(TextColumn(width: width, alignment: alignment))
    }
}
