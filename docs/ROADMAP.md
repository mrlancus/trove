# Trove roadmap: what to build next

_Written 2026-10-21 from a read of the code as it stands (commit fe47b18). The user asked for "a detailed
plan of what else we can do to any part of Trove": new features, faster everything (searches above
all), **sketching good enough to be serious competition for GoodNotes**, and how AI, GitHub,
Cloudflare and "the connection thing" (linking Trove to other services) should work._

How to read it:
- Every item has a size: **S** (one session), **M** (2–3 sessions), **L** (a round of several sessions).
- **Web first** means build it on the website first (the user's main client while there's no Apple
  Silicon Mac), then port it to the apps. Shared logic goes in TroveCore and `web/public/core` together,
  with a shared fixture, as usual.
- 🔒 marks anything that touches the protocol or encryption. Those change PROTOCOL.md, both cores and
  the fixtures in the same commit.
- ❓ marks a decision that's the user's to make (collected at the end).

---

## 0. Where Trove stands against GoodNotes

| | GoodNotes 6 | Trove today | Gap |
|---|---|---|---|
| Pens, pressure, highlighter, shapes, lasso, text, pictures | ✅ | ✅ 6 pens, shape snap, lasso move/resize/recolour | Rotate, flip, arrange, convert to text |
| Papers and templates | ✅ big library + custom | ✅ 17 papers, page sizes | Planners, custom templates from any PDF/image |
| Notebook feel: covers, shelf, outline, links between pages | ✅ | ❌ sketches are cards in a folder | **Big gap** |
| PDF markup | ✅ text-snapping highlighter, forms, links, outline | 🟡 ink on top only | Text selection, highlight-to-text, links, outline |
| Handwriting search | ✅ | 🟡 Apple devices only (Vision, page text) | Website, word positions, hit highlights |
| Handwriting → text, spellcheck, word complete, math | ✅ | ❌ | Needs recognition with word boxes |
| Audio recording synced to ink | ❌ (Notability has it) | ❌ | **A chance to beat GoodNotes** |
| Study: flashcards, tape | ✅ | ❌ | Medium |
| Elements / stickers | ✅ | ❌ | Small |
| Zoom window (write big, lands small) | ✅ | ❌ | Medium |
| Presentation mode | ✅ | 🟡 laser only | Small |
| Collaboration | ✅ share links, live | ❌ | Later (needs shared keys) |
| Writing feel / latency | Excellent (native) | iPad: PencilKit (excellent); website: good, not great | Website rendering pipeline |
| Works on Windows/Android/any browser | 🟡 web viewer | ✅ full editor on the website | **Trove's edge** |
| Notes, links, clips, files, graph in the same place | ❌ | ✅ | **Trove's edge** |
| End-to-end encrypted | ❌ | ✅ | **Trove's edge** |

