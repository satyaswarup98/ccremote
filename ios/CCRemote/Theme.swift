import SwiftUI

enum Theme {
    static let accent = Color(hex: 0xD97757)        // Claude orange
    static let background = Color(hex: 0x141413)
    static let card = Color(hex: 0x1F1E1C)
    static let cardRaised = Color(hex: 0x2A2926)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color(hex: 0xF5F4EE)
    static let secondary = Color(hex: 0xA8A69E)
    static let terminalBackground = Color(hex: 0x0D0D0C)
    static let terminalText = Color(hex: 0xE6E4DC)
    static let green = Color(hex: 0x7BC47F)
    static let red = Color(hex: 0xE5675B)
    static let amber = Color(hex: 0xE8B04B)
    static let blue = Color(hex: 0x7AA7F0)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .working: blue
        case .needsPermission, .needsAnswer: accent
        case .waitingInput: amber
        case .idle: green
        case .ended, .unknown: secondary
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct StatusPill: View {
    let status: SessionStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(for: status)).frame(width: 7, height: 7)
                .modifier(Pulse(active: status == .working || status.needsYou))
            Text(status.label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.color(for: status))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.color(for: status).opacity(0.14), in: Capsule())
    }
}

struct Pulse: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active && on ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever() : .default, value: on)
            .onAppear { on = true }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.cardRaised.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(color)
    }
}

// "CC Remote 1.0 · build 58 (03728ba) · built 31 Oct 12:40"
enum AppVersion {
    static var line: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "CC Remote \(v) · build \(BuildInfo.number) (\(BuildInfo.commit)) · built \(BuildInfo.built)"
    }
}

struct VersionFooter: View {
    var body: some View {
        Text(AppVersion.line)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.secondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
    }
}
