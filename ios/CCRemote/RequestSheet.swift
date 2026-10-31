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

struct QuestionForm: View {
    let request: PendingRequest
    let done: () -> Void
    @Environment(BridgeClient.self) private var client
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var questions: [Question] { request.questions ?? [] }

    private func answer(for q: Question) -> String? {
        let custom = other[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let chosen = q.options.map(\.label).filter { picks[q.question]?.contains($0) == true }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { answer(for: $0) != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(questions) { q in
                    VStack(alignment: .leading, spacing: 10) {
                        if let h = q.header {
                            Text(h.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                        }
                        Text(q.question).font(.title3.weight(.semibold))
                        if q.multiSelect == true {
                            Text("Choose any").font(.caption).foregroundStyle(Theme.secondary)
                        }
                        ForEach(q.options, id: \.label) { o in
                            optionButton(q, o)
                        }
                        TextField("Other…", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }), axis: .vertical)
                            .lineLimit(1...4)
                            .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button("Send answer") {
                    var out: [String: String] = [:]
                    for q in questions { out[q.question] = answer(for: q) }
                    client.answer(request, answers: out)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    done()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!complete).opacity(complete ? 1 : 0.5)
                Button("Answer on the Mac instead") { client.answerOnMac(request); done() }
                    .font(.subheadline).frame(maxWidth: .infinity)
            }
            .padding(20)
        }
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
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: q.multiSelect == true ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Theme.accent : Theme.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(o.label).font(.body.weight(.semibold))
                    if let d = o.description { Text(d).font(.caption).foregroundStyle(Theme.secondary) }
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
