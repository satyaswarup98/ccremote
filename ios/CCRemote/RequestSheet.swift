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
            .background(Theme.background)
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
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("Claude wants to use").font(.subheadline).foregroundStyle(Theme.secondary)
                        Text(request.toolName ?? "a tool").font(.title2.weight(.bold))
                    }
                }
                DetailView(detail: request.detail, fallback: request.summary)

                if request.canAnswerFromPhone {
                    VStack(spacing: 10) {
                        Button("Allow") { act { client.allow(request) } }.buttonStyle(PrimaryButtonStyle(color: Theme.green.opacity(0.85)))
                        ForEach(request.suggestions ?? []) { s in
                            Button(s.label) { act { client.allow(request, suggestion: s.index) } }
                                .buttonStyle(SecondaryButtonStyle()).multilineTextAlignment(.center)
                        }
                        if showDeny {
                            TextField("Tell Claude what to do instead (optional)", text: $denyReason, axis: .vertical)
                                .lineLimit(1...4)
                                .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
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
                            Text("You were at the Mac when this came in, so the prompt is showing there. Answer it on the Mac, or, for a Terminal session, use the 1/2/3 keys in the Terminal tab. Switch Away mode to Phone to answer future prompts here.")
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .padding(20)
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
                .padding(20)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
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
                .padding(.horizontal, 16).padding(.vertical, 10)
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
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.stroke))
            .foregroundStyle(selected ? .white : Theme.text)
        }
        .buttonStyle(.plain)
    }

    // MARK: Pages

    private func questionPage(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((other[q.question] ?? "").isEmpty ? Theme.stroke : Theme.accent))
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
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.background)
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
            .padding(14)
            .background(on ? Theme.accent.opacity(0.14) : Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Theme.accent : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}