The plan: close the "feel" and "notebook" gaps first (that's what people notice in the first minute),
then add the things GoodNotes can't do because it isn't a second brain: audio synced to ink, ink
that links to everything else, AI over all of it, and GoodNotes notebooks opened and edited without
GoodNotes.

---

## 1. Sketching: a real GoodNotes rival

### S1. Writing feel and speed (web first, then Mac) **L**
The iPad app already uses PencilKit, which is as good as it gets. The website and the Mac draw
strokes themselves, and that's where the feel is lost.
- **Outline rendering.** Today `drawStroke` (core/ink.js) and `InkRenderer.swift` draw a stroke as
  many short segments of varying width. Instead, turn each stroke into one filled outline polygon
  (the perfect-freehand method: offset left/right by the width at each point, round caps, streamline
  the input), cache it as a `Path2D` / `CGPath` per stroke version, and fill it once. Smoother
  edges, no visible joins, much faster redraws. Both sides check against a new
  `Fixtures/ink-outline.json` so the website and apps draw the same shape. 🔒 (look only; no data change)
- **Lower latency on the website:**
  - The live stroke canvas with `getContext("2d", { desynchronized: true })` (paints without
    waiting for the compositor; big win on iPad Safari and Chrome).
  - `getPredictedEvents()` to draw 1–2 frames ahead and replace the guess when real points arrive.
  - `pointerrawupdate` where supported. Measure first (see §3.6), then keep what helps.
- **Tiles and a spatial index.**
  - Each page gets a grid index of stroke bounds. The eraser, lasso and scribble-to-erase test only
    nearby strokes instead of every stroke on the page (today they scan all of them).
  - Finished ink renders into 512 px tiles cached per zoom step (100 %, 200 %, 400 %…). Panning and
    zooming move bitmaps; only tiles a change touches are redrawn. This is what makes 1000 % zoom and
    huge whiteboards smooth.
  - Website: rasterise tiles in a Worker with `OffscreenCanvas` so the main thread only composites.
  - Mac: the same tiles as `CGLayer`s (it already caches finished ink as one bitmap).
- **Stabiliser and pressure curve** settings (per pen): smoothing slider (0 = raw, high = calligraphy
  steady), pressure curve (soft / normal / firm), minimum width. Synced in `settings.ink`.
- **Pencil hover preview** (M2+ iPads and Pencil Pro): show the tip and colour before touching.
  **Barrel roll** (Pencil Pro) turns the fountain and brush nibs. The user has an iPad Air M3 + Pencil Pro.
- Done when: drawing on the website at 120 Hz on the iPad feels the same as Safari's own Notes-like
  apps (latency target under 25 ms input-to-paint, §3.6), and a 2,000-stroke page pans at 60 fps.

### S2. Pens worth switching for **M**
- **Pen favourites**: up to 10 presets (tool + colour + size), one tap from the toolbar and the squeeze
  palette, synced. GoodNotes users live on these.
- **Pencil grain**: a texture for `pencil` strokes (a tileable noise pattern clipped to the outline), so
  pencil looks like pencil. GoodNotes' notebooks have pencil texture too ("not drawn yet" in
  GOODNOTES.md).
- **Dashed and dotted lines**, **arrows** on line shapes, **filled shapes** (fill colour on any closed
  shape, like GoodNotes' shape fills that Trove already reads).
- **Highlighter that stays under the writing** whatever the order (already blended "under";
  make sure lasso moves keep it under) and **straight-line highlighter** (hold to straighten).
- **Colour**: custom palettes, eyedropper, recently used, hex input.
- **Tape** (cover an answer, tap to peek): a new element type. 🔒

### S3. Editing that's faster than GoodNotes **M**
- **Lasso**: rotate handle (now resize only), flip, bring to front/back, lasso by type
  (ink / text / pictures), group, and an action bar: copy as image, convert to text, straighten,
  ask AI (§4), make flashcard (§S7), save as element.
- **Shapes**: arrows, stars, hearts, speech bubbles; shapes keep editable handles after snapping
  (move a corner, bend a line); connectors that stay attached when shapes move (good for diagrams).
- **Ruler and protractor** (ruler with angle readout; draw along it).
- **Inline text boxes in the apps** (today a sheet): type straight onto the page, with font, size,
  colour, bold/italic, bullet lists.
- **Elements library**: save any selection as a reusable element (sticker), with folders, synced like
  other records. Ships with a small set (arrows, checkboxes, dividers, planner stickers). 🔒 new kind.
- **Scribble-to-erase** stays opt-in; add **circle-to-select** (draw a loop and hold → lasso).

### S4. Notebooks, not just sketches **L**
GoodNotes is organised around notebooks; Trove's sketches are cards. Keep the card (it's what makes
search and connections work), and give sketches a notebook face:
- **Covers** (colours, patterns, a picture) and a **shelf view** for the Sketches section (cover grid,
  recently opened first, favourites). Cover = a field on the sketch item.
- **Outline / bookmarks**: name any page; a sidebar lists them; tap to jump. PDFs show their own outline
  (pdf.js and PDFKit both read it).
- **Links on pages**: lasso → "Link to…" a page, another notebook, or any Trove item (`[[` the same way
  notes link). Tapping follows it. Links show up in Connections and backlinks, so a handwritten page
  connects to notes, clips and files — something GoodNotes can't do.
- **Templates**:
  - Generated planners: daily / weekly / monthly for a chosen year, with page links between them
    (made in code, so no big template files).
  - Any PDF page or picture as a custom template, saved to a template library (synced).
  - More papers: music staff, handwriting practice (3-line), engineering, calendar grid.
