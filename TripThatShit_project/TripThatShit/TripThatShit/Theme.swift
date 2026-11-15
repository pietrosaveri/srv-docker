import SwiftUI

/// Design tokens from design.md. Every token adapts to light and dark mode.
enum Theme {
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Background behind grouped forms, so white rows stay visible in light mode.
    static let formCanvas = dynamic(light: 0xF2F2F4, dark: 0x000000)
    static let surface = dynamic(light: 0xF4F4F4, dark: 0x16181A)
    static let surfaceDeep = dynamic(light: 0xEAEAEE, dark: 0x0A0A0A)
    static let hairline = dynamic(light: 0x191C1F, lightAlpha: 0.1, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let text = dynamic(light: 0x191C1F, dark: 0xFFFFFF)
    static let mute = dynamic(light: 0x505A63, dark: 0xFFFFFF, darkAlpha: 0.72)
    static let stone = Color(hex: 0x8D969E)
    static let danger = Color(hex: 0xE23B4A)
    /// Subtle tinted fill for icon buttons and chips.
    static let fill = dynamic(light: 0x191C1F, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// High-contrast surface for the primary CTA (white on dark, ink on light).
    static let inverse = dynamic(light: 0x191C1F, dark: 0xFFFFFF)
    static let inversePressed = dynamic(light: 0x3A3D40, dark: 0xC9C9CD)
    static let onInverse = dynamic(light: 0xFFFFFF, dark: 0x000000)

    nonisolated static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        let l = UIColor(hex: light, alpha: lightAlpha), d = UIColor(hex: dark, alpha: darkAlpha)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// sRGB hex of the colour, clamped to 0...255 per channel.
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }
}

extension Font {
    /// Display style: medium weight, used with negative tracking.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
}

// MARK: - Reusable components

/// High-contrast pill: the primary CTA.
struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.onInverse)
            .padding(.horizontal, 24)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Theme.inversePressed : Theme.inverse, in: Capsule())
    }
}

/// Soft pill for secondary actions.
struct SoftPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Round icon in the transport colour.
struct ModeBadge: View {
    let mode: TransportMode
    var size: CGFloat = 32
    var dimmed = false

    var body: some View {
        Image(systemName: mode.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(mode.color.opacity(dimmed ? 0.45 : 1), in: Circle())
            .overlay(Circle().stroke(Theme.canvas.opacity(0.7), lineWidth: 1.5))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.stone)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }
}
