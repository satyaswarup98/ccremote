import SwiftUI

// Renders tmux `capture-pane -e` output (SGR colour codes) into an AttributedString.
enum ANSI {
    private static let base: [Color] = [
        .init(hex: 0x1E1E1E), .init(hex: 0xE5534B), .init(hex: 0x57AB5A), .init(hex: 0xC69026),
        .init(hex: 0x539BF5), .init(hex: 0xB083F0), .init(hex: 0x39C5CF), .init(hex: 0xD1D1D1),
        .init(hex: 0x666666), .init(hex: 0xFF938A), .init(hex: 0x8DDB8C), .init(hex: 0xDAAA3F),
        .init(hex: 0x96D0FF), .init(hex: 0xDCBDFB), .init(hex: 0x56D4DD), .init(hex: 0xFFFFFF),
    ]

    private struct Style {
        var fg: Color?
        var bg: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
    }

    static func render(_ text: String, fontSize: CGFloat) -> AttributedString {
        var out = AttributedString()
        var style = Style()
        var run = ""
        let regular = Font.system(size: fontSize, design: .monospaced)
        let bold = Font.system(size: fontSize, weight: .bold, design: .monospaced)

        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            var fg = style.fg ?? Theme.terminalText
            var bg = style.bg
            if style.inverse { let f = fg; fg = bg ?? Theme.terminalBackground; bg = f }
            piece.foregroundColor = style.dim ? fg.opacity(0.6) : fg
            if let bg { piece.backgroundColor = bg }
            piece.font = style.bold ? bold : (style.italic ? regular.italic() : regular)
            if style.underline { piece.underlineStyle = .single }
            out.append(piece)
            run = ""
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "\u{1B}" else { run.unicodeScalars.append(c); i += 1; continue }
            flush()
            guard i + 1 < scalars.count else { break }
            let kind = scalars[i + 1]
            if kind == "[" {
                var j = i + 2
                var params = ""
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j]); j += 1
                }
                if j < scalars.count, scalars[j] == "m" { apply(params, to: &style) }
                i = j + 1
            } else if kind == "]" {
                // OSC (e.g. hyperlinks): skip to BEL or ST
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { j += 1; break }
                    if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                    j += 1
                }
                i = j
            } else {
                i += 2
            }
        }
        flush()
        return out
    }

    private static func apply(_ params: String, to s: inout Style) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let c = codes[k]
            switch c {
            case 0: s = Style()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4: s.underline = true
            case 7: s.inverse = true
            case 22: s.bold = false; s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 30...37: s.fg = base[c - 30]
            case 90...97: s.fg = base[c - 90 + 8]
            case 39: s.fg = nil
            case 40...47: s.bg = base[c - 40]
            case 100...107: s.bg = base[c - 100 + 8]
            case 49: s.bg = nil
            case 38, 48:
                var color: Color?
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    color = palette256(codes[k + 2]); k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    color = Color(red: Double(codes[k + 2]) / 255, green: Double(codes[k + 3]) / 255, blue: Double(codes[k + 4]) / 255)
                    k += 4
                }
                if c == 38 { s.fg = color } else { s.bg = color }
            default: break
            }
            k += 1
        }
    }

    private static func palette256(_ n: Int) -> Color {
        if n < 16 { return base[max(0, n)] }
        if n >= 232 {
            let v = Double(8 + (n - 232) * 10) / 255
            return Color(red: v, green: v, blue: v)
        }
        let i = n - 16
        let steps: [Double] = [0, 95, 135, 175, 215, 255]
        return Color(red: steps[i / 36] / 255, green: steps[(i / 6) % 6] / 255, blue: steps[i % 6] / 255)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