- **Tabs and split view**: two notebooks side by side (website: split pane; iPad: second window via
  scenes; Mac: second window already exists for sketches).
- **Page tools**: copy pages to another notebook, insert pages from a PDF, scan pages with the
  camera (VisionKit on iPhone/iPad; website `getUserMedia` + edge crop), go-to-page, page thumbnails
  that include ink.

### S5. PDFs like a PDF app **M**
- **Text-aware highlighter**: drag across PDF text and the highlight snaps to the lines (pdf.js text
  layer on the website, `PDFSelection` in the apps). The highlighted text is saved with the highlight,
  so it's searchable and can become a quote item ("Quotes & Highlights" already exists).
- **Search inside a PDF** with hits highlighted on the page (website: pdf.js `getTextContent`; apps:
  `PDFDocument.findString`).
- **Index PDF text on the website**: today only Apple devices extract PDF text (`AppleEnricher.pdfText`).
  The website can do the same with pdf.js for typed PDFs and write `ocrText`, so PDFs added on the
  website are searchable without waiting for an Apple device.
- **Links and form fields** in PDFs work (tap a link; fill a form, saved as an element layer so the file
  still never changes).
- **Export**: keep "flatten" and add "as real PDF annotations" (ink annotations other PDF apps can
  still edit), saved as a new file version (`fileVersions`).

### S6. Handwriting that's text too **L**
- **Recognition with word positions**, not just page text. Store recognised words with their boxes
  (`inkWords`: text + rect per word, per page) so search hits highlight the exact spot on the page and
  "jump to" works. 🔒 new field.
  - iPad/iPhone/Mac: `PKStrokeRecognizer` (OS 27, now released; behind `#available`) for real
    stroke-based recognition; Vision on the page image as the fallback for OS 18–26.
  - Website: there's no on-device handwriting recognition in browsers. Options, in order of privacy:
    wait for an Apple device to sync (today's behaviour); or opt-in cloud recognition (the page is
    rendered to an image and sent to Claude through the relay, never stored). ❓ cloud AI is the user's call.
- **Convert to text**: lasso → text box with the recognised text (keep the ink until confirmed).
- **Spellcheck and word complete** on handwriting (underline misspelt words; suggest the rest of a
  word in grey ink). OS 27 recogniser first.
- **Maths**: recognise an equation, show the answer in handwriting-style ink (Apple's Math Notes API
  where available; else Foundation Models on the iPad / Claude when cloud AI is on).

### S7. Beyond GoodNotes **L**
- **Audio synced to ink** (the Notability feature GoodNotes users ask for):
  - Record while writing; each stroke already has `createdAt`, so playback lights up strokes in the
    order they were written and tapping a word jumps the audio there.
  - Audio is an encrypted attachment; a new `recording` field lists recordings with start times. 🔒
  - Transcribed on device (SpeechAnalyzer on OS 26+) or, if cloud AI is on, Whisper on Workers AI
    (already in `server/src/ai.ts`). The transcript is searchable and linked to the ink timeline.
- **Study mode**: lasso → flashcard (front = selection, back = what's under the tape or a typed
  answer); spaced repetition review in a Study view; "make flashcards from this notebook" with AI.
- **Presentation mode**: hide the UI, laser and a pen for annotating live, AirPlay / second screen,
  website full-screen.
- **Ink in notes**: a sketch block inside a Markdown note (`![[sketch-id#page]]`), drawn inline.
- **Shared notebooks** (later, needs shared keys, see §5.4): send a link, the other person draws too.
- **GoodNotes, completely**: sticky notes, rotated lasso items, audio, pencil texture (GOODNOTES.md
  "Not drawn yet"); bulk import of the whole GoodNotes backup folder keeping its folder tree, with an
  import report ("312 notebooks, 2 strokes unreadable"). ❓ needs a sample whiteboard and a notebook
  with audio from the user.

### S8. Drawing data that stays small 🔒 **M**
- Points are float32 × 4 in base64url: about 21 bytes per point, so a long stroke is several KB and a
  full notebook is megabytes of ops to download, decrypt, keep in memory and save.
