# Trove

Save anything: links, screenshots, PDFs, voice notes, highlights, email and GoodNotes handwriting.
Trove organises it for you and finds it by meaning. It also works with Apple Notes, Obsidian, Kindle,
Readwise and Notion. It syncs through your own iCloud Drive, with an optional free Cloudflare relay,
and is end-to-end encrypted. It's a native app for Mac, iPhone and iPad.

| Folder | What |
|---|---|
| `App/` | SwiftUI apps (macOS + iOS/iPadOS), share extension, widgets, Safari extension (XcodeGen project) |
| `Packages/TroveCore/` | Shared Swift core: sync engine, encryption, merge, importers, search |
| `server/` | Cloudflare relay: instant sync, sealed inbox, GoodNotes WebDAV, email-in, opt-in AI |
| `extensions/browser/` | "Save to Trove" for Chrome (and Safari) |
| `web/` | Trove in any browser, served by the relay (browse, search, write, upload; end-to-end encrypted) |
| `docs/` | `RESEARCH.md` (spec), `PROTOCOL.md` (wire format), `ARCHITECTURE.md` (code map) |

**Status and next steps:** [NOTES.md](NOTES.md). **Run the tests:** `./scripts/test-all.sh`.
