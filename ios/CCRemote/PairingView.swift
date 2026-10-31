import SwiftUI

struct PairingView: View {
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
                macPicker
                if target != nil { codeEntry.transition(.opacity.combined(with: .move(edge: .bottom))) }
                howTo
            }
            .padding(24)
            .animation(.snappy, value: target != nil)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.found) { _, found in
            if selected == nil, found.count == 1 { selected = found.first; codeFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppGlyph(size: 64)
            Text("CC Remote").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Approve prompts, answer Claude, and keep your Claude Code sessions moving from your iPhone.")
                .font(.body).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 24)
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
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(selected == mac && !showManual ? Theme.accent : Theme.stroke, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            if discovery.found.isEmpty && !showManual {
                Text("Looking for Macs on this Wi-Fi…").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            if showManual {
                TextField("192.168.1.20 or Tailscale IP", text: $manualHost)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(current ? Theme.accent : (error != nil ? Theme.red.opacity(0.6) : Theme.stroke), lineWidth: current ? 2 : 1))
    }

    private var howTo: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("On your Mac, run", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Text("ccr pair")
                    .font(.body.monospaced().weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Theme.accent)
                Text("It shows a 6-digit code valid for 5 minutes. Your iPhone and Mac need to be on the same Wi-Fi (or both on Tailscale).")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func submit() {
        guard let t = target, code.count == 6, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await client.pair(host: t.host, port: t.port, code: code)
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
