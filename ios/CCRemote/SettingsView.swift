import SwiftUI

struct SettingsView: View {
    @Environment(BridgeClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var host = ""
    @State private var removing: Pairing?
    @State private var showAddMac = false

    var body: some View {
        NavigationStack {
            List {
                if let p = client.pairing {
                    Section("This Mac") {
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
                    if let ts = client.pairing?.tailscaleHost {
                        Label("On via Tailscale (\(ts))", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    } else {
                        Label("Wi-Fi only", systemImage: "wifi").foregroundStyle(Theme.secondary)
                        Button {
                            openURL(URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!)
                        } label: { Label("Get Tailscale for iPhone", systemImage: "arrow.down.app") }
                    }
                } header: {
                    Text("Remote access (mobile data)")
                } footer: {
                    Text(client.pairing?.tailscaleHost != nil
                         ? "Away from this Wi-Fi, CC Remote connects through Tailscale automatically. Keep Tailscale switched on on the iPhone."
                         : "To use CC Remote away from home: install Tailscale on the Mac and this iPhone and sign in to the same account on both. CC Remote picks it up by itself.")
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
                    ForEach(client.pairings) { m in
                        HStack {
                            Image(systemName: m.id == client.pairing?.id ? "checkmark.circle.fill" : "laptopcomputer")
                                .foregroundStyle(m.id == client.pairing?.id ? Theme.accent : Theme.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.macName)
                                Text("\(m.host):\(String(m.port))").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if m.id != client.pairing?.id {
                                Button("Switch") { client.switchTo(m.id); dismiss() }.font(.subheadline.weight(.semibold))
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = m }
                        }
                    }
                    Button { showAddMac = true } label: { Label("Add another Mac", systemImage: "plus") }
                } header: {
                    Text("Macs on this iPhone")
                } footer: {
                    Text("Swipe left on a Mac to remove it from this iPhone. To revoke this iPhone from a Mac instead, run on that Mac: ccr unpair all")
                }

                Section {
                } footer: {
                    VersionFooter().padding(.top, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .modifier(KeyboardDismissToolbar())
            .appBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove \(removing?.macName ?? "Mac") from this iPhone?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let m = removing { client.unpair(m.id) }
                    removing = nil
                    if client.pairing == nil { dismiss() }
                }
            }
            .sheet(isPresented: $showAddMac) {
                PairingView(onPaired: { showAddMac = false; dismiss() })
                    .appBackground()
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: client.pairing?.id) { _, _ in if let p = client.pairing { host = "\(p.host):\(p.port)" } }
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
