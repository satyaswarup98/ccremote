import SwiftUI

struct SessionsView: View {
    @Environment(BridgeClient.self) private var client
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showNew = false
    @State private var activeRequest: PendingRequest?

    private var active: [SessionInfo] { client.sessions.filter { $0.status != .ended } }
    private var ended: [SessionInfo] { client.sessions.filter { $0.status == .ended } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConnectionBanner()
                    AwayCard()
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
                    if !ended.isEmpty {
                        section("RECENTLY ENDED")
                        ForEach(ended) { s in
                            NavigationLink(value: s.id) { SessionRow(session: s) }.buttonStyle(.plain).opacity(0.6)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
                .animation(.snappy, value: client.sessions.map(\.status))
            }
            .background(Theme.background)
            .refreshable { client.connect() }
            .navigationTitle(client.pairing?.macName ?? "CC Remote")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .disabled(client.connection != .connected)
                }
            }
            .navigationDestination(for: String.self) { id in SessionDetailView(sessionId: id) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNew) { NewSessionSheet() }
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
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AwayCard: View {
    @Environment(BridgeClient.self) private var client

    var body: some View {
        let away = client.state?.away ?? false
        let mode = client.state?.awayMode ?? "auto"
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: away ? "iphone.radiowaves.left.and.right" : "laptopcomputer")
                        .font(.title3)
                        .foregroundStyle(away ? Theme.accent : Theme.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(away ? "Phone is in control" : "You're at the Mac")
                            .font(.headline)
                        Text(away
                             ? "Prompts and finished turns wait here for you."
                             : "Prompts appear on the Mac; you get a heads-up here.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Picker("Away mode", selection: Binding(get: { mode }, set: { client.setAway($0) })) {
                    Text("Auto").tag("auto")
                    Text("Phone").tag("on")
                    Text("Mac").tag("off")
                }
                .pickerStyle(.segmented)
                if mode == "auto" {
                    Text("Auto switches to the phone after \(String((client.state?.idleThresholdSec ?? 120) / 60)) min without keyboard or mouse on the Mac, and back when you touch it.")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
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
        .padding(16)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.5)))
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
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
        Text(session.hasMirror ? "TERMINAL" : (session.isVSCode ? "VS CODE" : "CLI"))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.cardRaised, in: Capsule())
            .foregroundStyle(Theme.secondary)
    }
}

struct NewSessionSheet: View {
    @Environment(BridgeClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("/Users/you/project", text: $custom)
                        .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Start Claude here") { start(custom) }.disabled(!custom.hasPrefix("/"))
                } header: { Text("Folder on the Mac") }
                Section {
                    ForEach(client.recentDirs, id: \.self) { dir in
                        Button { start(dir) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((dir as NSString).lastPathComponent).font(.headline).foregroundStyle(Theme.text)
                                Text(dir).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                } header: { Text("Recent projects") } footer: {
                    Text("Starts `claude` in a new tmux session on the Mac, so you also get the live terminal view. Attach on the Mac with `tmux attach`.")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .modifier(KeyboardDismissToolbar())
            .background(Theme.background)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { client.loadRecentDirs() }
        .presentationDetents([.medium, .large])
    }

    private func start(_ dir: String) {
        client.newSession(cwd: dir)
        dismiss()
    }
}
