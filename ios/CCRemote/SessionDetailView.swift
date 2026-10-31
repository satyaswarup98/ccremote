import SwiftUI

struct SessionDetailView: View {
    let sessionId: String
    @Environment(BridgeClient.self) private var client
    @State private var tab = Tab.chat
    @State private var draft = ""
    @State private var activeRequest: PendingRequest?
    @AppStorage("terminalFontSize") private var fontSize: Double = 9.5
    @FocusState private var composerFocused: Bool

    private func deliver(_ text: String, mode: BridgeClient.SendMode) {
        client.sendText(text, to: sessionId, mode: mode)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Dictation can write its text back into the field after we clear it, so end editing first
        // (which stops dictation), clear, and clear again once the keyboard has settled.
        composerFocused = false
        hideKeyboard()
        draft = ""
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if draft == text || text.hasPrefix(draft.trimmingCharacters(in: .whitespacesAndNewlines)) { draft = "" }
        }
    }

    enum Tab { case chat, terminal }

    private var session: SessionInfo? { client.session(sessionId) }

    var body: some View {
        VStack(spacing: 0) {
            if let s = session {
                if s.hasMirror {
                    Picker("", selection: $tab) {
                        Text("Chat").tag(Tab.chat)
                        Text("Terminal").tag(Tab.terminal)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
                ForEach(client.pending(for: sessionId)) { req in
                    Button { activeRequest = req } label: { PendingRow(req: req) }
                        .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if tab == .terminal && s.hasMirror {
                    TerminalMirror(text: client.screen, fontSize: fontSize)
                    KeyBar(sessionId: sessionId, fontSize: $fontSize)
                } else {
                    ChatTranscript(items: client.items, session: s)
                }
                Composer(session: s, draft: $draft, focused: $composerFocused) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    // The Mac decides: reply to a waiting turn, type into the terminal or VS Code, or queue.
                    deliver(text, mode: .auto)
                }
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.folder",
                                       description: Text("It may have ended, or the bridge restarted."))
            }
        }
        .appBackground()
        .navigationTitle(session?.project ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let s = session {
                ToolbarItem(placement: .principal) { SessionTitle(session: s) }
                if s.queued > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear \(s.queued) queued", role: .destructive) { client.clearQueue(s.id) }
                        } label: { Image(systemName: "tray.full").foregroundStyle(Theme.amber) }
                    }
                }
            }
        }
        .onAppear {
            client.subscribe(sessionId)
            if session?.hasMirror == true && session?.isVSCode == false { tab = .terminal }
        }
        .onDisappear { client.unsubscribe(sessionId) }
        .sheet(item: $activeRequest) { req in RequestSheet(request: req) }
    }
}

/// The session's name with a readable status line under it, centred in the navigation bar.
struct SessionTitle: View {
    let session: SessionInfo

