import SwiftUI

/// Editor v1: a plain TextEditor with Markdown helpers. (Phase 6: replace with a TextKit 2 editor
/// that styles Markdown live, like Bear; see RESEARCH.md §8.)
struct MarkdownEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
            HStack(spacing: 14) {
                format("bold", "**", "**")
                format("italic", "*", "*")
                format("list.bullet", "\n- ", "")
                format("checklist", "\n- [ ] ", "")
                format("number", "\n## ", "")
                format("link", "[[", "]]")
                Spacer()
                Text("\(text.split { $0 == " " || $0 == "\n" }.count) words").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ symbol: String, _ prefix: String, _ suffix: String) -> some View {
        Button { text += prefix + suffix } label: { Image(systemName: symbol) }
    }
}

/// Read mode: renders Markdown with checklists and headings.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                case .task(let done, let text):
                    Label { Text(inline(text)).strikethrough(done) } icon: { Image(systemName: done ? "checkmark.square.fill" : "square") }
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(inline(text)) }
                case .quote(let text):
                    Text(inline(text)).italic().padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 3) }
                case .code(let text):
                    Text(text).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(Int, String), task(Bool, String), bullet(String), quote(String), code(String), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var code: [String]?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { continue }
            if line.hasPrefix("### ") { out.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- [ ] ") { out.append(.task(false, String(line.dropFirst(6)))) }
            else if line.lowercased().hasPrefix("- [x] ") { out.append(.task(true, String(line.dropFirst(6)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if line.hasPrefix("> ") { out.append(.quote(String(line.dropFirst(2)))) }
            else { out.append(.paragraph(line)) }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    /// Inline bold/italic/links via AttributedString. `[[wikilinks]]` become `trove://link?t=Title`
    /// links, which ItemDetailView opens (the item with that title, or a new note).
    private func inline(_ text: String) -> AttributedString {
        var linked = ""
        var rest = text[...]
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            linked += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first?.split(separator: "#").first.map(String.init) ?? ""
            var c = URLComponents()
            c.scheme = "trove"; c.host = "link"; c.queryItems = [URLQueryItem(name: "t", value: target)]
            if let url = c.url?.absoluteString, !target.isEmpty {
                linked += "[\((parts.count > 1 ? parts[1] : target).replacingOccurrences(of: "]", with: ""))](\(url))"
            } else {
                linked += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        linked += rest
        return (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
