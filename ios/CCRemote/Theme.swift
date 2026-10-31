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

// MARK: Liquid Glass (iOS 26+)

extension View {
    /// A frosted glass panel; `tint` colours it slightly (e.g. orange for things that need you).
    func glassPanel(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The app's background: dark, with soft colour glows for the glass to refract.
    func appBackground() -> some View { background(AppBackground()) }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            Circle().fill(Theme.accent.opacity(0.32)).frame(width: 420).blur(radius: 130).offset(x: -150, y: -320)
            Circle().fill(Theme.blue.opacity(0.18)).frame(width: 380).blur(radius: 140).offset(x: 170, y: 120)
            Circle().fill(Theme.accent.opacity(0.14)).frame(width: 360).blur(radius: 150).offset(x: -60, y: 520)
        }
        .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(tint: tint)
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
        .glassEffect(.regular.tint(Theme.color(for: status).opacity(0.25)), in: Capsule())
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

/// Main action: tinted, interactive glass.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(color.opacity(configuration.isPressed ? 0.6 : 0.85)).interactive(),
                         in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Secondary action: clear glass.
struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(color)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
