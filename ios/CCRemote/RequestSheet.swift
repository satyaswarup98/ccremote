import SwiftUI

struct RequestSheet: View {
    let request: PendingRequest
    @Environment(BridgeClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    // The sheet closes itself once the request is answered anywhere (phone, Mac, or timeout).
    private var stillPending: Bool { client.pending.contains { $0.id == request.id } }

    var body: some View {
        NavigationStack {
            Group {
                if request.isQuestion {
                    QuestionForm(request: request) { dismiss() }
                } else {
                    PermissionForm(request: request) { dismiss() }
                }
            }
            .appBackground()
            .scrollDismissesKeyboard(.interactively)
            .modifier(KeyboardDismissToolbar())
            .navigationTitle(request.project)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
        .onChange(of: stillPending) { _, pending in if !pending { dismiss() } }
    }
}

struct PermissionForm: View {
    let request: PendingRequest
    let done: () -> Void
    @Environment(BridgeClient.self) private var client
    @State private var denyReason = ""
    @State private var showDeny = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("Claude wants to use").font(.subheadline).foregroundStyle(Theme.secondary)
                        Text(request.toolName ?? "a tool").font(.title2.weight(.bold))
                    }
                }
                DetailView(detail: request.detail, fallback: request.summary)

                if request.canAnswerFromPhone {
                    VStack(spacing: 12) {
                        Button("Allow") { act { client.allow(request) } }.buttonStyle(PrimaryButtonStyle(color: Theme.green.opacity(0.85)))
                        ForEach(request.suggestions ?? []) { s in
                            Button(s.label) { act { client.allow(request, suggestion: s.index) } }
                                .buttonStyle(SecondaryButtonStyle()).multilineTextAlignment(.center)
                        }
                        if showDeny {
                            TextField("Tell Claude what to do instead (optional)", text: $denyReason, axis: .vertical)
                                .lineLimit(1...4)
                                .padding(12).glassPanel(cornerRadius: 14)
                            HStack(spacing: 10) {
                                Button("Deny") { act { client.deny(request, message: denyReason) } }
                                    .buttonStyle(SecondaryButtonStyle(color: Theme.red))
                                Button("Deny & stop") { act { client.deny(request, message: denyReason, interrupt: true) } }
                                    .buttonStyle(SecondaryButtonStyle(color: Theme.red))
                            }
                        } else {
                            Button("Deny…") { withAnimation { showDeny = true } }.buttonStyle(SecondaryButtonStyle(color: Theme.red))
                        }
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Waiting on the Mac", systemImage: "laptopcomputer").font(.headline)
                            Text("This prompt can only be answered on the Mac.")
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func act(_ f: () -> Void) {
        f()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        done()
    }
}

struct DetailView: View {
    let detail: PermissionDetail?
    let fallback: String?

    var body: some View {
        switch detail?.type {
        case "command":
            VStack(alignment: .leading, spacing: 8) {
                if let d = detail?.description { Text(d).font(.subheadline).foregroundStyle(Theme.secondary) }
                code(detail?.text ?? "", prefix: "$ ")
            }
        case "diff":
            VStack(alignment: .leading, spacing: 8) {
                fileLabel(detail?.file)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines(detail?.old).enumerated()), id: \.offset) { _, l in diffLine("-", l, Theme.red) }
                        ForEach(Array(lines(detail?.new).enumerated()), id: \.offset) { _, l in diffLine("+", l, Theme.green) }
                    }
                    .padding(.vertical, 8)
                }
                .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 12))
            }
        case "file":
            VStack(alignment: .leading, spacing: 8) {
                fileLabel(detail?.file)
                code(detail?.text ?? "")
            }
        case "plan":
            Card { MarkdownView(text: detail?.text ?? "") }
        default:
            code(detail?.text ?? fallback ?? "")
        }
    }

    private func lines(_ s: String?) -> [Substring] {
        guard let s, !s.isEmpty else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private func fileLabel(_ f: String?) -> some View {
        Label((f as NSString?)?.lastPathComponent ?? "file", systemImage: "doc")
            .font(.subheadline.monospaced().weight(.semibold))
    }

    private func diffLine(_ sign: String, _ l: Substring, _ c: Color) -> some View {
        Text("\(sign) \(l)").font(.caption.monospaced())
            .padding(.horizontal, 10).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.opacity(0.12))
            .foregroundStyle(c)
    }

    private func code(_ s: String, prefix: String = "") -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(prefix + s).font(.callout.monospaced()).textSelection(.enabled).padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

