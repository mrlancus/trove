# Build prompt: Trove (save-anything brain + notes app)

> **How to use:**
> 1. Make an empty folder on your Mac and put **RESEARCH.md** (from this same folder) in it.
> 2. Open Claude Code there (Code tab in Claude desktop).
> 3. Paste everything below the line.
>
> You'll need: Xcode (latest), a free Apple ID signed into Xcode, a free Cloudflare account, and Node.js.

---

I want to build **Trove** (working name), a native Apple app for Mac, iPhone and iPad. It's a "save anything" second brain combined with a proper notes app:
- It captures links, screenshots, photos, PDFs, voice notes, highlights and emails, and organizes them automatically.
- It works with the apps I already use instead of replacing them: Apple Notes, GoodNotes, Obsidian, Notion, Kindle, Readwise.
- It syncs for free through **my own iCloud Drive**, with an optional Cloudflare relay for instant sync and server features.
- It works well even on devices **without** Apple Intelligence. **My iPad is my only Apple Intelligence device**, so it acts as the AI helper for my iPhone and Mac.
- It looks and feels Apple-made.

**Read `RESEARCH.md` in this folder first.** It has the full research: competitors, the AI tier design, sync options, every integration's real limits, Cloudflare free-tier numbers, risks and a roadmap. Treat it as the spec. Anything marked **(verify)** must be checked against current docs or a quick test before you rely on it.

## Non-negotiables
1. **AI tiers, so old devices work** (RESEARCH.md §3):
   - **Tier 0:** Vision OCR, NSDataDetector, NLTagger, NLEmbedding, image classification, schema.org parsing. Works on every device.
   - **Tier 1:** the Foundation Models framework where available.
   - **Tier 2:** **my iPad** enriches items for my iPhone and Mac through sync. It runs while the app is open, and in a background processing task that requires external power, overnight while charging. Handle the Foundation Models rate-limit error and retry.
   - **Tier 3:** cloud AI, opt-in only, with a clear "processed in cloud" badge:
     - Default to Claude Haiku 5.5 (`claude-haiku-5-5`, effort `low` for tagging) via the official Anthropic TypeScript SDK inside the Worker, with the API key stored as a Worker secret and never shipped in the apps.
     - Use Cloudflare Workers AI for Whisper transcription and embeddings.
     - Show me a monthly usage and cost estimate in settings.

   Rules:
   - Every feature has a fallback, and the UI never shows broken buttons.
   - Search indexes are built locally on each device and never synced.
   - AI *results* (summaries, titles, tags, transcripts) are synced, tagged with the device or model that made them.
2. **Free Apple ID and iCloud Drive storage.** No CloudKit, push or Siri entitlement. Free accounts allow 10 App IDs per 7 days and 3 apps per device, so keep targets lean: one multiplatform app plus share, widget and Safari extensions.

   Main storage is the **iCloud Drive vault** design in RESEARCH.md §4:
   - one `Trove/` folder in iCloud Drive
   - **per-device append-only change journals**, so no two devices ever write the same file
   - content-hash-named attachments
   - a readable Markdown mirror written only by the Mac

   Both of these sit behind a `SyncTransport` protocol, so CloudKit can be added later:
   - An optional **Cloudflare relay** (Workers + Durable Objects + R2) carries the same journals for instant sync. It also hosts email-in, GoodNotes WebDAV, price checks and cloud AI.
   - **Fallback:** if Phase 0 shows that iOS can't access a picked iCloud Drive folder on a free account, the iPhone and iPad sync through the relay and the Mac bridges to iCloud.
3. **End-to-end encryption:**
   - CryptoKit, with the vault key in the Keychain.
   - QR-code device pairing and a printable recovery key.
   - A sealed-box public key so the server can accept email-in and GoodNotes uploads it can't read.
4. **Offline-first:**
   - Local SQLite (GRDB) with FTS5 is the source of truth for the UI.
   - Note bodies merge with a CRDT (evaluate Automerge Swift). Never lose data silently.
5. **No lock-in:**
   - Notes are Markdown internally.
   - Full export to Markdown plus attachments.
   - Two-way Obsidian vault mirroring on Mac.
6. **Minimum OS.** Ask me which devices I own. Default to iOS 18+ / macOS 15+, with Liquid Glass, Foundation Models and SpeechAnalyzer enabled automatically on 26+.
7. **Privacy:**
   - Journals and attachments in iCloud are encrypted with the vault key by default. A setting can turn this off, relying on Apple's iCloud encryption so files stay readable in Files.
   - The Obsidian Markdown mirror is plaintext by design.
   - Nothing goes to the relay or to cloud AI unencrypted unless I explicitly opt in for that item.

