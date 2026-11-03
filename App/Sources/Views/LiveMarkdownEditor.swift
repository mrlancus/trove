import SwiftUI
import TroveCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The live notes editor (docs/MASTER_PLAN.md N1): Markdown styled as you type, like Bear and
/// Obsidian's live preview, on TextKit 2. Notes stay plain Markdown; this only colours them.
/// - Only the paragraph being edited is restyled (a fence line restyles everything), so typing
///   costs the same in a 50,000-word note as in a short one.
/// - Tap a checkbox to tick it; Return continues a list (and ends it on an empty item).
/// - `[[` suggests titles from the library; picking one finishes the link.
/// - Writing Tools come with the system text view where Apple Intelligence is on (the iPad).
struct LiveMarkdownEditor: View {
    @Binding var text: String
    /// Titles offered after `[[`.
    var titles: [String] = []
    @State private var query: String?
    @State private var controller = LiveMarkdownController()

    var body: some View {
        VStack(spacing: 6) {
            MarkdownTextView(text: $text, query: $query, controller: controller)
                .frame(minHeight: 260)
            if let query, !suggestions(for: query).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions(for: query), id: \.self) { title in
                            Button(title) { controller.completeWikilink(title) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                format("bold", "**", "**")
                format("italic", "*", "*")
                format("highlighter", "==", "==")
                format("list.bullet", "- ", "", line: true)
                format("checklist", "- [ ] ", "", line: true)
                format("textformat.size", "## ", "", line: true)
                format("link", "[[", "]]")
                Spacer()
                Text("\(text.split { $0 == " " || $0 == "\n" }.count) words").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func suggestions(for q: String) -> [String] {
        let folded = q.lowercased()
        return Array(titles.lazy.filter { !$0.isEmpty && (folded.isEmpty || $0.lowercased().contains(folded)) }.prefix(8))
    }

    private func format(_ symbol: String, _ prefix: String, _ suffix: String, line: Bool = false) -> some View {
        Button { controller.wrap(prefix, suffix, atLineStart: line) } label: { Image(systemName: symbol) }
    }
}

/// Lets the SwiftUI side act on the text view (format buttons, finishing a wikilink).
@MainActor
final class LiveMarkdownController {
    weak var coordinator: MarkdownTextView.Coordinator?
    func wrap(_ prefix: String, _ suffix: String, atLineStart: Bool) { coordinator?.wrap(prefix, suffix, atLineStart: atLineStart) }
    func completeWikilink(_ title: String) { coordinator?.completeWikilink(title) }
}

// MARK: - Styling (both platforms)

#if canImport(UIKit)
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

@MainActor
enum MarkdownStyler {
    static var bodySize: CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        NSFont.systemFontSize + 1
        #endif
    }

    static func base() -> [NSAttributedString.Key: Any] {
        #if canImport(UIKit)
        [.font: PlatformFont.systemFont(ofSize: bodySize), .foregroundColor: PlatformColor.label]
        #else
        [.font: PlatformFont.systemFont(ofSize: bodySize), .foregroundColor: PlatformColor.labelColor]
        #endif
    }

    static var secondary: PlatformColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    static var accent: PlatformColor {
        #if canImport(UIKit)
        .tintColor
        #else
        .controlAccentColor
        #endif
    }

    static func withTraits(_ font: PlatformFont, bold: Bool = false, italic: Bool = false) -> PlatformFont {
        #if canImport(UIKit)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #endif
    }

    static func mono(_ size: CGFloat) -> PlatformFont { PlatformFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular) }

    /// Styles one line that starts at `offset` in the storage.
    static func style(_ storage: NSTextStorage, line: String, offset: Int, inFence: Bool) {
        let length = line.utf16.count
        let whole = NSRange(location: offset, length: length)
        guard NSMaxRange(whole) <= storage.length else { return }
        storage.setAttributes(base(), range: whole)
        for span in MarkdownSyntax.spans(line: line, inFence: inFence) {
            let r = NSRange(location: offset + span.location, length: span.length)
            guard r.length > 0, NSMaxRange(r) <= storage.length else { continue }
            switch span.style {
            case .heading(let level):
                let scale: CGFloat = [1.6, 1.35, 1.18, 1.08, 1.04, 1.0][min(5, level - 1)]
                storage.addAttribute(.font, value: PlatformFont.systemFont(ofSize: bodySize * scale, weight: .bold), range: r)
            case .bold, .italic:
                let bold = span.style == .bold
                storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                    let f = (value as? PlatformFont) ?? PlatformFont.systemFont(ofSize: bodySize)
                    storage.addAttribute(.font, value: withTraits(f, bold: bold, italic: !bold), range: sub)
                }
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code, .codeBlock:
                storage.addAttribute(.font, value: mono(bodySize), range: r)
                storage.addAttribute(.backgroundColor, value: secondary.withAlphaComponent(0.12), range: r)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: PlatformColor.systemYellow.withAlphaComponent(0.35), range: r)
            case .link, .wikilink, .tag:
                storage.addAttribute(.foregroundColor, value: accent, range: r)
            case .marker, .bullet:
                storage.addAttribute(.foregroundColor, value: secondary.withAlphaComponent(0.7), range: r)
            case .checkbox:
                storage.addAttribute(.foregroundColor, value: accent, range: r)
                storage.addAttribute(.font, value: mono(bodySize), range: r)
            case .done:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.foregroundColor, value: secondary, range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: secondary, range: r)
            }
        }
    }

    /// Restyles everything (on load, or when a code fence changed).
    static func styleAll(_ storage: NSTextStorage) {
        let text = storage.string
        storage.beginEditing()
        var offset = 0
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            style(storage, line: line, offset: offset, inFence: inFence)
            if MarkdownSyntax.isFence(line) { inFence.toggle() }
            offset += line.utf16.count + 1
        }
        storage.endEditing()
    }

    /// Restyles the paragraph(s) touched by an edit; returns false when everything must be restyled.
    static func styleEdited(_ storage: NSTextStorage, around range: NSRange) -> Bool {
        let ns = storage.string as NSString
        let safe = NSRange(location: min(range.location, ns.length), length: min(range.length, max(0, ns.length - min(range.location, ns.length))))
        let para = ns.paragraphRange(for: safe)
        let chunk = ns.substring(with: para)
        if chunk.contains("```") { return false }
        // Inside a fence? Count the fences before this paragraph.
        let before = ns.substring(to: para.location)
        let fences = before.components(separatedBy: "\n").filter(MarkdownSyntax.isFence).count
        storage.beginEditing()
        var offset = para.location
        for line in chunk.components(separatedBy: "\n") {
            if offset > NSMaxRange(para) { break }
            style(storage, line: line, offset: offset, inFence: fences % 2 == 1)
            offset += line.utf16.count + 1
        }
        storage.endEditing()
        return true
    }
}