// Claude's questions one page at a time, like VS Code: tabs on top (✓ when answered, Submit last),
// Back / Next at the bottom. Picking an option on a single-choice question moves on by itself.
struct QuestionForm: View {
    let request: PendingRequest
    let done: () -> Void
    @Environment(BridgeClient.self) private var client
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var page = 0
    @FocusState private var otherFocused: Bool
    // Demo/preview only: open on a given page with some options already picked.
    var startPage = 0
    var presetPicks: [String: Set<String>] = [:]

    private var questions: [Question] { request.questions ?? [] }
    private var submitPage: Int { questions.count }
    private var onSubmitPage: Bool { page >= submitPage }

    private func answer(for q: Question) -> String? {
        let custom = other[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let chosen = q.options.map(\.label).filter { picks[q.question]?.contains($0) == true }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { answer(for: $0) != nil } }

    private func go(_ p: Int) {
        otherFocused = false
        withAnimation(.snappy) { page = max(0, min(p, submitPage)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider().overlay(Theme.stroke)
            ScrollView {
                Group {
                    if onSubmitPage { review } else { questionPage(questions[page]) }
                }
                .padding(.horizontal, 22).padding(.vertical, 22)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .onAppear { if picks.isEmpty { picks = presetPicks; page = startPage } }
    }

    // MARK: Tabs

    private var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                        tab(title: q.header ?? "Question \(i + 1)", done: answer(for: q) != nil, selected: page == i) { go(i) }
                            .id(i)
                    }
                    tab(title: "Submit", done: false, selected: onSubmitPage, icon: "paperplane.fill") { go(submitPage) }
                        .id(submitPage)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .onChange(of: page) { _, p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
    }

    private func tab(title: String, done: Bool, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(selected ? .white : Theme.green)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(selected ? .white : Theme.text)
            .glassEffect(selected ? .clear.tint(Theme.accent.opacity(0.85)).interactive() : .clear.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Pages

    private func questionPage(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Question \(page + 1) of \(questions.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(q.question).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(q.multiSelect == true ? "Choose one or more" : "Choose one")
                .font(.caption).foregroundStyle(Theme.secondary)
            ForEach(q.options, id: \.label) { o in optionButton(q, o) }
            TextField("Other…", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }), axis: .vertical)
                .lineLimit(1...4)
                .focused($otherFocused)
                .padding(16)
                .glassPanel(cornerRadius: 20, tint: (other[q.question] ?? "").isEmpty ? nil : Theme.accent.opacity(0.25))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(complete ? "Ready to send" : "Some questions still need an answer")
                .font(.title3.weight(.semibold))
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                Button { go(i) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: answer(for: q) == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(answer(for: q) == nil ? Theme.accent : Theme.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.header ?? "Question \(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                            Text(q.question).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                            Text(answer(for: q) ?? "Not answered. Tap to answer")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(answer(for: q) == nil ? Theme.accent : Theme.text)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .padding(18)
                    .glassPanel(cornerRadius: 22, interactive: true)
                }
                .buttonStyle(.plain)
            }
            Button("Answer on the Mac instead") { client.answerOnMac(request); done() }
                .font(.subheadline).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { go(page - 1) } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(page == 0).opacity(page == 0 ? 0.4 : 1)
            if onSubmitPage {
                Button {
                    var out: [String: String] = [:]
                    for q in questions { out[q.question] = answer(for: q) }
                    client.answer(request, answers: out)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    done()
                } label: { Label("Submit", systemImage: "paperplane.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!complete).opacity(complete ? 1 : 0.5)
            } else {
                Button { go(page + 1) } label: {
                    Label(page == submitPage - 1 ? "Review" : "Next", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
    }

    private func optionButton(_ q: Question, _ o: QuestionOption) -> some View {
        let on = picks[q.question]?.contains(o.label) == true
        return Button {
            var set = picks[q.question] ?? []
            if q.multiSelect == true {
                if on { set.remove(o.label) } else { set.insert(o.label) }
            } else {
                set = [o.label]
            }
            picks[q.question] = set
            other[q.question] = nil
            UISelectionFeedbackGenerator().selectionChanged()
            // Single choice: move on to the next question after a beat, like VS Code.
            if q.multiSelect != true {
                let here = page
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    if page == here { go(page + 1) }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: q.multiSelect == true ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Theme.accent : Theme.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(o.label).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                    if let d = o.description { Text(d).font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.leading) }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassPanel(cornerRadius: 22, tint: on ? Theme.accent.opacity(0.35) : nil, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

#if DEBUG
// Launch with CCR_DEMO=questions (and CCR_DEMO_PAGE=0…3) to see the question screen with sample questions.
enum QuestionDemo {
    static let request: PendingRequest = {
        let json = """
        {"id":"demo","kind":"question","sessionId":"demo","project":"insta_bot","createdAt":0,"answerable":true,
         "questions":[
          {"question":"Which database should the reels pipeline use?","header":"Database","multiSelect":false,
           "options":[{"label":"Postgres","description":"Reliable, good for analytics later"},
                      {"label":"SQLite","description":"Zero setup, one file"},
                      {"label":"Supabase","description":"Hosted Postgres with a dashboard"}]},
          {"question":"Which platforms should it post to?","header":"Platforms","multiSelect":true,
           "options":[{"label":"Instagram","description":"Reels"},{"label":"YouTube","description":"Shorts"},
                      {"label":"TikTok","description":null},{"label":"X","description":"Video posts"}]},
          {"question":"When should it run?","header":"Schedule","multiSelect":false,
           "options":[{"label":"Every morning","description":"7:00"},{"label":"Twice a day","description":"7:00 and 19:00"},
                      {"label":"Manually","description":"Only when you start it"}]}
         ]}
        """
        return try! JSONDecoder().decode(PendingRequest.self, from: Data(json.utf8))
    }()

    static var page: Int { Int(ProcessInfo.processInfo.environment["CCR_DEMO_PAGE"] ?? "0") ?? 0 }
    // Later pages show earlier questions as answered, like a real walk-through.
    static var picks: [String: Set<String>] {
        let qs = request.questions ?? []
        var out: [String: Set<String>] = [:]
        if page > 0 { out[qs[0].question] = ["Postgres"] }
        if page >= 1 { out[qs[1].question] = ["Instagram", "YouTube"] }
        if page > 2 { out[qs[2].question] = ["Every morning"] }
        return out
    }
}

struct TableDemoView: View {
    var body: some View {
        ScrollView {
            AssistantBlock(text: """
            Here's the comparison:

            | Option | What it does | Downside |
            |---|---|---|
            | Run now in a Terminal copy | Starts a copy of the conversation in Terminal with your message as the next prompt and runs it immediately with the full history | The original VS Code session doesn't see it, and the copy needs the folder trusted first |
            | Queue | Holds the message until Claude stops | Waits |
            | Send to VS Code | Types into the real chat | Needs the Mac unlocked and the chat visible in a window on the current desktop or in the Window menu |
            """)
            .padding(20)
            // What Copy / Share produces for WhatsApp:
            Text(ShareText.whatsApp("""
            ## Plan
            **Bold**, *italic* and `code`, see [docs](https://example.com).

            - one
            - two

            | City | Days |
            |---|---|
            | Penang | 3 |
            | Bali | 5 |
            """) + "\n\n— wide table —\n\n" + ShareText.whatsApp("""
            | Option | What it does | Downside |
            |---|---|---|
            | Queue | Holds the message until Claude stops | Waits |
            | Send to VS Code | Types into the real chat | Needs the Mac unlocked |
            """))
            .font(.caption.monospaced())
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
        }
        .appBackground()
    }
}

struct QuestionDemoView: View {
    var body: some View {
        NavigationStack {
            QuestionForm(request: QuestionDemo.request, done: {}, startPage: QuestionDemo.page, presetPicks: QuestionDemo.picks)
                .appBackground()
                .navigationTitle("insta_bot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") {} } }
        }
    }
}
#endif