- New points format `points2`: x/y as varint deltas at 1/20 pt, pressure as one byte, time deltas as
  varints. About 4–5 bytes per point, 4× smaller, no visible change. Readers accept both; writers
  switch once every client reads it. Fixture-checked in Swift and JS.
- **Page checkpoints**: a page whose strokes haven't changed for a while can be folded into one
  compressed "page snapshot" blob so opening a 200-page notebook doesn't replay 50,000 stroke records.
  Needs care with merges (strokes stay individually addressable inside the blob). Design first.

---

## 2. Search: faster and smarter

What's there: BM25 over weighted fields with a prefix match on the last word, in Swift
(`SearchIndex.swift`: postings + sorted vocabulary) and JS (`core/items.js`). The apps blend in
NLEmbedding semantic scores. The website's search was made fast this year (3–12 ms per keystroke for
3,000 items), but it still scores **every** item on every keystroke and scans every term of every
document for the prefix match. That won't hold at 30,000 items plus clips.

### Q1. The website gets a real index **M**
- Port the Swift design: postings (term → item ids) and a sorted vocabulary, so a query touches only
  the items containing its words, and prefixes are a binary search. Keep `items.js` and
  `SearchIndex.swift` in step with a shared `search-cases.json` (query → expected order).
- Score only candidates, keep the top 50 with a small heap instead of sorting everything, and render
  the first page right away.