// MARK: - The text view

#if canImport(UIKit)
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var query: String?
    let controller: LiveMarkdownController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = PlatformFont.systemFont(ofSize: MarkdownStyler.bodySize)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.writingToolsBehavior = .complete
        view.text = text
        MarkdownStyler.styleAll(view.textStorage)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        controller.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            MarkdownStyler.styleAll(view.textStorage)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        weak var view: UITextView?
        private var lastEdit = NSRange(location: 0, length: 0)

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            lastEdit = NSRange(location: range.location, length: (text as NSString).length)
            guard text == "\n" else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            guard let next = MarkdownSyntax.continuation(of: line) else { return true }
            if next.endList {
                // An empty item: Return ends the list (the marker goes).
                replace(NSRange(location: lineRange.location, length: range.location - lineRange.location), with: "")
            } else {
                replace(range, with: next.insert)
            }
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            if !MarkdownStyler.styleEdited(textView.textStorage, around: lastEdit) { MarkdownStyler.styleAll(textView.textStorage) }
            parent.text = textView.text
            updateQuery(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) { updateQuery(textView) }

        private func updateQuery(_ textView: UITextView) {
            let cursor = textView.selectedRange.location
            let q = MarkdownSyntax.openWikilink(in: textView.text, cursor: cursor)?.query
            if parent.query != q { parent.query = q }
        }

        private func replace(_ range: NSRange, with string: String) {
            guard let view, let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length), let r = view.textRange(from: start, to: end) else { return }
            lastEdit = NSRange(location: range.location, length: (string as NSString).length)
            view.replace(r, withText: string)
        }

        func wrap(_ prefix: String, _ suffix: String, atLineStart: Bool) {
            guard let view else { return }
            let sel = view.selectedRange
            let ns = view.text as NSString
            if atLineStart {
                let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                replace(NSRange(location: line.location, length: 0), with: prefix)
            } else {
                let selected = ns.substring(with: sel)
                replace(sel, with: prefix + selected + suffix)
                if selected.isEmpty { view.selectedRange = NSRange(location: sel.location + (prefix as NSString).length, length: 0) }
            }
        }

        func completeWikilink(_ title: String) {
            guard let view, let open = MarkdownSyntax.openWikilink(in: view.text, cursor: view.selectedRange.location) else { return }
            replace(NSRange(location: open.start, length: view.selectedRange.location - open.start), with: title + "]]")
            parent.query = nil
        }

        /// A tap on a checkbox ticks or unticks it.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view, let pos = view.closestPosition(to: g.location(in: view)) else { return }
            toggleCheckbox(near: view.offset(from: view.beginningOfDocument, to: pos))
        }

        private func toggleCheckbox(near index: Int) {
            guard let view else { return }
            let ns = view.text as NSString
            guard index <= ns.length else { return }
            let line = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
            let text = ns.substring(with: line).replacingOccurrences(of: "\n", with: "")
            for span in MarkdownSyntax.spans(line: text) {
                guard case .checkbox(let checked) = span.style else { continue }
                let box = NSRange(location: line.location + span.location, length: span.length)
                // Only a tap on (or right next to) the box.
                guard index >= box.location - 1, index <= NSMaxRange(box) + 1 else { return }
                replace(NSRange(location: box.location + 1, length: 1), with: checked ? " " : "x")
                return
            }
        }
    }
}
#else
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var query: String?
    let controller: LiveMarkdownController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = PlatformFont.systemFont(ofSize: MarkdownStyler.bodySize)
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.writingToolsBehavior = .complete
        view.string = text
        if let storage = view.textStorage { MarkdownStyler.styleAll(storage) }
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        scroll.drawsBackground = false
        context.coordinator.view = view
        controller.coordinator = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        if let storage = view.textStorage { MarkdownStyler.styleAll(storage) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var view: NSTextView?
        private var lastEdit = NSRange(location: 0, length: 0)

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            lastEdit = NSRange(location: range.location, length: ((text ?? "") as NSString).length)
            guard text == "\n" else { return true }
            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            guard let next = MarkdownSyntax.continuation(of: line) else { return true }
            if next.endList {
                replace(NSRange(location: lineRange.location, length: range.location - lineRange.location), with: "")
            } else {
                replace(range, with: next.insert)
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let view, let storage = view.textStorage else { return }
            if !MarkdownStyler.styleEdited(storage, around: lastEdit) { MarkdownStyler.styleAll(storage) }
            parent.text = view.string
            updateQuery()
        }

        func textViewDidChangeSelection(_ notification: Notification) { updateQuery() }

        private func updateQuery() {
            guard let view else { return }
            let q = MarkdownSyntax.openWikilink(in: view.string, cursor: view.selectedRange().location)?.query
            if parent.query != q { parent.query = q }
        }

        private func replace(_ range: NSRange, with string: String) {
            guard let view, view.shouldChangeText(in: range, replacementString: string) else { return }
            lastEdit = NSRange(location: range.location, length: (string as NSString).length)
            view.textStorage?.replaceCharacters(in: range, with: string)
            view.didChangeText()
            view.setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
        }

        func wrap(_ prefix: String, _ suffix: String, atLineStart: Bool) {
            guard let view else { return }
            let sel = view.selectedRange()
            let ns = view.string as NSString
            if atLineStart {
                let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                replace(NSRange(location: line.location, length: 0), with: prefix)
            } else {
                let selected = ns.substring(with: sel)
                replace(sel, with: prefix + selected + suffix)
                if selected.isEmpty { view.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0)) }
            }
        }

        func completeWikilink(_ title: String) {
            guard let view, let open = MarkdownSyntax.openWikilink(in: view.string, cursor: view.selectedRange().location) else { return }
            replace(NSRange(location: open.start, length: view.selectedRange().location - open.start), with: title + "]]")
            parent.query = nil
        }

        @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let view else { return }
            let index = view.characterIndexForInsertion(at: g.location(in: view))
            let ns = view.string as NSString
            guard index <= ns.length, ns.length > 0 else { return }
            let line = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
            let text = ns.substring(with: line).replacingOccurrences(of: "\n", with: "")
            for span in MarkdownSyntax.spans(line: text) {
                guard case .checkbox(let checked) = span.style else { continue }
                let box = NSRange(location: line.location + span.location, length: span.length)
                guard index >= box.location - 1, index <= NSMaxRange(box) + 1 else { return }
                replace(NSRange(location: box.location + 1, length: 1), with: checked ? " " : "x")
                return
            }
        }
    }
}
#endif
