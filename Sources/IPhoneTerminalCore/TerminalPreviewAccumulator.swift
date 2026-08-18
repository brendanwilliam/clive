import Foundation

/// A deliberately small, in-memory-only representation of recent terminal output.
/// It strips terminal control streams incrementally, so a split escape sequence can
/// never leak into a connection switcher preview.
public struct TerminalPreviewAccumulator: Sendable {
    public private(set) var preview: String?
    private var line = ""
    private var escape: EscapeState = .text
    private let maximumLength: Int

    private enum EscapeState: Sendable { case text, escape, csi, osc, oscEscape }

    public init(maximumLength: Int = 120) { self.maximumLength = maximumLength }

    public mutating func consume(_ data: Data) {
        for byte in data {
            switch escape {
            case .escape:
                if byte == 0x5b { escape = .csi }
                else if byte == 0x5d { escape = .osc }
                else { escape = .text }
                continue
            case .csi:
                if byte >= 0x40 && byte <= 0x7e { escape = .text }
                continue
            case .osc:
                if byte == 0x07 { escape = .text }
                else if byte == 0x1b { escape = .oscEscape }
                continue
            case .oscEscape:
                escape = byte == 0x5c ? .text : .osc
                continue
            case .text: break
            }
            if byte == 0x1b { escape = .escape; continue }
            if byte == 0x0d { line = ""; continue }
            if byte == 0x08 || byte == 0x7f { if !line.isEmpty { line.removeLast() }; continue }
            if byte == 0x0a { publish(); line = ""; continue }
            guard byte >= 0x20 else { continue }
            // Decoding a single byte only admits ASCII; non-ASCII is handled after an
            // output chunk below, avoiding replacement glyphs for invalid sequences.
            if byte < 0x80 { line.unicodeScalars.append(UnicodeScalar(byte)) }
        }
        publish()
    }

    public mutating func clear() { preview = nil; line = ""; escape = .text }

    private mutating func publish() {
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return }
        preview = String(collapsed.prefix(maximumLength))
    }
}