- Run indexing and search in a **Web Worker**, so typing never waits on scoring. The UI shows the
  previous results until the new ones arrive (it already narrows from the previous results in the
  apps' clipboard; do the same for the main search).
- Target: under 5 ms per keystroke at 50,000 items + 50,000 clips (§3.6 benchmark).

### Q2. Better matching (both sides) **M**
- **Typo tolerance**: for words of 5+ letters, also match vocabulary terms one edit away (symmetric
  delete over the sorted vocabulary), scored lower. "recipie" finds "recipe".
- **Phrases**: `"exact words"` with term positions.
- **Operators**: `title:`, `in:folder`, `type:pdf`, `from:goodnotes`, `has:ink`, `has:audio`,
  `before:2026-01`, `after:`, `-word` to exclude, `#tag` (exists). Typed, and as filter chips.
- **Snippets with highlights**: show the matching sentence with the words bold (and for handwriting, a
  crop of the page around the word, from `inkWords`).
- **Search everywhere at once**: items, clips, handwriting, PDF text, audio transcripts and text
  boxes in one list grouped by kind, each with its jump-to spot.

### Q3. Search by meaning everywhere **M**
- **Apps**: vectors as `Float32` normalised once, scored with Accelerate (`vDSP_dotpr`) instead of a
  Swift loop over `Double`s; int8 quantised to cut memory 8×. Cache vectors on disk so they aren't
  rebuilt every launch. Combine keyword and meaning results with reciprocal rank fusion instead of
  adding scores.
- **Website**: there's no semantic search yet. Run a small embedding model in the browser
  (transformers.js with a quantised MiniLM/E5-small, ~25 MB, cached once, WebGPU when available) in
  the search Worker. Private: nothing leaves the device. Vectors cached in IndexedDB, encrypted.
- Indexes still don't sync (each device builds its own), as RESEARCH.md decided.

### Q4. A persisted index **S**
- The website rebuilds search docs on every load. Save the index (encrypted with a non-extractable
  key, like the other stored data should be, §3.2) and load it in one read; rebuild only changed items.
- The apps do the same with the `SearchIndex` value (Codable) next to the snapshot.

---

## 3. Performance everywhere

### 3.1 Sync and storage **L** 🔒
- **Snapshot to SQLite** (apps; already in NOTES "later"): `SyncEngine.Snapshot` is one JSON file with
  every op, encoded on every save. Move to SQLite (append ops, update rows) so saving costs what
  changed, not the whole vault. It's also where the 780 MB memory peak on the Mac came from.
- **Checkpoints / compaction**: a new device (or a website login) replays every op since the vault
  began. Add signed, encrypted **checkpoint segments** (the materialised records at an HLC) that
  devices write occasionally; new devices load the latest checkpoint then the ops after it. Old
  segments can then be pruned from the relay and iCloud. Needs a careful PROTOCOL.md section and
  fixtures; the biggest long-term speed win for opening the website.
- **Lazy loading on the website**: load records first, decode stroke points and big bodies only when
  something opens (stroke views are already cached per version; make the first decode lazy too).

### 3.2 The website **M**
- **Saving**: `Vault.save` writes the whole `ops` array to IndexedDB every time. Store ops in their
  own object store keyed by id (append only), so a save writes only new ops.
- **Encrypted at rest**: the decrypted ops sit in IndexedDB as plain JSON today. Encrypt them with a
  non-extractable AES-GCM key (the same rule PROTOCOL.md §7 sets for keys). Small cost, matters if
  the browser profile is ever copied. 🔒
- **Offline app** (NOTES "later"): a service worker that caches the app shell, pdf.js and fonts, so it
  opens instantly and without a connection, then syncs. Install as a PWA on the iPad home screen.
- **Startup**: split `app.js` (2,000 lines) and `draw.js` (1,600) so the drawing editor, viewers and
  importers load only when opened (`import()`); preload the next likely module when idle.

### 3.3 The apps **M**
- Launch time: open from the snapshot/SQLite without waiting for iCloud or the relay (measure with
  `os_signpost`; the first CI build with signposts gives numbers to beat).
- Memory: cap thumbnail and page caches by cost (`NSCache` with `totalCostLimit`); release PDF pages
  off screen.
- Battery: the drawing canvas runs at 120 Hz only while the Pencil is down; idle redraws stop.
  Sync loops back off when nothing changes (30 s → 5 min on battery).

### 3.4 The relay **S**
- Live sockets already hibernate (`acceptWebSocket`). Batch the "something new" pings when a device
  pushes many segments at once (one ping per push, not per segment).
- Cache-friendly static assets (`_headers` immutable hashes for vendor files).

### 3.5 Clipboard **S**
- Search over 50,000 clips with the same postings index as items (today `memmem` over folded text is
  fine up to ~20,000; keep it as the fallback).

### 3.6 Measure it, in CI **M**
Speed claims need numbers, or they come back.
- `web/test/bench.mjs`: a synthetic vault (50,000 items, 50,000 clips, a 500-page notebook with
  100,000 strokes) generated from a seed; times opening, search keystrokes, drawing a page, eraser
  hits, saving. Results written as JSON.
- A Chromium e2e that measures pen input → paint latency on the drawing canvas (`performance.now()`
  at the event, `requestAnimationFrame` after the paint).
- `swift test --filter Benchmarks` for `SearchIndex`, `RecordStore`, `InkGeometry`.
- A GitHub Actions job runs them on every push and fails if anything is more than 20 % slower than
  the stored baseline (`bench-baseline.json`).

---

## 4. AI

What exists: Apple Intelligence on the iPad (titles, summaries, tags, Ask Trove), Vision OCR on every
Apple device, NLEmbedding search, and an opt-in relay AI (`server/src/ai.ts`: Claude for enrich/ask,
Workers AI Whisper and embeddings). The relay key isn't set yet (costs money; the user's call).
Principles stay: **local first, cloud only when the user turns it on, never stored by the relay, every
AI result labelled with where it ran.**

### A1. Ask Trove everywhere **M**
- The website gets Ask Trove (apps have it): the device searches locally (keyword + meaning), sends
  only the top ~20 snippets to the relay, Claude answers with citations, tapping a citation opens the
  item at the right spot (page, clip, timestamp).
- Answers can be saved as a note with the citations as links.
- Cost control: Haiku by default (NOTES: "suggest `claude-haiku-5-5`"), a monthly cap on the relay
  (`AI_MONTHLY_LIMIT`), and a running total in Settings.

### A2. AI on ink and notes **M**
- On a lasso selection or a page: summarise, explain, convert to text, tidy into bullet points,
  make flashcards, solve the maths, translate.
- On a notebook: "summarise this lecture", "what did I write about X", "make a study sheet".
- On notes: continue writing, rewrite shorter/clearer, fix grammar, suggest `[[links]]` to existing
  items (uses meaning search, so works with no cloud AI too).
- iPad: Foundation Models for all of these (free, private). Other devices: cloud AI if on, otherwise
  the feature is hidden rather than broken.

