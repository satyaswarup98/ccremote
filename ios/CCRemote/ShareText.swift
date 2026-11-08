import SwiftUI
import UIKit

// Turns Claude's Markdown reply into text that looks right when pasted into WhatsApp (and reads fine in
// Messages, Notes, mail): WhatsApp uses *bold*, _italic_, ~strike~, `code` and ``` blocks, and has no tables.
enum ShareText {
    static func whatsApp(_ markdown: String) -> String {
        var out: [String] = []
        for block in Markdown.parse(markdown) {
            switch block {
            case .heading(_, let t): out.append("*\(plain(inline(t), keepStyles: false))*")
            case .paragraph(let t): out.append(inline(t))
            case .bullet(let indent, let t): out.append(String(repeating: "   ", count: indent) + "• " + inline(t))
            case .ordered(let indent, let n, let t): out.append(String(repeating: "   ", count: indent) + "\(n). " + inline(t))
            case .quote(let t): out.append(t.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + inline(String($0)) }.joined(separator: "\n"))
            case .code(let t): out.append("```\n\(t)\n```")
            case .table(let header, let rows): out.append(table(header, rows))
            case .rule: out.append("———")
            }
        }
        // Consecutive list items stay together; other blocks get a blank line between them.
        var text = ""
        for (i, piece) in out.enumerated() {
            if i > 0 {
                let isItem: (String) -> Bool = { $0.hasPrefix("• ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("• ") || $0.range(of: #"^\s*\d+\. "#, options: .regularExpression) != nil }
                text += (isItem(piece) && isItem(out[i - 1])) ? "\n" : "\n\n"
            }
            text += piece
        }
        return text
    }

    // **bold**/__bold__ → *bold*, *italic*/_italic_ → _italic_, ~~strike~~ → ~strike~, [text](url) → text (url).
    static func inline(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)"),
            (#"\*\*(.+?)\*\*"#, "\u{1}$1\u{1}"),
            (#"__(.+?)__"#, "\u{1}$1\u{1}"),
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "_$1_"),
            (#"~~(.+?)~~"#, "~$1~"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t.replacingOccurrences(of: "\u{1}", with: "*")
    }

    /// Text without any WhatsApp style marks, for measuring and for table cells.
    static func plain(_ s: String, keepStyles: Bool) -> String {
        keepStyles ? s : s.replacingOccurrences(of: #"[*_~`]"#, with: "", options: .regularExpression)
    }

    // Small tables become an aligned monospace block; wider ones become one block per row,
    // which reads far better on a phone than a wrapped grid.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let cells = ([header] + rows).map { $0.map { plain(inline($0), keepStyles: false) } }
        let widths = header.indices.map { c in cells.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        let total = widths.reduce(0, +) + 3 * max(0, widths.count - 1)
        if total <= 38 {
            func line(_ r: [String]) -> String {
                header.indices.map { c in
                    let v = c < r.count ? r[c] : ""
                    return v.padding(toLength: widths[c], withPad: " ", startingAt: 0)
                }.joined(separator: " │ ").trimmingCharacters(in: .whitespaces)
            }
            let sep = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")
            return "```\n" + ([line(cells[0]), sep] + cells.dropFirst().map(line)).joined(separator: "\n") + "\n```"
        }
        let heads = header.map { plain(inline($0), keepStyles: false) }
        return rows.map { r in
            header.indices.map { c in "*\(heads[c]):* \(c < r.count ? inline(r[c]) : "")" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Copy / Share row under each of Claude's replies.
struct ReplyActions: View {
    let markdown: String
    @State private var copied = false

    private var shareText: String { ShareText.whatsApp(markdown) }

    var body: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = shareText
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .foregroundStyle(copied ? Theme.green : Theme.secondary)
            ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                .foregroundStyle(Theme.secondary)
        }
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
        .padding(.top, 2)
    }
}
