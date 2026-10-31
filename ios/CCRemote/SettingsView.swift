import SwiftUI

struct SettingsView: View {
    @Environment(BridgeClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var host = ""
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if let p = client.pairing {
                    Section("Mac") {
                        LabeledContent("Name", value: p.macName)
                        LabeledContent("Status", value: statusText)
                        LabeledContent("Security code") { Text(p.securityCode).font(.body.monospaced()) }
                        HStack {
                            TextField("Address", text: $host).font(.body.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            if host != "\(p.host):\(p.port)" {
                                Button("Save") {
                                    let parts = host.split(separator: ":")
                                    if let h = parts.first {
                                        client.updateHost(String(h), port: parts.count > 1 ? Int(parts[1]) ?? p.port : p.port)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    if let topic = client.state?.ntfyTopic {
                        Button {
                            openURL(URL(string: "ntfy://ntfy.sh/\(topic)")!) { ok in
                                if !ok { openURL(URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!) }
                            }
                        } label: {
                            Label("Subscribe in ntfy", systemImage: "bell.badge")
                        }
                        LabeledContent("Topic") {
                            Text(topic).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Copy topic") { UIPasteboard.general.string = topic }
                    } else {
                        Text("Connect to the Mac to set up notifications.").foregroundStyle(Theme.secondary)
                    }
                } header: {
                    Text("Notifications when the app is closed")
                } footer: {
                    Text("Apple only lets paid developer accounts send real push notifications, so the bridge sends them through the free ntfy app. Install ntfy from the App Store, subscribe to this topic, and allow its notifications. Tapping one opens CC Remote on that session. Messages go through ntfy.sh; the topic is random and unguessable. While CC Remote is open, it alerts you itself.")
                }

                Section {
                    Text("• Phone: prompts wait for you here; finished turns wait about 14 min for your reply.\n• Mac: everything shows on the Mac; the phone only gets a heads-up.\n• Auto: Phone after 2 min with no keyboard or mouse input, back to Mac when you touch it.")
                        .font(.footnote).foregroundStyle(Theme.secondary)
                } header: { Text("Away mode") }

                Section {
                    Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("To revoke from the Mac instead: ccr unpair all")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .modifier(KeyboardDismissToolbar())
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair from \(client.pairing?.macName ?? "Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { client.unpair(); dismiss() }
            }
            .onAppear { if let p = client.pairing { host = "\(p.host):\(p.port)" } }
        }
    }

    private var statusText: String {
        switch client.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .failed: "Can't connect"
        }
    }
}