### A3. Background intelligence **M**
- **Link suggestions**: "maybe related" (exists) upgraded with meaning scores; one-tap connect.
- **Digest**: a weekly note "what you saved, what you wrote, what you haven't opened" plus
  resurfacing ("on this day", NOTES "later").
- **Duplicates by meaning** (two saves of the same article from different URLs).
- **The iPad as the AI worker**: since only the iPad has Apple Intelligence, let it work through a
  queue of items other devices flag (`needsEnrichment` exists) while charging overnight
  (`BGProcessingTask`), so everyone benefits without cloud AI.

### A4. Claude working on your vault (MCP) **M**
See §5.2: an MCP server lets Claude Desktop, Claude Code and claude.ai read and add to Trove with
the user's permission. That's the most useful "AI" feature for very little code, because Claude does
the thinking and Trove only needs search, read and create tools.

---

## 5. Connecting Trove to everything else

The user didn't have a name for "the connection thing". Trove already uses **Connections** for the
links-and-graph feature, so it needs a different word. Suggestions ❓:
1. **Bridges** (recommended: short, says what it does; "Settings → Bridges → GitHub")
2. **Portals**
3. **Plugs**
4. **Channels**
5. **Hookups**

The rest of this section calls them **Bridges**. There are three kinds, and the encryption decides
which kind each bridge can be.

### 5.1 How bridges fit end-to-end encryption
- **Into Trove (one way)**: anything can *add* to Trove without being able to read it, because the
  inbox is sealed with the vault's public key (PROTOCOL.md §4). The relay already does this for
  email, GoodNotes WebDAV and the browser extension. So the relay can fetch things on a schedule
  (GitHub stars, RSS, a YouTube playlist) and seal them into the inbox. It sees only the public thing
  it fetched, never the vault. **This is the main pattern: safe, cheap, runs while devices sleep.**
- **Out of Trove / reading Trove**: needs the keys, so it must run on a device the user owns (the
  website, the apps, or a small program on a computer), or the user must deliberately share some data
  with a server (5.4).
- **Two way**: a device-side bridge that reads and writes (Obsidian mirror and Apple Notes bridge
  already work this way on the Mac).

### 5.2 Trove for Claude (MCP) **M**
An MCP server with tools: `search`, `read_item`, `read_page_text`, `list_recent`, `create_note`,
`save_link`, `add_to_folder`, `ask` (local search then return snippets for Claude to reason over).
- **Step 1, local** (recommended first): `trove-mcp`, a small Node program that reuses
  `web/public/core` (it already runs in Node for the tests). It joins the vault as its own device of
  kind `agent` with a setup code, keeps its keys in the OS keychain, and talks stdio to Claude Desktop
  and Claude Code. Works on the user's Intel Mac today. Scopes chosen at pairing: read only, or
  read + add; optionally limited to some folders. Revocable from Settings → Devices like any device. 🔒
  (new device kind)