    var body: some View {
        VStack(spacing: 1) {
            Text(session.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(Theme.color(for: session.status)).frame(width: 6, height: 6)
                    .modifier(Pulse(active: session.status == .working || session.status.needsYou))
                Text(detail).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [session.project, Self.statusText(session.status)]
        if let mode = session.permissionMode, mode != "default" { parts.append(Self.modeText(mode)) }
        if session.queued > 0 { parts.append("\(session.queued) queued") }
        return parts.joined(separator: " · ")
    }

    static func statusText(_ s: SessionStatus) -> String {
        switch s {
        case .working: "Working"
        case .idle: "Idle"
        case .ended: "Ended"
        case .needsPermission: "Needs your approval"
        case .needsAnswer: "Has a question"
        case .waitingInput: "Waiting for your reply"
        case .unknown: ""
        }
    }

    static func modeText(_ mode: String) -> String {
        switch mode {
        case "auto": "Auto mode"
        case "plan": "Plan mode"
        case "acceptEdits": "Accepting edits"
        case "bypassPermissions": "Bypassing permissions"
        case "dontAsk": "Don't ask"
        default: mode
        }
    }
}

// MARK: Chat

struct ChatTranscript: View {
    let items: [TranscriptItem]
    let session: SessionInfo
    @Environment(BridgeClient.self) private var client

    private var results: [String: TranscriptItem] {
        Dictionary(items.filter { $0.kind == "result" }.compactMap { i in i.toolUseId.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        Text(session.lastMessage ?? "Waiting for activity…")
                            .font(.subheadline).foregroundStyle(Theme.secondary).padding(.top, 30)
                            .frame(maxWidth: .infinity)
                    }
                    let res = results
                    ForEach(items.filter { $0.kind != "result" }) { item in
                        switch item.kind {
                        case "user": UserBubble(text: item.text ?? "", fromPhone: item.fromPhone ?? false)
                        case "assistant": AssistantBlock(text: item.text ?? "")
                        case "tool": ToolRow(item: item, result: item.toolUseId.flatMap { res[$0] })
                        default: EmptyView()
                        }
                    }
                    ForEach(client.outgoing(for: session.id)) { o in
                        OutgoingBubble(item: o)
                    }
                    if session.status == .working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.activity ?? "Working…").font(.caption.monospaced()).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { hideKeyboard() }
            .onChange(of: items.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: client.outgoing.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
}

struct UserBubble: View {
    let text: String
    var fromPhone = false
    var body: some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassPanel(cornerRadius: 22, tint: Theme.accent.opacity(0.35))
                if fromPhone {
                    Label("sent from phone", systemImage: "iphone")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// Your message, shown the moment you send it, with what happened to it underneath.
struct OutgoingBubble: View {
    let item: BridgeClient.Outgoing
    @Environment(BridgeClient.self) private var client

    var body: some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.text)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassPanel(cornerRadius: 22, tint: Theme.accent.opacity(item.status == .failed ? 0.15 : 0.35))
                    .opacity(item.status == .sending ? 0.75 : 1)
                status
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .sending:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Sending…") }
                .font(.caption2).foregroundStyle(Theme.secondary)
        case .sent:
            Label("Sent", systemImage: "checkmark").font(.caption2).foregroundStyle(Theme.secondary)
        case .queued:
            VStack(alignment: .trailing, spacing: 4) {
                Label(item.note ?? "Queued", systemImage: "clock").font(.caption2).foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.trailing)
                copyButton.font(.caption.weight(.semibold))
            }
        case .failed:
            VStack(alignment: .trailing, spacing: 4) {
                if let n = item.note { Text(n).font(.caption2).foregroundStyle(Theme.red).multilineTextAlignment(.trailing) }
                HStack(spacing: 14) {
                    Button("Dismiss") { client.dismissOutgoing(item) }.foregroundStyle(Theme.secondary)
                    copyButton
                    Button { client.retry(item) } label: { Label("Retry", systemImage: "arrow.clockwise") }.foregroundStyle(Theme.accent)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    // Only for messages that didn't get through: copy it to paste on the Mac yourself (Universal Clipboard).
    @State private var copied = false
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = item.text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .foregroundStyle(copied ? Theme.green : Theme.text)
    }
}

struct AssistantBlock: View {
    let text: String
    var body: some View { MarkdownView(text: text) }
}

struct ToolRow: View {
    let item: TranscriptItem
    let result: TranscriptItem?
    @State private var expanded = false

    private var icon: String {
        switch item.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "AskUserQuestion": "questionmark.bubble"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.caption).frame(width: 16)
                    Text(item.name ?? "Tool").font(.caption.weight(.semibold))
                    Text(item.summary ?? "").font(.caption.monospaced()).lineLimit(1).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 4)
                    if result?.isError == true {
                        Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(Theme.red)
                    } else if result != nil {
                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(Theme.green)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .foregroundStyle(Theme.text.opacity(0.8))
            }
            .buttonStyle(.plain)
            if expanded, let r = result?.text, !r.isEmpty {
                Text(r).font(.caption2.monospaced()).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassPanel(cornerRadius: 16)
    }
}

// MARK: Terminal

struct TerminalMirror: View {
    let text: String
    let fontSize: Double

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? AttributedString("Connecting to terminal…") : ANSI.render(text, fontSize: fontSize))
                        .font(.system(size: fontSize, design: .monospaced))
                        .lineSpacing(1)
                        .fixedSize()
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .defaultScrollAnchor(.bottomLeading)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { hideKeyboard() }
            .background(Theme.terminalBackground)
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottomLeading) }
        }
    }
}

struct KeyBar: View {
    let sessionId: String
    @Binding var fontSize: Double
    @Environment(BridgeClient.self) private var client

    private let keys: [(label: String, key: String)] = [
        ("esc", "esc"), ("1", "1"), ("2", "2"), ("3", "3"), ("↑", "up"), ("↓", "down"),
        ("⏎", "enter"), ("⇧⇥", "btab"), ("tab", "tab"), ("⌃C", "ctrlc"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.key) { k in
                    Button {
                        client.sendKeys([k.key], to: sessionId)
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    } label: {
                        Text(k.label).font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 38, minHeight: 34)
                            .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 24)
                Button { fontSize = max(6, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller").frame(width: 34, height: 34) }
                Button { fontSize = min(16, fontSize + 1) } label: { Image(systemName: "textformat.size.larger").frame(width: 34, height: 34) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

// MARK: Composer

struct Composer: View {
    let session: SessionInfo
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var hint: String {
        if session.status == .ended { return "Session ended" }
        if session.holdingForPhone { return "Reply to Claude…" }
        if session.hasMirror { return "Type into the terminal…" }
        if session.entrypoint == "phone" { return "Message Claude…" }
        if session.isVSCode { return "Message Claude (sent into VS Code)…" }
        if session.status == .working { return "Queue a message for when Claude stops…" }
        return "Message Claude…"
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(hint, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.horizontal, 18).padding(.vertical, 13)
                .glassEffect(session.holdingForPhone ? .clear.tint(Theme.accent.opacity(0.25)).interactive() : .clear.interactive(),
                             in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .disabled(session.status == .ended)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.white)
                    .glassEffect(draft.isEmpty ? .clear.interactive() : .clear.tint(Theme.accent.opacity(0.9)).interactive(), in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.status == .ended)
        }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .animation(.snappy, value: focused.wrappedValue)
    }
}

// Resigns whichever text field is active (composer, deny reason, "Other…" answers).
@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct KeyboardDismissToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { hideKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }
            }
        }
    }
}
