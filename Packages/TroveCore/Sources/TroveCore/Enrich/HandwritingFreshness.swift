import Foundation

/// Which sketch pages need their handwriting read again (docs/plans/sketch-2-plan.md A5).
///
/// The page-by-page text lives in a cache on this device only, while the item's overall signature
/// syncs. Trusting the synced signature meant handwriting read on another device (or a cache the
/// system cleared) looked "already read" with no text here, so the notebook chat saw none of it.
/// Now every page is judged by its own signature against what this device actually holds.
public enum HandwritingFreshness {
    /// `pages`: each page with ink, and the signature of its strokes now. `local`: the signature each
    /// page was read at on this device. Returns the pages to read, in the order given.
    public static func pagesToRead(_ pages: [(key: String, sig: String)], local: [String: String]) -> [String] {
        pages.filter { local[$0.key] != $0.sig }.map(\.key)
    }

    /// Whether nothing needs reading: the item's synced signature may be skipped on only when every
    /// page with ink is held locally at its current signature.
    public static func upToDate(_ pages: [(key: String, sig: String)], local: [String: String]) -> Bool {
        pagesToRead(pages, local: local).isEmpty
    }
}

/// Asking before the notebook chat sends pictures of pages (plan A5.5). The first time in a session
/// a question would send pictures, the user is asked: allow once, for this session, always, or not now.
public enum PictureConsent {
    /// Settings → AI → Page pictures.
    public enum Setting: String, CaseIterable, Sendable {
        case askEachSession, always, never
    }

    public enum Answer: Sendable {
        case allowOnce, allowSession, allowAlways, notNow
    }

    public enum Decision: Equatable, Sendable {
        case send, skip, ask
    }

    /// What to do for a question that wants pictures. `session` is this session's earlier answer
    /// (`true` allowed for the session, `false` said not now for it, nil not asked yet).
    public static func decide(_ setting: Setting, session: Bool?) -> Decision {
        switch setting {
        case .always: return .send
        case .never: return .skip
        case .askEachSession:
            switch session {
            case true?: return .send
            case false?: return .skip
            case nil: return .ask
            }
        }
    }

    /// Applies an answer: whether to send now, this session's memory, and the new setting.
    public static func apply(_ answer: Answer, setting: Setting) -> (send: Bool, session: Bool?, setting: Setting) {
        switch answer {
        case .allowOnce: return (true, nil, setting)
        case .allowSession: return (true, true, setting)
        case .allowAlways: return (true, true, .always)
        // "Not now" for this question only; the next one asks again (it's cheap to ask, and the
        // user may want pictures for a diagram question later).
        case .notNow: return (false, nil, setting)
        }
    }
}

/// Which pages to show the AI as pictures (plan A5.5): pages with ink that Vision read little text
/// from (drawings, diagrams, maths layout), the current page first, at most `limit`.
public enum PagePictures {
    public struct Page: Sendable {
        public var key: String
        public var strokes: Int
        /// Characters of text read from the page's handwriting.
        public var textCharacters: Int
        public init(key: String, strokes: Int, textCharacters: Int) { self.key = key; self.strokes = strokes; self.textCharacters = textCharacters }
    }

    /// Writing gives a few characters a stroke; a page well under that is mostly drawing.
    public static func mostlyDrawing(_ p: Page) -> Bool { p.strokes >= 8 && Double(p.textCharacters) < Double(p.strokes) * 0.8 }

    public static func choose(_ pages: [Page], current: String?, limit: Int = 3) -> [String] {
        let wanted = pages.filter(mostlyDrawing)
        let ordered = wanted.sorted { a, b in
            if a.key == current { return true }
            if b.key == current { return false }
            return a.strokes > b.strokes
        }
        return Array(ordered.prefix(limit).map(\.key))
    }

    /// About what pictures cost (Haiku-class input price per million tokens): a picture ~1 600 tokens.
    public static func cost(_ count: Int, pricePerMillion: Double = 0.10) -> Double { Double(count) * 1_600 * pricePerMillion / 1_000_000 }
}