## Integrations (each one an isolated module; details and limits in RESEARCH.md §5)
- **Apple Notes:**
  - Mac: a read-only mirror into Trove's search via AppleScript/JXA, plus "Save to Apple Notes".
  - iOS: import via share sheet → "Export as Markdown" (iOS 26), plus a Shortcuts-based importer.
- **GoodNotes:** a minimal WebDAV endpoint on the Worker, targeted by GoodNotes Auto Backup, storing PDFs sealed-box encrypted. Devices then OCR the handwriting into search. Dropbox local folder is the alternative.
- **Obsidian:** two-way vault folder mirror on Mac (FSEvents, YAML front matter, `[[wikilinks]]`, attachments).
- **Notion:** one-way import or sync of chosen pages using an internal integration token.
- **Kindle and Readwise:** a `My Clippings.txt` parser, and the Readwise export API.
- **Safari Web Extension and Chrome extension:** save page, selection or highlights; snapshot article text at save time.
- **Email-in:** Cloudflare Email Routing → Email Worker. Optional, needs a domain.
- **Photos:** opt-in screenshot auto-import with OCR.
- **Reminders/Calendar:** via EventKit.
- **CoreSpotlight and App Intents:** "Save / Search / Ask Trove".
- **Imports:** mymind, Raindrop, Pocket and browser bookmark exports.

## Features
Build the full list in RESEARCH.md §6:
- capture everywhere
- a real Markdown notes editor (live styling, links/backlinks, daily notes, templates, PencilKit on iPad)
- auto Smart Collections
- spaces plus a Face ID private space
- one search across everything, including the integrations
- resurfacing (on this day, highlight review, places map with nearby alerts, price-drop alerts)
- turning items into reminders and events
- Ask Trove with citations
- reader mode
- publish-to-link
- later, a browser web app that decrypts client-side

## Design
- Apple Human Interface Guidelines, SwiftUI.
- Liquid Glass on 26+ with graceful materials on older OSes.
- SF Symbols with symbol effects, spring animations, haptics.
- A beautiful masonry/card grid for items, with each content type having its own card style.
- Calm, premium, fast. Dark and light mode, Dynamic Type, VoiceOver.
- Show me 2–3 visual directions as SwiftUI previews or screenshots before building the main UI.

## How I want you to work
1. **Read RESEARCH.md, then ask me the §10 questions.** Then run the **Phase 0 spikes** to prove the risky assumptions:
   - **The most important one:** can the iPhone and iPad app read and write a user-picked iCloud Drive folder, and keep access via a bookmark, when signed with a free account?
   - Foundation Models on my iPad, including a charging-only background task
   - SpeechAnalyzer on my iPhone
   - Safari extension loading with a free-account signature
   - Worker + Durable Object hello-world
   - GoodNotes Auto Backup → WebDAV upload with a large notebook (check Worker request-size limits)

   Report the results, with the RESEARCH.md §11 table updated.
2. Write `ARCHITECTURE.md` covering:
   - modules and the shared `TroveCore` Swift package
   - the data model
   - the sync protocol and CRDT choice
   - the encryption and pairing design
   - the enrichment pipeline and tiers
   - the integration plugin interface

   Then wait for my OK.
3. Build phase by phase (RESEARCH.md §9). **Every phase ends with something I can run and use.** Deploy the Cloudflare parts with `wrangler`, and give me exact setup steps the first time (`wrangler login`, bucket creation and so on).
4. **Tests:**
   - Unit-test `TroveCore`: enrichment extractors, search ranking, CRDT merge cases, encryption round-trips, importers.
   - Test the Worker with vitest and the Workers pool.
   - Build and test with `xcodebuild`, and keep Swift 6 strict concurrency clean.
5. Use git and commit after each phase.
6. Keep `NOTES.md` up to date with what's done, what's next, decisions made, and every manual step for me. Include Xcode signing, App Groups, extension enabling, the 7-day iOS re-install, and the Cloudflare and GoodNotes setup. A fresh session should be able to say "read NOTES.md and continue" and pick up exactly where we left off.
7. Ask me before decisions that are mine: the name (suggest 5), the design direction, the minimum OS, and anything that costs money.

Start with step 1.
