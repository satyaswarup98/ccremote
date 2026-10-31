import SwiftUI

struct SessionsView: View {
    @Environment(BridgeClient.self) private var client
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var showAddMac = false
    @State private var activeRequest: PendingRequest?

    private var active: [SessionInfo] { client.sessions.filter { $0.status != .ended } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ConnectionBanner()
                    if !client.pending.isEmpty {
                        section("NEEDS YOU")
                        ForEach(client.pending) { req in
                            Button { activeRequest = req } label: { PendingRow(req: req) }
                                .buttonStyle(.plain)
                        }
                    }
                    section("SESSIONS")
                    if active.isEmpty { emptyState }
                    ForEach(active) { s in
                        NavigationLink(value: s.id) { SessionRow(session: s) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
                .animation(.snappy, value: client.sessions.map(\.status))
            }
            .appBackground()
            .refreshable { client.connect() }
            .navigationTitle(client.pairing?.macName ?? "CC Remote")
            .toolbarTitleMenu {
                ForEach(client.pairings) { m in
                    Button { client.switchTo(m.id) } label: {
                        Label(m.macName, systemImage: m.id == client.pairing?.id ? "checkmark" : "laptopcomputer")
                    }
                }
                Divider()
                Button { showAddMac = true } label: { Label("Add another Mac…", systemImage: "plus") }
            }
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                // One item, so iOS keeps both icons visible instead of folding them into a "…" menu.
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        MacStatusButton()
                        Button { showNotifications = true } label: {
                            Image(systemName: client.hasUnreadNotifications ? "bell.badge" : "bell")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(client.hasUnreadNotifications ? Theme.accent : Theme.text, Theme.text)
                        }
                        .accessibilityLabel("Notification history")
                    }
                    .padding(.horizontal, 4)
                }
            }
            .navigationDestination(for: String.self) { id in SessionDetailView(sessionId: id) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNotifications) { NotificationsView() }
        .sheet(isPresented: $showAddMac) {
            PairingView(onPaired: { showAddMac = false })
                .appBackground()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $activeRequest) { req in RequestSheet(request: req) }
        .onChange(of: client.openSessionId) { _, id in
            guard let id else { return }
            client.openSessionId = nil
            if path.last != id { path = [id] }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.top, 6)
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("No sessions yet").font(.headline)
                Text("Sessions show up as soon as Claude Code does something: start, a prompt, or a tool call. Sessions started with `cc` in Terminal also get a live screen mirror.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct ConnectionBanner: View {
    @Environment(BridgeClient.self) private var client
    var body: some View {
        switch client.connection {
        case .connected:
            EmptyView()
        case .connecting:
            banner(icon: nil, text: "Connecting to \(client.pairing?.macName ?? "Mac")…", color: Theme.secondary)
        case .disconnected:
            banner(icon: "wifi.slash", text: "Disconnected", color: Theme.secondary)
        case .failed(let msg):
            banner(icon: "exclamationmark.triangle.fill", text: msg, color: Theme.amber)
        }
    }

    private func banner(icon: String?, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.small) }
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") { client.connect() }.font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(14)
        .glassPanel(cornerRadius: 14, tint: color.opacity(0.2))
    }
}

// The Mac's state as a toolbar icon; tap it for what that means. Away is automatic: when the Mac is
// locked or untouched for a couple of minutes, finished turns stay open for your phone reply.
struct MacStatusButton: View {
    @Environment(BridgeClient.self) private var client

    var body: some View {
        let locked = client.state?.locked ?? false
        let away = client.state?.away ?? false
        let connected = client.connection == .connected
        let (icon, color, title, detail): (String, Color, String, String) =
            !connected ? ("wifi.slash", Theme.secondary, "Not connected", "The Mac isn't reachable right now.")
            : locked ? ("lock.fill", Theme.accent, "Mac locked", "When Claude finishes, the turn waits for your reply here, and your reply goes straight in.")
            : away ? ("iphone", Theme.accent, "Mac idle", "Nobody has used the Mac for a while, so finished turns wait for your reply here.")
            : ("laptopcomputer", Theme.text, "You're at the Mac", "Finished turns end as usual. Messages from here are typed into VS Code.")
        Menu {
            Section(title) { Text(detail) }
        } label: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .accessibilityLabel(title)
    }
}

struct PendingRow: View {
    let req: PendingRequest
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: req.isQuestion ? "questionmark.bubble.fill" : "lock.shield.fill")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(req.isQuestion ? "Claude has a question" : "Allow \(req.toolName ?? "tool")?")
                    .font(.headline)
                Text(req.isQuestion ? (req.questions?.first?.question ?? "") : (req.summary ?? ""))
                    .font(.subheadline.monospaced()).foregroundStyle(Theme.secondary).lineLimit(2)
                Text(req.project).font(.caption).foregroundStyle(Theme.accent)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
        }
        .padding(20)
        .glassPanel(tint: Theme.accent.opacity(0.3), interactive: true)
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.project).font(.headline)
                    tag
                    Spacer()
                    StatusPill(status: session.status)
                }
                Text(session.displayTitle)
                    .font(.subheadline).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(2)
                if let a = session.activity, session.status == .working {
                    Label(a, systemImage: "gearshape.2")
                        .font(.caption.monospaced()).foregroundStyle(Theme.blue).lineLimit(1)
                } else if let m = session.lastMessage, session.status != .working {
                    Text(m).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                HStack {
                    if session.queued > 0 {
                        Label("\(session.queued) queued", systemImage: "tray.full").font(.caption2).foregroundStyle(Theme.amber)
                    }
                    Spacer()
                    Text(session.updatedDate, style: .relative).font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private var tag: some View {
        Text(session.entrypoint == "phone" ? "PHONE" : session.hasMirror ? "TERMINAL" : (session.isVSCode ? "VS CODE" : "CLI"))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .glassEffect(.clear, in: Capsule())
            .foregroundStyle(Theme.secondary)
    }
}

struct NotificationsView: View {
    @Environment(BridgeClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if client.notifications.isEmpty {
                    ContentUnavailableView("No notifications yet", systemImage: "bell",
                                           description: Text("Approvals, questions and finished tasks from \(client.pairing?.macName ?? "your Mac") show up here."))
                } else {
                    List(client.notifications) { n in
                        Button {
                            client.openSessionId = n.sessionId
                            dismiss()
                        } label: { NotificationRow(item: n, unread: n.at > client.notificationsSeenAt) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .appBackground()
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { client.loadNotifications() }
        .onDisappear { client.markNotificationsSeen() }
    }
}

struct NotificationRow: View {
    let item: NotificationItem
    let unread: Bool

    private var icon: (String, Color) {
        switch item.kind {
        case "permission": ("lock.shield.fill", Theme.accent)
        case "question": ("questionmark.bubble.fill", Theme.accent)
        case "stop", "waiting": ("hourglass", Theme.amber)
        case "done": ("checkmark.circle.fill", Theme.green)
        default: ("bell.fill", Theme.secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon.0).foregroundStyle(icon.1).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.subtitle).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(item.date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(Theme.secondary)
                    if unread { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                }
                Text(item.title).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(item.body).font(.footnote).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}