- **Step 2, remote** (so claude.ai and the Claude phone app can use it): a remote MCP endpoint needs
  a server that can read the data. Two ways ❓:
  - The Worker hosts it (Cloudflare's MCP support) for a **shared space only** (5.4): Claude sees
    what's in the "Shared with Claude" folder and nothing else.
  - Or the user keeps a computer running `trove-mcp --http` behind a Cloudflare Tunnel (free); the
    keys never leave that computer.

### 5.3 Bridges worth building **M each unless noted**
| Bridge | Direction | Where it runs | What it does |
|---|---|---|---|
| **GitHub** | in | relay (cron) | Starred repos (README summary, language, topics) and your own repos' releases as link items; issues/PRs you're assigned or mention you; gists as notes. Token stored in the relay as a secret; read-only scopes. |
| **GitHub backup** | out | website/app | Optional export of notes as Markdown (and sketches as PDF) to a **private** repo the user picks, on demand or daily from a device. Plaintext leaves the vault, so it's off by default and explained. ❓ |
| **RSS / newsletters** | in | relay (cron) | Follow feeds; new posts land in a "Feeds" folder; email newsletters via email-in (needs a domain). |
| **YouTube / podcasts** | in | relay | Liked videos / a playlist with transcripts (Workers AI Whisper for podcasts if cloud AI is on). |
| **Readwise, Kindle, Notion, Raindrop, Pocket export** | in | website | Import UI on the website for parsers that exist in TroveCore (NOTES "later"); Raindrop/Pocket new. |
| **Telegram / Discord bot** | in | relay | Send a message, link or photo to the bot → sealed into the inbox. Saving from any phone without the app. |
| **Shortcuts / webhooks** | in | relay | A per-vault "add" URL with an inbox token (like the extension's), for Shortcuts, IFTTT, Zapier, scripts. **S** |
| **Calendar (ICS)** | in | relay | Meeting notes: a note template per calendar event, linked to it. |
| **Obsidian** | both | Mac app (exists) + `trove-mcp` | Mirror for non-Mac computers through the Node program. |
| **Link previews** | in | relay | The unfurl endpoint NOTES asks for: fetch title/image for links saved on the website (browsers can't fetch other sites). Optionally full-page archive with Cloudflare Browser Rendering (small free allowance; check limits). **S** |

All "relay (cron)" bridges share one piece: a `BridgeObject` Durable Object per vault with an alarm,
the bridge's settings (stored encrypted to the vault's public key where possible, or as relay
secrets for tokens), and a seal-into-inbox step. Build it once with RSS, then each bridge is small.

### 5.4 Shared spaces (later, needs design) **L** 🔒
A folder with its **own key** that the user can give to someone or something else: a friend
(shared notebook), a remote MCP for claude.ai, a public read-only page. Members get only that key.
This is how collaboration and remote AI work without breaking "the relay can't read your vault".
It's a real protocol change (per-space keys, key rotation when someone leaves), so it gets its own
design doc before any code.

### 5.5 Cloudflare: what to use and what it costs
Everything below fits the free plan for one person, except where marked.
| Service | Use | Free? |
|---|---|---|
| Workers + Durable Objects (SQLite) + R2 | Already the relay | ✅ |
| Cron Triggers / DO alarms | Bridges, price watches (exists) | ✅ |
| Workers AI | Whisper, embeddings, image captions | ✅ 10,000 neurons/day, then paid |
| Browser Rendering | Link previews of JS-heavy pages, page archiving | Small free allowance |
| Queues | Spread bridge work out | Paid plan only; DO alarms are enough |
| Email Routing | Email-in, digest emails | ✅ but needs a domain (~$10/yr) ❓ |
| Tunnel | Remote `trove-mcp` from a home computer | ✅ |
| Access / Turnstile | Extra sign-in in front of the website | ✅ (optional) |
| Analytics Engine | Anonymous speed numbers from the website (no content) | ✅ ❓ |
| Vectorize | **Not used**: it would need plaintext vectors on the server | — |

---

## 6. GitHub as the workshop

The repo already builds the apps on Actions (the user has no Apple Silicon Mac) and publishes the
`latest` release and SideStore source. More can be done there:
- **Issues for this roadmap**: one issue per item above (labelled `sketching`, `search`, `perf`, `ai`,
  `bridges`, size `S/M/L`), on a GitHub Project board (Now / Next / Later). Sessions then say "do
  #42" and close it in the commit.
- **Claude in GitHub** (`anthropics/claude-code-action`): comment `@claude` on an issue or PR and a
  run builds it and opens a PR, from the phone, without opening a session. Needs either an Anthropic
  API key (costs money per run) or a Claude subscription token from `claude setup-token` as a repo
  secret. ❓
- **CI additions**:
  - Run the relay, extension and web tests on every push on a Linux runner (today Actions builds the
    apps and runs only the TroveCore tests; the JS and relay tests run only in cloud sessions).
  - Benchmarks with a regression gate (§3.6).
  - Playwright screenshot tests of the website's main screens and the drawing editor, compared with
    stored images, so UI changes are seen.
  - A nightly e2e against the deployed relay (it's already run by hand after deploys).
  - Dependabot for `server/` and `web/` npm packages; CodeQL for the Worker.
- **Deploys from GitHub**: `wrangler deploy` in an Action on a tag or a manual "Deploy" button
  (`workflow_dispatch`), with the Cloudflare token as a secret, instead of only from cloud sessions.
  ❓ (the user said deploys happen when they say "publish"; a manual button keeps that.)

---

## 7. Everything else worth doing

### Capture
- **Web highlights**: the extension highlights text on any page; highlights become quote items linked
  to the page and re-appear when you visit it again. **M**
- **Reader view** saved with each article (Readability-style clean text, stored encrypted) so links
  still read when the page dies. **M**
- **Scan to Trove**: document scanner on iPhone (VisionKit) and the website (camera + crop). **S/M**
- **Voice notes** with transcripts on the iPhone (SpeechAnalyzer). **M**

### Notes
- The **TextKit 2 live Markdown editor** (NOTES "later") in the apps, and a richer editor on the
  website: checklists, tables, headings that fold, slash menu, paste images, sketch blocks (§S7). **L**
- **Daily note** and **templates** (meeting, journal, recipe). **S**

### Clipboard
- Pinboards with drag to reorder, snippets with placeholders (`{date}`, `{clipboard}`), paste as plain
  text, merge several clips into one. **M**

### Organise and resurface
- **Places map** (NOTES "later") from saved places and clip locations. **M**
- **Resurfacing**: "on this day", "you saved this 3 months ago and never opened it". **S**
- **Reminders on items** (local notifications; no push on a free Apple ID, so they fire on the device
  that set them, and the website shows them when open). **S**

### Security
- **Passkeys to unlock the website**: WebAuthn PRF derives the key that wraps the stored keys, so a
  copied browser profile can't open the vault. **M** 🔒
- **Key rotation** after removing a device (today removing a device stops its relay access, but it
  still has the vault key). **L** 🔒
- **Close the relay to new vaults** once the user has made theirs (NOTES manual step).

### Design
- The design direction is still open (A Glass, B Editorial, C Midnight; NOTES). Sketching and the
  notebook shelf (§S4) are the most visual parts, so pick before building S4. ❓

---

## 8. Suggested order

| When | What | Why first |
|---|---|---|
| **Now** (next 3–5 sessions) | S1 writing feel + tiles · Q1 website search index in a Worker · 3.6 benchmarks · 3.2 IndexedDB saving · S5 PDF text on the website | The things the user feels every day, on the client they use every day, with numbers to prove it |
| **Next** | S2 pens · S3 lasso/shapes/ruler · S4 notebooks (after the design pick) · Q2 matching · Q3 meaning on the website · A1 Ask Trove on the website · 5.2 `trove-mcp` local · 6 issues + CI | GoodNotes parity on the parts people compare first; Claude can use Trove |
| **Then** | S6 handwriting as text · S7 audio + study · S8 smaller strokes · 3.1 SQLite + checkpoints · 5.3 bridges (RSS, GitHub, bot, link previews) · A2/A3 | Beyond GoodNotes; the vault stays fast as it grows |
| **Later** | 5.4 shared spaces → collaboration and remote MCP · key rotation · passkeys · notes editor rewrite | Needs design docs and protocol changes |

Each step ships on its own, keeps the website and apps working, and updates NOTES.md.

---

## 9. Decisions for the user ❓
1. ~~Name for "the connection thing"~~ **Decided: Bridges.**
2. ~~Which iPad and Pencil~~ **Decided: iPad Air M3 + Apple Pencil Pro** (hover, squeeze, barrel roll and
   haptics all work). Everything must still work on any iPad and Pencil.
3. **Cloud AI on?** Setting the relay's Anthropic key costs money per use (pennies with Haiku and a
   monthly cap). Without it, AI features run on the iPad only, and website handwriting recognition
   waits for an Apple device.
4. **Claude in GitHub**: use a Claude subscription token (no extra cost) or an API key (pay per run),
   or skip it.
5. **Remote MCP for claude.ai/phone**: shared space on the Worker, a home computer with a Tunnel, or
   local only (Claude Desktop/Code) for now.
6. **GitHub backup of notes as Markdown** to a private repo: wanted? (Plaintext leaves the vault.)
7. **A domain** (~$10/yr) for email-in and digest emails: wanted?
8. **Design direction** (A, B or C) before the notebook shelf is built.
9. **Samples to test against**: a GoodNotes whiteboard and a notebook with audio (`.goodnotes`).
10. **Start with** the "Now" row as written, or put a different item first?
