# Trove

A place to **learn**, for **Mac, iPhone and iPad**. Pick what you're learning (a GCSE, IGCSE or A-level
course, a university module, or something of your own: a language, an instrument, a certificate) and Trove
gives you small practice sessions from real exam papers, a tutor that reads your handwriting and holds the
answer back, and progress you can explain. Notes, sketches, PDFs and the clipboard are the tools you learn
with. It syncs through your own iCloud Drive (with an optional free Cloudflare relay for instant sync) and
everything is end-to-end encrypted. A website version exists too, but the apps are the product.

## What's in it

- **Learn:** pick what you're learning; Trove leads with the next exam or goal and a small Up next session
  (about 3 questions, ~10 minutes). Testing yourself and spacing practice out come first; streaks stay quiet
  and there's no XP. For exam courses Trove lists the boards' past papers:
  - **AQA, OCR, Pearson Edexcel, Eduqas, WJEC and Cambridge**, GCSE, (I)GCSE and AS/A level, from each
    board's own site (`catalogue/`, rebuilt weekly). CCEA, and Pearson's newest login-only papers, through a
    browser inside the app (Upload → From a board's website).
  - Papers are **split into questions** with their marks, so you practise one question at a time and mark
    it against the mark scheme (or with your AI if you choose). Mastery and goals track how you're doing.
  - **Your own papers** (worksheets, competition papers, photos, scans) upload with a suggested name read
    from the paper, which you can change.
  - Papers you download and upload **sync to all your devices** through your trove.
- **Save from anywhere:** share sheet, Safari and Chrome extensions, a keyboard, email-in, drag and drop,
  imports from Apple Notes, Obsidian, Kindle, Readwise, Notion and Paste.
- **Organised for you:** auto-filing into folders, tags, connections between items, versions of files,
  search by meaning (on the device), and AI descriptions where you allow it.
- **Notes:** today's note, templates, checklists, links between notes; AI actions and flashcards.
- **PDFs and drawing:** a proper PDF reader (highlights, forms, export), Apple Pencil sketching and ink on
  PDFs and pictures, GoodNotes notebooks with handwriting search.
- **Clipboard history:** ⌥Space on the Mac, the Trove keyboard on iPhone and iPad, synced and searchable.
- **AI on your terms:** Apple's on-device model (on devices with Apple Intelligence) first; your own Claude
  key only if you add one, with costs shown. You can hide any item from AI.

## Install

The apps are built on GitHub Actions (there's no Apple Silicon Mac to build on locally):

- **iPhone / iPad:** [Trove.ipa](https://github.com/mrlancus/trove/releases/download/latest/Trove.ipa),
  installed with Sideloadly and a free Apple ID (reinstall every 7 days).
- **Mac:** [Trove-macOS.zip](https://github.com/mrlancus/trove/releases/download/latest/Trove-macOS.zip);
  unzip, then right-click Trove.app → Open. It updates itself after that.
- **Website:** https://trove-relay.lancus.workers.dev (create your vault, add devices, use it in any browser).

## Code

| Folder | What |
|---|---|
| `App/` | SwiftUI apps (macOS + iOS/iPadOS), share extension, widgets, Safari extension, keyboard (XcodeGen; `project.yml` is the source of truth) |
| `Packages/TroveCore/` | Shared Swift core: sync engine, encryption, merge, importers, search, notes, ink, Develop (catalogue, splitting, marking, mastery) |
| `server/` | Cloudflare relay: instant sync, sealed inbox, GoodNotes WebDAV, email-in, opt-in AI, serves the website |
| `extensions/browser/` | "Save to Trove" for Chrome (and Safari) |
| `web/` | Trove in any browser (end-to-end encrypted; its `core/` is a JS port of TroveCore's sync) |
| `catalogue/`, `scripts/catalogue/` | The past-paper catalogue (links and facts only) and the scripts that build it from the boards' sites |
| `docs/` | `RESEARCH.md` (spec), `PROTOCOL.md` (wire format), `ARCHITECTURE.md` (code map), `CATALOGUE.md`, `testing/` |

**Status and next steps:** [NOTES.md](NOTES.md). **Run the tests:** `./scripts/test-all.sh`
(TroveCore alone: `cd Packages/TroveCore && swift test`).
