import SwiftUI

/// Colours, type and components shared by every screen. Dark by design: the
/// app is used in a car, often at night, over a dark map.
enum Theme {
    static let background = Color(red: 0.047, green: 0.067, blue: 0.082)
    static let surface = Color(red: 0.078, green: 0.106, blue: 0.125)
    static let raised = Color(red: 0.125, green: 0.157, blue: 0.180)
    static let stroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.67, green: 0.72, blue: 0.74)
    static let tertiaryText = Color(red: 0.47, green: 0.53, blue: 0.55)
    /// Brand and primary actions.
    static let accent = Color(red: 0.69, green: 0.96, blue: 0.39)
    /// The chosen route, as drawn on the map.
    static let route = Color(red: 0.20, green: 0.78, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.39, blue: 0.37)

    static let cardRadius: CGFloat = 28
    static let controlRadius: CGFloat = 16

    /// Colour for the typical position error in metres; amber from where the
    /// engine reports "Position uncertain".
    static func uncertainty(_ metres: Double) -> Color {
        if metres <= 45 {
            return accent
        }
        if metres <= 125 {
            return warning
        }
        return danger
    }
}

/// Kept for screens that predate `Theme`.
enum AppColors {
    static let background = Theme.background
    static let panel = Theme.surface
    static let accent = Theme.accent
    static let secondary = Theme.secondaryText
}

// MARK: - Containers

/// The floating card at the bottom of the map.
struct SheetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface.opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.stroke)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .foregroundStyle(Theme.primaryText)
    }
}

/// Eyebrow, title and optional explanation at the top of a card.
struct CardHeader: View {
    var eyebrow: String?
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small coloured capsule for a status value.
struct StatusPill: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary actions: a quiet filled button.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Tertiary actions: text only.
struct QuietButtonStyle: ButtonStyle {
    var color = Theme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(minHeight: 36)
    }
}

/// Round control floating over the map.
struct MapControlButton: View {
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Theme.background : Theme.primaryText)
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface.opacity(0.92)))
                        .background(.ultraThinMaterial, in: Circle())
                }
                .overlay(Circle().strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct MapControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.primaryText)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

// MARK: - Formatting

enum Format {
    static func distance(_ metres: Double) -> String {
        if metres < 1000 {
            return "\(Int((metres / 10).rounded() * 10)) m"
        }
        if metres < 100_000 {
            return String(format: "%.1f km", metres / 1000)
        }
        return "\(Int((metres / 1000).rounded())) km"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(max(1, minutes)) min"
        }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func arrival(after seconds: Double) -> String {
        return Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }
}
