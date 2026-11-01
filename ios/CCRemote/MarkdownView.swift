import SwiftUI

// Block-level Markdown for Claude's replies: headings, lists, tables, quotes, rules, code fences.
// Inline styling (bold, italics, `code`, links) uses Foundation's Markdown parser.
enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(indent: Int, String)
    case ordered(indent: Int, number: String, String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum Markdown {
    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let m = match(#"^(#{1,6})\s+(.*)$"#, trimmed) {
                flush(); blocks.append(.heading(m[1].count, m[2])); i += 1; continue
            }
            if match(#"^([-*_])(\s*\1){2,}$"#, trimmed) != nil {
                flush(); blocks.append(.rule); i += 1; continue
            }
            if let m = match(#"^(\s*)[-*+]\s+(.*)$"#, line) {
                flush(); blocks.append(.bullet(indent: m[1].count / 2, m[2])); i += 1; continue
            }
            if let m = match(#"^(\s*)(\d+)[.)]\s+(.*)$"#, line) {
                flush(); blocks.append(.ordered(indent: m[1].count / 2, number: m[2], m[3])); i += 1; continue
            }
            if let m = match(#"^>\s?(.*)$"#, trimmed) {
                flush()
                if case .quote(let prev)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(prev + "\n" + m[1])
                } else {
                    blocks.append(.quote(m[1]))
                }
                i += 1; continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            Range(m.range(at: idx), in: s).map { String(s[$0]) } ?? ""
        }
    }
}

struct MarkdownView: View {
    let text: String
    private var blocks: [MDBlock] { Markdown.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(Markdown.inline(t))
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let t):
            Text(Markdown.inline(t)).font(.subheadline)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(Theme.accent)
                Text(Markdown.inline(t)).font(.subheadline)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .ordered(let indent, let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.accent)
                Text(Markdown.inline(t)).font(.subheadline)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(Markdown.inline(t)).font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.caption.monospaced()).padding(10)
            }
            .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 10))
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider().overlay(Theme.stroke).padding(.vertical, 4)
        }
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    // Each column gets a definite width from its longest text (between 70 and 200 pt), so long text
    // wraps inside its cell and the row grows taller. (A max-width alone doesn't stop text from
    // overflowing into the next cell inside a horizontal scroll view.)
    private var columnWidths: [CGFloat] {
        header.indices.map { c in
            let longest = ([header[c]] + rows.map { c < $0.count ? $0[c] : "" })
                .map { Markdown.inline($0).characters.count }
                .max() ?? 0
            return min(200, max(70, CGFloat(longest) * 6.4))
        }
    }

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        cell(header[c], width: widths[c]).font(.caption.weight(.semibold))
                            .background(Theme.cardRaised.opacity(0.7))
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(header.indices, id: \.self) { c in
                            cell(c < rows[r].count ? rows[r][c] : "", width: widths[c]).font(.caption)
                                .background(r % 2 == 1 ? Theme.card.opacity(0.45) : Color.clear)
                        }
                    }
                }
            }
            // Natural height for the whole table, so rows size to their tallest cell and nothing is cut off.
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func cell(_ s: String, width: CGFloat) -> some View {
        Text(Markdown.inline(s))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxHeight: .infinity, alignment: .topLeading)   // cells in a row share the tallest height
            .overlay(Rectangle().stroke(Theme.stroke, lineWidth: 0.5))
    }
}
