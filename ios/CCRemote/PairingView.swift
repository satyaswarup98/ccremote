import SwiftUI

struct PairingView: View {
    // Set when shown as the "Add another Mac" sheet; called after pairing succeeds.
    var onPaired: (() -> Void)? = nil
    @Environment(BridgeClient.self) private var client
    @State private var discovery = Discovery()
    @State private var selected: Discovery.Found?
    @State private var manualHost = ""
    @State private var showManual = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    private var target: (host: String, port: Int)? {
        if showManual {
            let parts = manualHost.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard let h = parts.first, !h.isEmpty else { return nil }
            return (String(h), parts.count > 1 ? Int(parts[1]) ?? 8787 : 8787)
        }
        if let s = selected { return (s.host, s.port) }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                howTo
                macPicker
                if target != nil { codeEntry.transition(.opacity.combined(with: .move(edge: .bottom))) }
                VersionFooter().padding(.top, 8)
            }
            .padding(24)
            .animation(.snappy, value: target != nil)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.found) { _, found in
            // Pre-select the only Mac, but leave the keyboard down until the code boxes are tapped.
            if selected == nil, found.count == 1 { selected = found.first }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppGlyph(size: 56)
            Text("CC Remote").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Your Claude Code sessions, in your pocket.")
                .font(.body).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 20)
    }

    private var macPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR MAC").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                if discovery.found.isEmpty && !showManual { ProgressView().controlSize(.small) }
            }
            ForEach(discovery.found) { mac in
                Button {
                    selected = mac; showManual = false; codeFocused = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(.headline)
                            Text("\(mac.host):\(String(mac.port))").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: selected == mac && !showManual ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected == mac && !showManual ? Theme.accent : Theme.secondary)
                    }
                    .padding(16)
                    .glassPanel(cornerRadius: 18, tint: selected == mac && !showManual ? Theme.accent.opacity(0.3) : nil, interactive: true)
                }
                .buttonStyle(.plain)
            }
            if discovery.found.isEmpty && !showManual {
                Text("Looking for your Mac on this Wi-Fi…").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            if showManual {
                TextField("192.168.1.20 or Tailscale IP", text: $manualHost)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(14)
                    .glassPanel(cornerRadius: 16, tint: Theme.accent.opacity(0.2))
            }
            Button(showManual ? "Use a discovered Mac" : "Enter address manually") {
                showManual.toggle()
            }
            .font(.subheadline.weight(.medium))
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PAIRING CODE").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .opacity(0.02)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        // Clearing the boxes after a failure must not hide the failure message.
                        if !digits.isEmpty { error = nil }
                        if digits.count == 6 { submit() }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        digitBox(i)
                        if i == 2 { Spacer().frame(width: 6) }
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Theme.red)
            }
            Button(action: submit) {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Pairing…" : "Pair")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(code.count != 6 || busy)
            .opacity(code.count == 6 ? 1 : 0.5)
        }
    }

    private func digitBox(_ i: Int) -> some View {
        let chars = Array(code)
        let filled = i < chars.count
        let current = i == chars.count && codeFocused
        return Text(filled ? String(chars[i]) : "")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .glassPanel(cornerRadius: 14, tint: current ? Theme.accent.opacity(0.35) : (error != nil ? Theme.red.opacity(0.3) : nil))
    }

    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash"

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up your Mac").font(.headline)
                Text("Paste in Terminal on your Mac").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            CommandBox(command: Self.installCommand)
            Text("Installs or updates CC Remote, then shows a 6-digit code.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 22)
    }

    private func submit() {
        guard let t = target, code.count == 6, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await client.pair(host: t.host, port: t.port, code: code)
                onPaired?()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the Mac: \(error.localizedDescription)"
                code = ""
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            busy = false
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xE58A6B), Color(hex: 0xC4613F)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.36, weight: .heavy))
                .offset(x: -size * 0.12)
            RoundedRectangle(cornerRadius: 2)
                .frame(width: size * 0.24, height: size * 0.07)
                .offset(x: size * 0.16, y: size * 0.15)
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
    }
}

// Terminal-style command with a small copy button in the corner.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.styled(command))
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.snappy) { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.8)); withAnimation(.snappy) { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(copied ? Theme.green : Theme.text)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(12)
        .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    // "$ " prompt in orange, command in terminal white.
    static func styled(_ cmd: String) -> AttributedString {
        var prompt = AttributedString("$ ")
        prompt.foregroundColor = Theme.accent
        var body = AttributedString(cmd)
        body.foregroundColor = Theme.terminalText
        return prompt + body
    }
}
