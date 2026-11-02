# Trove master plan: improve everything, much faster, much less battery

_Written 2026-11-02 from a read of the code at 1a08372 and research into Paste, GoodNotes (and
Notability), Obsidian and Apple Notes (plus Bear, Craft and Raycast where they set the bar). The
user asked for "a large plan of a plurality of changes to improve everything about Trove …
everything is open to change … importantly massively increase performance of everything and battery
life in turn … this plan must not miss a thing"._

This plan comes after `docs/ROADMAP.md`. Most of that roadmap has landed: search index and
operators, outline ink, tiles, `points2`, pens, S3 editing, PDFs, bridges, trove-mcp, checkpoints,
SQLite local store, PowerPolicy, the battery round, and Ask with tools. Where an item below
continues a ROADMAP item, it says so. Don't redo what's done.

How to read it:
- IDs (**P3**, **N7**, **C4**…) let a session say "do P3". Sizes: **S** one session, **M** 2–3,
  **L** a round.
- **Apps first** (CLAUDE.md). The website gets an item only where it's marked 🌐 *cheap*.
- 🔒 touches the protocol or encryption: PROTOCOL.md, both cores and the fixtures change in the same commit.
- ❓ is the user's decision (collected in §13).
- ⚡ marks items whose main point is speed, and 🔋 items whose main point is battery.

---

## 0. The short version

1. **Stop rebuilding the whole library on every change** (P1–P4). Today one edit, a pulled op, an
   enrichment result or a handwriting read makes `AppModel.reload()` decode every item, sort them,
   rebuild the link graph and sidebar counts, copy the search index, diff Spotlight, re-embed and
   republish the widget. Make every layer incremental, driven by a set of changed ids from the engine.
   This is the biggest speed and battery win left.
2. **Wake the radio and the CPU less** (P8–P14): one batched request instead of one per segment,
   iCloud change notifications instead of directory walks, a Mac clipboard watcher that coalesces
   and sleeps, a live socket that hibernates, App Nap allowed, timers with tolerance, and big
   transfers on discretionary background sessions.
3. **Hold less in memory** (P5–P7): ops and text history out of RAM and into SQLite, compact list
   rows instead of full records, images decoded at display size.
4. **A real notes editor** (N1): TextKit 2 live Markdown with `[[links]]`, checklists, tables,
   collapsible headings, inline sketches and attachments. This is the largest gap against Apple
   Notes, Obsidian and Bear, and today it's a plain `TextEditor` (`Views/MarkdownEditor.swift`).
5. **Obsidian-grade navigation** (O1–O8): quick switcher, command palette, tabs and splits,
   backlinks with unlinked mentions, embeds, Properties, and **Bases-style table and board views**.
6. **Paste-grade clipboard** (C1–C12): pinboards, a paste stack everywhere, a predicted next paste,
   jump to history, paste transforms, privacy while screen sharing, pause timers.
7. **GoodNotes/Notability-grade notebooks** (G1–G12): notebook shelf and covers, outline, page
   links, audio synced to ink, Smart-Ink-style editing (insert space, reflow), study mode with
   spaced repetition, math, a zoom window and presentation mode.
8. **Prove it on CI** (Q1–Q5). The user has no Apple Silicon Mac, so XCTest performance tests and
   simulator UI tests on the macOS runner are the only way to catch regressions before the user sees them.

---

## 1. What the others do, and where Trove stands

### 1.1 Paste (clipboard)
Shipped features, from Paste's update feed: iOS companion with synced history and pinboards (2018),
editing and renaming clips (2020), Siri Shortcuts, link previews, **Paste Stack** (paste a sequence in
order), Paste Keyboard for iOS (2022), a rebuilt Mac app with compact mode (2023), item titles and
multi-select on iOS, **Advanced Pause** (pause collection for a while), images pasted as files,
previews and editing for every type (2024), **Shared Pinboards** with a rebuilt sync engine (2025),
Paste 6 with Liquid Glass, **privacy controls for screen sharing**, Apple Intelligence Writing Tools,
**Power Search** (2025), **pinboard filters** on search, **Jump to History** from a result, **Paste
MCP** for Claude and Codex, **Intelligent Clipboard** that suggests what you'll paste next, and
**iPhone Duo** side-by-side on the foldable (2026).

| Paste | Trove today | Plan |
|---|---|---|
| Pinboards | Imported as tags only | **C1** real pinboards |
| Paste Stack | In the Mac palette (`ClipsView` state) | **C2** everywhere, plus a "collect" mode |
| Intelligent Clipboard | ❌ | **C3** on-device ranking by target app, time and recency (no AI) |
| Jump to History | ❌ | **C4** |
| Pause with a timer | Partly (enable toggle) | **C5** |
| Screen-sharing privacy | ❌ | **C6** `sharingType = .none`, hide previews while recording |
| Writing Tools on clips | ❌ | **C7** (iPad free; elsewhere your own AI) |
| MCP | trove-mcp has items | **C8** add clipboard tools |
| Shared pinboards | ❌ | Needs shared spaces (**S6**) |
| Keyboard + Shortcuts | ✅ keyboard, partial intents | **X3** App Intents for every clip action |
| Compact mode, number keys, Quick Look | Partial | **C9** |
| Foldable iPhone layout | ❌ | **D6** |

### 1.2 GoodNotes 6 (and Notability)
GoodNotes 6 (2023) added on-device spellcheck for handwriting, word complete, AI math checking and
converting equations, Windows, Android and web versions, a template marketplace, and study sets.
In 2024 it added **Ask Goodnotes**, **Smart Ink** handwriting editing (move, reflow, convert,
restyle) and **Math Assist** (write `=` after an expression to get the answer). It also has audio
recording, notebooks with covers and a shelf, an outline, hyperlinks, a zoom window, presentation
mode, elements, tape, shapes, lasso, a text-snapping highlighter and collaboration. **Notability**'s
strength is **audio synced to ink**: tap a word and it plays what was said, plus transcripts. Both
added more AI in 2026. No GoodNotes 7 has been announced.

| GoodNotes/Notability | Trove today | Plan |
|---|---|---|
| Notebook shelf, covers | ❌ sketches are cards | **G1** |
| Outline, bookmarks, page links | PDFs' own only partly | **G2** |
| Templates, planners | 17 papers | **G3** generated planners, any PDF as template |
| Audio synced to ink | ❌ (strokes have `createdAt`) | **G4**, Trove's chance to beat GoodNotes |
| Smart Ink: insert space, reflow, restyle | Lasso move/resize/rotate/straighten | **G5** |
| Spellcheck, word complete | ❌ | **G6** (OS 27 recogniser) |
| Math Assist | ❌ | **G7** |
| Study sets | Flashcards note via AI | **G8** spaced repetition (FSRS) |
| Zoom window | ❌ | **G9** |
| Presentation mode | Laser only | **G10** |
| Ask over notebooks | ✅ Ask reads pages, sections | **A3** answers point at the exact page square |
| Collaboration | ❌ | **S6** shared spaces |
| Whiteboard (endless) | ✅ endless canvas | **G11** whiteboard speed at 10k strokes |
| Typed documents | Notes | **N1** |

### 1.3 Obsidian
Local Markdown files, `[[wikilinks]]`, backlinks with **unlinked mentions**, graph and local graph,
**Canvas**, **Bases** (2025, a core plugin that turns notes into a database with table and card
views; a **kanban** view landed in v1.14.4, October 2026), **Properties**, outline, tags with nesting,
daily and periodic notes, templates, **quick switcher**, **command palette**, tabs, splits and
workspaces, embeds/transclusion (`![[note#heading]]`), block references, aliases, file recovery,
Publish, Sync, the Web Clipper and plugins. Its weak spot is big vaults: 2026 changelogs fix freezes
in heading search, input lag from properties being recomputed in the background, and slow tree
views. **Trove's version of each must be incremental from day one** (it's the same trap as P1).

| Obsidian | Trove today | Plan |
|---|---|---|
| Live-preview Markdown editor | Plain `TextEditor` | **N1** |
| Backlinks + unlinked mentions | "Mentioned in" / "Maybe related" | **O4** linked/unlinked panes, "Link it" |
| Quick switcher, command palette | Type to search | **O1**, **O2** |
| Tabs, splits, workspaces | Separate windows | **O3** |
| Embeds, block refs, aliases | ❌ | **O5** 🔒 |
| Properties | Item fields | **O6** user properties 🔒 |
| Bases (table/cards/kanban) | Smart collections | **O7** 🔒 |
| Canvas | Endless sketch canvas | **O8** boards of cards |
| Plain files | Obsidian mirror (Mac) | **I4** two-way, more platforms |
| Plugins | ❌ | **X3/X4** App Intents and Shortcuts as the extension point (no code plugins) |

### 1.4 Apple Notes (iOS 18 → 26)
Tags and **smart folders**, Quick Note, pinned notes, **locked notes**, gallery view, the attachments
browser, document scanning, **audio recording with live transcripts and summaries** (iOS 18),
**Math Notes**, **collapsible headings**, highlight colours, checklists that sort ticked items down,
**links between notes** (`>>`), tables, mentions and an activity view in shared notes, Writing Tools,
Recently Deleted, and in iOS 26 / macOS Tahoe **Markdown import and export** plus the adaptive toolbar
and Liquid Glass.

| Apple Notes | Trove today | Plan |
|---|---|---|
| Rich editor with tables, checklists, headings that fold | Plain editor | **N1** |
| Quick Note anywhere | ⌥Space is the clipboard; share sheet | **X1** Quick capture everywhere (hotkey, Control Center, Action button, Lock Screen) |
| Locked notes | ❌ | **S3** 🔒 |
| Audio with transcripts and summaries | Voice note (`CaptureView`), Transcriber | **G4/N9** |
| Math Notes | ❌ | **N10** |
| Recently Deleted | Tombstones, no view | **N11** |
| Attachments browser, gallery view | Card grid | **D3** |
| Markdown export (iOS 26) | Apple Notes import via AppleScript (Mac) | **I1** also accept Notes' Markdown export and share sheet on iPad |
| Scan documents | ROADMAP §7, not built | **X5** |

### 1.5 Others worth borrowing from
- **Bear**: a beautiful TextKit editor, "hide Markdown" mode, tags in the text with nesting, many export formats. Feeds **N1**, **N4** and **I3**.
- **Craft / Notion**: a slash menu, blocks you can drag, page covers. Feeds **N3** and **G1**.
- **Raycast**: clipboard history with very fast fuzzy search, OCR in images and a local-only
  encrypted store. Feeds **C9**; Trove already has OCR and the encryption.

### 1.6 Where Trove already wins (keep and advertise)
End-to-end encryption everywhere. Notes, clips, files, sketches, PDFs and links in one place, with one
search. GoodNotes notebooks opened and edited without GoodNotes. Ask over everything with a cost
meter. It works without a paid developer account. A full website editor for any browser. Bridges
(RSS, GitHub, Telegram, webhooks) that seal into the inbox while devices sleep.

---

## 2. Performance and battery: the architecture (the main event)

### Targets (set now, measured by **Q1–Q4**)
| What | Target | Today (best known) |
|---|---|---|
| Cold launch to first usable list (iPhone, 20k items) | **< 400 ms** | Waits on engine load and a full `items()` |
| A single local edit → screen updated | **O(changed)**, < 5 ms of main-thread work | O(N): decode, sort, graph, counts, index copy |
| Search keystroke (50k items + 50k clips) | **< 5 ms p90** | 3.9 ms median, 20 ms p90 (web bench) |
| Memory at 50k items (iPhone) | **< 250 MB** | All ops + text history + records in RAM (780 MB Mac peak was seen) |
| Mac idle wakeups with Trove running | **< 1 per second**, App Nap when hidden | 2.5/s clipboard timer + 25 s socket ping + sync loop |
| Requests per sync that pulls 50 segments | **1–2** | 51 (list + one GET each) |
| iPad: 1 hour of writing, extra drain from Trove | **≤ PencilKit's alone + 2 %** | Measured by the user (Settings → Battery) |
| Spotlight work per launch | **0** when nothing changed | Re-indexes every item (in-memory map) |

### P1. A change feed: incremental everything ⚡🔋 **L**
Today `SyncEngine.observe` says only "something changed". `AppModel.reload()`
(`App/Sources/Model/AppModel.swift:377`) then compares `stamp(of:)` strings and, when they differ:
- `library.items()` maps **every** item record through `Item.init` and sorts them all (`Library.swift:18`);
- `Links.graph(loaded)` and `counts(...)` walk every item;
- the search index is copied out of the actor (a large value);
- `semantic.update(snapshot)`, `SpotlightIndexer.index(items)` and `publishWidget()` each walk them again.

Enrichment and handwriting reading change one item at a time, so a background batch of 200 runs
this 200 times.

Plan:
1. `RecordStore.apply` already knows which records each op touched. Collect them into a
   **`ChangeSet { upserted: Set<id>, removed: Set<id>, kinds: Set<String> }`** per apply, merged
   until someone reads it. `SyncEngine.changes(since token)` returns the merged set and a new token
   (a monotonic counter, not the HLC string).
2. `Library` keeps **sorted id arrays per view** (all, per folder, per kind, per smart collection),
   updated by binary insert/remove for the changed ids, instead of `filter` + `sort` over everything.
3. The link graph (`Links`) becomes a maintained structure: outgoing links per item plus a reverse
   map. A changed item updates only its own edges. Counts per folder and kind are counters adjusted
   by deltas.
4. The search index (`SearchIndex`/`TermIndex`) already updates per item. Stop copying it to the
   main actor: search runs **inside** an index actor and returns hits (P4).
5. Spotlight, the widget and semantic vectors take the `ChangeSet`, never the whole list (P6).
6. `AppModel` applies a ChangeSet to its observable arrays with minimal diffs, so SwiftUI
   re-renders only the rows that changed (P3).
7. Coalescing: enrichment, handwriting reading and the AI keywords write through one batched
   transaction (`library.batch { … }`), so 200 results give **one** ChangeSet and one UI update.
- Tests (Linux): a ChangeSet fixture for every op type (field set, text edit, delete, undelete,
  checkpoint load, rebuild after out-of-order ops: a rebuild reports "everything").
- Done when a 50k-item vault takes < 1 ms of main-thread time for one edited note.

### P2. Compact list rows instead of full records ⚡ **M**
`Item` wraps a whole `Record` (every field as `JSONValue`, every text in full, thumbnail JSON), and
its properties re-parse on every access (`Item.kind` parses an enum each time it's read by a sort or
filter). Lists need ~10 fields.
- **`ItemRow`**: id, displayTitle (≤ 80 chars), kind, category, createdAt, updatedAt, folderId,
  flags (pinned, inked, aiHidden, hasFile, conflict), a thumbnail key, a 140-char snippet. Built once
  per changed item (P1), stored in the per-view arrays, `Equatable` so rows skip redraws.
- The full `Item` loads only when opened (`library.item(id)`).
- The thumbnail is referenced by a content hash, never carried in the row (P7).
- Memory goes from whole records × N to ~300 bytes × N on the list side.

### P3. SwiftUI that redraws less ⚡🔋 **M**
`AppModel` is one `@Observable` with dozens of properties; `MainView.swift` reads `model.` 151 times.
Any view that touches `items`, `searchResults` or `dataVersion` re-evaluates on any change.
- Split into focused observable stores: `LibraryStore` (rows per view), `SearchStore`,
  `SyncStatus`, `ClipboardStore` (exists), `SelectionState`, `AIState`. Views take the smallest one
  they need. `dataVersion` disappears (P1 gives precise invalidation).
- Row views take `ItemRow` values (Equatable) and no model reference.
- `LazyVGrid`/`List` get stable ids, no `AnyView`, and no `GeometryReader` per cell. Card images load
  through `.task(id:)` (exists) from the decoded-image cache (P7).
- Debug builds log `Self._printChanges()` behind a flag. CI UI tests (**Q3**) count body evaluations
  with signposts.
- Settings: no work in `body`. Totals (AI usage, battery counters) are computed when the data
  changes, not when drawn (Activity already does this; do it everywhere).

### P4. Search inside its own actor, saved in binary ⚡🔋 **M**
- `SearchService` actor owns `SearchIndex` + `ClipIndex` + vectors. Queries go in, the top 60 hits
  plus snippets come out. Nothing big crosses actors.
- Saving: today `saveSearchIndexSoon` JSON-encodes the **whole** index after a minute of quiet
  (`AppModel.swift:705`). Replace it with a binary format (varint postings, front-coded vocabulary)
  in the SQLite file as an **append log of changed documents** plus an occasional compaction. Load it
  with one read. Fixture: the same snapshot read by Swift and JS stays possible, but optional, since
  the website keeps its own.
- Semantic vectors (`SemanticIndex`) go into the same SQLite file as `BLOB` rows per item
  (Float16 or int8, ROADMAP Q3), updated per changed item, never rewritten whole.
- Keystrokes: the first letter searches only titles and tags (tiny posting lists). From the second
  letter on, the full index, narrowing from the previous result set when the query only got longer.
  That hits the 5 ms p90.

### P5. Ops and text history out of memory ⚡🔋 **L** 🔒(local only)
`RecordStore` keeps **every op** since the checkpoint in `ops: [Op]`, `opIds`, and `history`, a map
of sha256 → full text for **every version of every text field**, so text merges can find their base.
For a notes-heavy vault that's many copies of every note in RAM.
- Records stay in memory (or move to SQLite as rows, step 3). Ops live in `LocalDatabase` (already
  saved there) and are read back only for a rebuild, which happens on out-of-order arrival and then
  replays from SQLite in HLC order with a cursor, not from an array.
- `history`: keep only bases newer than the **frontier every device has acknowledged** (the newest
  checkpoint every live device has read), and keep them in SQLite (`texthist(record, field, sha,
  text)`), fetched on a miss. A text op whose base was pruned falls back to the conflict path,
  which already exists and never loses text.
- Step 3 (later, **L**): records themselves as SQLite rows (`records(id, kind, fields BLOB, texts
  BLOB, updated)`) with the in-memory map as a bounded cache. That makes launch O(1): open the file
  and show rows (P15). It's the end state for 100k+ items.
- Fixtures: a rebuild from SQLite gives byte-identical records to the in-memory path
  (`RecordStoreTests` over every interop fixture).

### P6. Spotlight, widgets and Live Text off the hot path 🔋 **S**
- `SpotlightIndexer.indexed` is an in-memory dictionary (`SpotlightIndexer.swift:11`), so **every
  launch re-indexes every item**. Persist `id → updatedHLC` in SQLite, or better, use
  `CSSearchableIndex`'s `beginBatch()`/`endBatch(withClientState:)` with the ChangeSet token as client
  state, so a launch resumes from where it was.
- Bulk Spotlight re-indexing (first run, rebuilds) only on the charger or idle (`BGProcessingTask`);
  single changes are indexed right away.
- `CSSearchableItemAttributeSet`: set `contentType` per kind (image, PDF, URL), `thumbnailURL`, and
  `domainIdentifier` per folder, so deleting a folder deletes its entries in one call.
- Widgets: reload a timeline only when what it shows changed (done for counts; do the same for
  recents). Interactive widget buttons (iOS 17) for "New note" and "Paste clip" (**X1**).

### P7. Images decoded at the size they're shown ⚡🔋 **M**
- Thumbnails: `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
  equal to the cell's pixel size (never decode a 12 MP photo to show 220 pt). On iOS 15+,
  `UIImage.preparingThumbnail(of:)` off the main thread.
- Two caches: in memory, the `NSCache` capped by cost (exists); **on disk**, decoded thumbnails as
  HEIC/JPEG keyed by content hash and size (`Caches/thumbs/`), so scrolling after a relaunch never
  decrypts the original.
- Prefetch the next screen of cards in the scroll direction (`onScrollTargetVisibilityChange` /
  `onScrollGeometryChange`, iOS 18). Cancel prefetches when scrolling stops.
- PDF and GoodNotes covers: rendered once per file version, cached on disk, never at launch.
- Clip images: the palette shows a 2× thumbnail made at capture time (stored with the clip), not the original.

### P8. The Mac clipboard watcher: coalesce and sleep 🔋 **S**
`ClipboardWatcher` (macOS) runs a 0.4 s repeating `Timer` in common modes with no tolerance, for as
long as the app runs: 9,000 wakeups an hour, and it blocks App Nap.
- `timer.tolerance = 0.1` (Apple's energy guide: at least 10 % lets the system coalesce wakeups).
- **Adaptive interval**: 0.3 s for 10 s after a key or mouse event in another app (watch
  `NSEvent.addGlobalMonitorForEvents` for ⌘C only, which needs Accessibility, already granted for
  pasting), otherwise 1 s, and 2 s after 5 min with no user input
  (`CGEventSource.secondsSinceLastEventType`).
- **Stop entirely** while the screen is asleep or locked or the Mac sleeps
  (`NSWorkspace.screensDidSleepNotification`, `willSleepNotification`, `sessionDidResignActive`).
  Check once on wake.
- When the change count moves, do the type checks and reads on a background queue (NSPasteboard is
  thread-safe for reads), so the main thread never pays for a big TIFF → PNG conversion.
- Images: convert TIFF → PNG/HEIC off the main thread, and skip the conversion when an identical
  hash was just captured.

### P9. Sockets and polling that let devices sleep 🔋 **M**
- **Mac**: `LiveConnection` pings every 25 s (`LiveConnection.swift:40`). The relay already hibernates
  sockets, and Cloudflare closes idle sockets after ~100 s. Use `URLSessionWebSocketTask.sendPing`
  every 60 s with timer tolerance, and close the socket while the screen is asleep (sync once on wake).
- **Polling when live**: while the socket is connected, the sync loop's safety poll becomes 10 min
  (5 min on the charger). Pings do the real work. When the socket is down, use today's backoff.
- **iOS**: the socket is closed in the background (done). In the foreground on battery and idle
  (no touches for 2 min), close it and poll every 2 min. Touch or Pencil reopens it.
- **App Nap (Mac)**: never hold `beginActivity(.userInitiated)` outside real work. Wrap sync,
  import and enrichment in `ProcessInfo.performActivity(options: .background)`, so the app naps when
  hidden.
- Timers everywhere get `tolerance`. `Task.sleep` loops become `Task.sleep(for:tolerance:)` (Swift
  `Clock.sleep(until:tolerance:)`), e.g. the sync loop, the updater and the price-watch cadence.

### P10. One request instead of fifty 🔋⚡ **M** 🔒(relay endpoint)
- `RelayClient.segments(after:)` lists, then each segment is a separate `GET` (`RelayClient.swift:220`).
  Add **`POST /v/:vault/segments/batch`** (a list of refs in, a length-prefixed stream of segment
  bytes out, max 8 MiB) and **`GET segments?after=…&include=bytes`** for small pulls. The relay
  serves them from DO SQLite/R2 in one response. One radio wake per sync instead of N. 🔒 PROTOCOL.md
  §4, relay tests, and both clients (Swift and web) with a fallback for older relays (404 → per-segment).
- Pushes: several pending segments go in **one** `POST segments/batch` the same way.
- Blobs: upload big attachments with a **background `URLSession`** (`isDiscretionary = true` for
  non-urgent ones), so iOS schedules them on Wi-Fi and the charger and the app needn't stay awake.
- HTTP: one shared `URLSession` with HTTP/2 or 3 (check that every client reuses it), `waitsForConnectivity`,
  and `allowsConstrainedNetworkAccess = false` for bulk transfers in Low Data Mode.
- Responses: `ETag`/`If-None-Match` on `ai/status`, settings and bridge lists (304s are almost free).

### P11. iCloud Drive without directory walks 🔋⚡ **M**
`FolderTransport.listSegments()` walks every device folder on every sync round
(`FolderTransport.swift:65`), and on iOS each walk can wake iCloud's daemon.
- Watch with **`NSMetadataQuery`** on the ubiquity scope (`NSMetadataQueryUbiquitousDocumentsScope`,
  predicate on `.sync/`). It reports added and changed files with no polling, and it's the documented
  way. On the Mac, add an `NSFilePresenter` on `.sync/`.
- Each device also writes a tiny **`head`** file (its last seq). A round reads N small heads and lists
  a folder only when its head moved.
- Downloads: `startDownloadingUbiquitousItem` only for segments not yet applied, and never for
  blobs until they're opened (attachments stay "in the cloud" until needed, like Optimise Storage).
- Coordinated writes stay (exists). Batch them: one `NSFileCoordinator` call per round with
  `prepare(forReadingItemsAt:…)`.

### P12. Background work only when it's free 🔋 **M** (continues ROADMAP 3.7)
- Every bulk job (OCR backlog, re-embedding, AI keywords, Spotlight rebuild, checkpoint writing,
  thumbnail regeneration, segment pruning) goes through **one `WorkScheduler`** in TroveCore with
  per-job budgets and the `PowerPolicy` gates. Apps run it from `BGProcessingTask`
  (`requiresExternalPower = true`) and from `BGContinuedProcessingTask` (iOS 26) for user-started
  long jobs ("Read all past handwriting", imports) with system progress UI.
- **Content hashes**: never OCR, embed or AI-read the same bytes twice (a SHA-256 → result cache in
  SQLite). Duplicate screenshots and re-imported files become free.
- Vision: `.fast` first, `.accurate` only for pages whose fast pass found text but low confidence.
  Regions of interest only for changed page tiles (the per-page signature exists, so go per tile).
- NaturalLanguage embeddings: batch 64 at a time on one `NLEmbedding` instance (load it once per
  process, ~50 ms otherwise).
- Foundation Models (iPad): one `LanguageModelSession` reused for a batch with `prewarm()`, and
  guided generation (`@Generable`) to get exact fields without re-asking.

### P13. Drawing: the last mile ⚡🔋 **M** (continues S1/S8)
- **Mac**: finished ink as **`CALayer` tiles** (512 px per zoom step) like the website, instead of
  one bitmap redrawn on zoom. The live stroke on a small `CAShapeLayer`.
- **iPad**: PencilKit draws, but Trove's overlay (lasso, eraser hover, text, tape) still redraws
  whole layers on some moves. Finish ROADMAP 3.7 item 11: per-shape `CAShapeLayer`s, no SwiftUI in
  the per-move path.
- **Page checkpoints** (ROADMAP S8, "design first"): fold a quiet page's strokes into one
  compressed blob addressed by stroke ids, so opening a 200-page notebook reads 200 blobs, not
  50,000 records. Write the design section in PROTOCOL.md first. 🔒
- **Lazy pages**: decode strokes only for pages within ±2 of the viewport. Page thumbnails come
  from the cached preview, not a re-render.
- **ProMotion**: 120 Hz only while the Pencil is down or during a scroll or zoom (`CADisplayLink.preferredFrameRateRange`), 60 Hz or less otherwise (exists in part; check every display link).
- Big whiteboards (GoodNotes): a quadtree instead of a uniform grid when a page is > 20k × 20k pt.

### P14. Network AI that costs less time and money 🔋 **S**
- Prompt caching on every request (exists for Ask). Do the same for keyword and handwriting
  batches: a stable system prompt first, then the batch.
- Requests go only on Wi-Fi or the charger for background AI (`allowsExpensiveNetworkAccess = false`).
- The AI keywords run asks for the token count first and skips items whose brief didn't change (exists; keep it).

### P15. Launch in under 400 ms ⚡ **M**
- Order: show the window with a **row cache** (the first 200 `ItemRow`s of the last view, a small
  file written at background) at once. Open SQLite and the engine in a detached task, then swap in live rows.
- The Keychain read (`secrets` item on the Mac, already cached) happens in parallel with SQLite open.
- Nothing at launch walks all items: Spotlight (P6), semantic vectors (P4), inked layers (P1 keeps
  an "inked items" set up to date) and Apple Notes checks are deferred 10 s or until idle.
- Measured on CI by `XCTApplicationLaunchMetric` (**Q3**) with a generated 20k-item vault.

### P16. Memory budgets and leaks ⚡ **S**
- Budgets per cache with `totalCostLimit`: thumbnails 40 MB (iPhone) / 120 MB (Mac), PDF pages 60
  MB, ink tiles 80 MB. Purge on `didReceiveMemoryWarning` and when backgrounded.
- `PDFDocument` and GoodNotes parsers released when their window closes (check retain cycles in
  `PDFReader` and `FileViewer` with the Memory Graph in a CI UI test, `XCTMemoryMetric`).
- Big blobs: stream decryption chunk by chunk to a temp file (or straight into `PDFDocument`/AVPlayer
  via a resource loader) for files > 20 MB instead of holding all the bytes. TRV1 is already 64 KiB
  chunked AEAD (PROTOCOL.md §2), so this needs no protocol change, only a streaming reader in
  `TRV1.swift` with random access by chunk.

### P17. The website (secondary, 🌐 cheap only) ⚡ **S each**
- OffscreenCanvas tile rendering in a Worker (ROADMAP leftover).
- The batched segment fetch (P10) in `core/vault.js`.
- `content-visibility: auto` on long lists and the card grid. Images with `decoding="async"` and
  `loading="lazy"`.
- The ChangeSet idea (P1) for `app.js` renders: re-render only changed cards.

### P18. The relay ⚡ **S each**
- The batched segment endpoints (P10).
- Prune segments covered by a checkpoint every device has read (NOTES "Open"): the vault DO knows
  each device's last checkpoint read. Keep 30 days of history as a safety net. 🔒
- Cache headers for the app shell: done; add `immutable` for hashed vendor files (check).
- Price watches and bridges: one alarm per vault that runs everything due, not one per watch (check `bridges.ts`).

---

## 3. Notes: an editor that beats Apple Notes and Obsidian

### N1. TextKit 2 live Markdown editor **L**
The single biggest product gap. Built on `NSTextView`/`UITextView` with TextKit 2
(`NSTextContentStorage` + `NSTextLayoutManager`), viewport-based so a 50k-word note costs only what's
on screen.
- **Storage stays Markdown** (sync, merge, search and the website don't change). The editor
  styles Markdown live: syntax characters fade or hide away from the cursor (Bear's "hide
  Markdown"; Obsidian's live preview).
- Headings (H1–H3) **that fold** (Apple Notes), bold/italic/strike/highlight (`==text==` with
  colours), inline code, code blocks with syntax colours (a small tokenizer per language, no
  WebView), quotes, callouts (`> [!note]`), dividers.
- **Checklists** you tap (exists in the data, PROTOCOL.md §12), ticked items optionally sort down,
  nested lists with Tab/⇧Tab, and drag handles to move a line or block.
- **Tables** (Markdown pipe tables) edited as a grid: Tab moves cells, and rows and columns can be added.
- **`[[` autocomplete** over titles with aliases (O5), `#` autocomplete over tags, `@` for dates
  ("@tomorrow" → a date chip that can make a reminder, **N8**).
- **Inline attachments**: images, PDFs (first page), sketches (`![[sketch#page]]` drawn live from the
  ink tiles), audio with a player, files as chips. Paste or drop puts them in place.
- **Writing Tools** come free with `UITextView`/`NSTextView` on Apple Intelligence devices (the iPad);
  set `writingToolsBehavior = .complete`. Elsewhere the existing note AI menu (your own AI).
- Find and replace, word count, a focus mode and typewriter scrolling, and spellcheck and
  autocorrect (system).
- Performance: style only the edited paragraphs (TextKit 2 paragraph-level invalidation); parse
  Markdown incrementally per paragraph; never re-style the whole note per keystroke. Typing latency target < 8 ms at 50k words.
- The website keeps its editor and gets checklists, tables and `[[` autocomplete only (🌐 cheap).

### N2. Outline, headings and navigation **S**
An outline pane (headings) for long notes, with click to jump. Fold all and unfold all. ⌘↑/⌘↓ jump between headings.

### N3. Slash menu and Markdown shortcuts **S**
`/` opens a menu: heading, checklist, table, code, quote, callout, divider, sketch, image, file,
date, link to note, template. Typing `- [ ]`, `1.`, `>` or `---` converts as you type.

### N4. Tags that are part of the text **S**
`#tag` and nested `#area/project` in the body count as tags (Bear/Obsidian). There's a tag tree in
the sidebar, and you can rename a tag everywhere at once (one batched transaction, P1).

### N5. Templates with variables **S** (continues PROTOCOL.md §12)
`{{date}}`, `{{time}}`, `{{title}}`, `{{clipboard}}`, `{{cursor}}`, plus date maths
(`{{date+7d:yyyy-MM-dd}}`). Templates for weekly and monthly notes (periodic notes, Obsidian). A
folder can have a default template.

### N6. Daily, weekly and monthly notes **S**
Weekly and monthly next to Today's note. A calendar strip on the Today screen with dots on days
that have notes, clips or sketches ("what did I do on Tuesday?").

### N7. Version history you can browse **S**
Versions exist (`fileVersions`, text history). Add a timeline slider for any note ("as it was on
…"), a diff view, and restore. It reads from the op log in SQLite (P5) on demand.

### N8. Reminders and dates on notes and items **M**
Local notifications (no push on a free Apple ID): a date chip in a note or "Remind me" on any item.
It fires on the device that set it and shows in a Reminders section on every device.
Optionally creates an EventKit reminder (Reminders app) instead. 🔒 new field `remindAt`.

### N9. Audio notes with transcripts and summaries **M**
`SpeechAnalyzer` (OS 26) for live transcription on every device (on-device, free). The transcript is
searchable, timestamped words let you tap a word and play from there, and there's a summary
(Foundation Models on the iPad, otherwise your own AI if on). The same engine powers **G4**.

### N10. Math in notes **M**
A line ending in `=` evaluates (`12*4.5 =` → `54`). Variables (`rent = 900`) persist down the note,
units and currency come from a fixed table (no network), and percentages work. It's a small
expression parser in TroveCore (tested on Linux) shared with **G7** for handwriting.

### N11. Recently Deleted **S**
A view of tombstoned items from the last 30 days with Restore (an undelete op) and Delete Now
(blob purge). Today deletes are invisible and final from the user's side.

### N12. Pinned notes, sorting and views **S**
Pin to top per folder, sort by created/edited/title, list or gallery (**D3**).

---

## 4. Navigation and organisation: Obsidian's best ideas

### O1. Quick switcher (⌘O / iPad keyboard) **S**
Fuzzy match over titles and aliases from the title-only postings (P4), recent first, ⏎ opens and ⌘⏎
opens in a new tab. If nothing matches, ⇧⏎ creates a note with that title.

### O2. Command palette (⌘K) **M**
Every action (new note, new sketch, move to folder, toggle AI visibility, export, settings pages,
sync now, …) is registered once as a `TroveCommand`, the same list that feeds App Intents (**X3**)
and the menu bar. Fuzzy search with shortcut hints and recents.

### O3. Tabs, splits and workspaces **M**
Mac: native window tabs plus a split editor (two items side by side, such as a PDF and a note).
iPad: two panes in the detail column, multiple scenes (exists for sketches; open any item in a new
window). Workspaces save open tabs and splits per name.

### O4. Backlinks done properly **S**
Under every item: **Linked mentions** (from `Links`), **Unlinked mentions** (the title or aliases
found in other items' text via the search index, not a scan, P4) with a one-tap "Link it" that
rewrites the text to `[[Title]]`, and a **local graph** (one hop, two hops) in a popover.

### O5. Embeds, headings links, block refs and aliases **M** 🔒
`[[Note#Heading]]`, `[[Note^block]]`, `![[Note]]` (rendered inline, read-only, click to open), and
`aliases:` in Properties. Links update when a note is renamed (one batched rewrite). Shared
fixture `links-cases.json` so the Swift and JS parsers agree.

### O6. Properties **M** 🔒
User-defined typed fields on any item: text, number, date, checkbox, list, link, rating. They're
shown in a header block, searchable (`status:done`, `rating>3`), and kept as a `props` object field
(LWW per key), so different properties edited on two devices merge.

### O7. Bases: tables, cards and boards over anything **L** 🔒
A **View** item (`kind: view`) stores a filter (search query + properties + folder + kind), columns,
sort, group and layout: **table**, **cards**, **board** (kanban grouped by a property, drag between
columns writes the property) or **calendar** (by a date property). Smart collections become Views.
Built on the per-view sorted id arrays (P1), so a view of 10k items updates in O(changed). This is
where Trove becomes a light Notion/Bases for everything saved (reading lists, recipes, projects).

### O8. Boards: a canvas of cards **M**
Obsidian Canvas / Freeform: an endless page (reuse the endless sketch canvas and its tiles) where
cards are **live items** (notes, links, files, clips, sketches), with ink and connectors between
them (connectors exist from S3). Cards are elements referencing item ids (🔒 new element type
`card`). Great for planning and research boards.

### O9. Folders, smarter **S**
Drag and drop everywhere (sidebar, cards, tabs). Folder icons and colours. Nested folder counts
from P1 counters. "Tidy up" auto-filing (exists) shows a preview before applying.

### O10. The graph that scales **S**
`GraphView` runs a 16 ms loop (`GraphView.swift:181`). Use a Barnes–Hut layout in a detached task,
render with `Canvas` and draw only at 60 fps while it's settling. When settled it stops: zero
frames. Filter by folder, tag or kind, and show a local graph from any item.

---

## 5. Clipboard: Paste's best ideas, privately

### C1. Pinboards **M** 🔒
Named, coloured, ordered lists of clips (a `pinboard` record with ordered clip ids). Imported Paste
pinboards become real pinboards, not tags. In the palette, ⌘1–⌘9 switch pinboards and there's drag to reorder. Pinned
clips are never pruned.

### C2. Paste stack everywhere **S**
Mac: "Collect" mode, where every copy goes onto the stack, and ⌘⇧V pastes the next one in order (or
reverse). iPad/iPhone keyboard: the stack as a strip in the Trove keyboard.

### C3. Predicted next paste (Intelligent Clipboard, without AI) **S**
Rank clips per **target app** (frontmost app when the palette opens): how often clips of that kind
were pasted there, recency, the time of day and what was just copied. A tiny on-device model
(counts in SQLite), shown as the first row with a ⏎ hint. No cloud and no cost.

### C4. Jump to history **S**
From a search hit, ⌥⏎ shows the clip in its place in the full timeline, with what was copied just before and after.

### C5. Pause **S**
Pause for 5 min / 1 hour / until tomorrow / until I resume, from the menu bar and the palette. A
pause indicator in the menu-bar icon. "Ignore next copy" (⌥⌘C).

### C6. Privacy while screen sharing **S**
The palette window gets `sharingType = .none` (invisible to screen recording and sharing).
Previews of sensitive-looking clips stay blurred until hovered or selected (an option, on by
default), because macOS gives apps no reliable signal that the screen is being shared. App ignore list editor
(exists as a constant list, `ClipboardWatcher.ignoredApps`; make it editable and synced).

### C7. Paste transforms **S**
In the palette, ⌘⇧ actions: paste as plain text, UPPER/lower/Title, trim whitespace, clean URL
(URLCleaner exists), JSON pretty/minify, Markdown ↔ rich text, and Writing Tools on the iPad.

### C8. Clipboard for Claude (MCP) **S**
trove-mcp gets `clipboard_search` and `clipboard_read` (never sensitive clips, the same rule as Ask).

### C9. Palette speed and polish **S** ⚡
It opens in < 50 ms (keep the window and view tree alive, hidden, and pre-render the first 20 rows). Arrow-key
navigation is instant. Space shows Quick Look, there's a compact one-line mode, drag out to any app,
OCR text searchable in images (exists), and type-to-filter by app (`app:Safari`).

### C10. Snippets with placeholders **S**
Saved snippets with `{date}`, `{clipboard}` and `{cursor}`, expanded on paste. Optionally a text
abbreviation like `;sig` (the Mac, via the Accessibility permission already granted).

### C11. Merge and split **S**
Select several clips → merge into one (with a separator) or save as a note. Split a clip by lines.

### C12. Retention you can see **S**
Settings shows how much history there is and its size, with "keep 1 month / 1 year / forever" per kind (images separately). Exists partly (`clipKeep`); add the size and a per-kind setting.

---

## 6. Sketching and notebooks: GoodNotes and Notability, then past them

### G1. Notebook shelf and covers **M** (ROADMAP S4) ❓ design direction first
Covers (colour, pattern, picture), a shelf view for Sketches (recent first, favourites),
notebook-level settings (paper, size, default pen).

### G2. Outline, bookmarks and page links **M** (ROADMAP S4)
Name any page; a sidebar lists them. PDF outlines (PDFKit's `outlineRoot`). Lasso → "Link to…" a
page, notebook or any item, and the links show in backlinks (O4).

### G3. Templates and planners **M** (ROADMAP S4)
Generated daily/weekly/monthly planners with page links, any PDF page or image as a template, and more papers (music, handwriting practice, engineering, calendar).

### G4. Audio synced to ink **L** 🔒 (ROADMAP S7)
Record while writing; strokes already carry `createdAt`. Playback lights strokes in order, and
tapping a word or stroke seeks the audio. Transcripts (N9) are searchable and linked to the timeline.
The audio is an encrypted blob recorded as AAC at 32–48 kbps mono (small, low power), with no
continuous waveform redraw while recording (an update once a second). This is the feature that beats GoodNotes.

### G5. Smart-Ink-style editing **M**
- **Insert space**: drag a line down to push everything below it (GoodNotes' "add space").
- **Reflow**: lasso handwriting and change the column width, so words rewrap (needs word boxes from G6).
- **Erase by word**, **restyle** (colour or thickness of a selection, exists), and **straighten lines** (exists).
- **Convert to text inline** (exists via Vision): keep the ink until confirmed.

### G6. Handwriting recognised with word positions **L** 🔒 (ROADMAP S6)
`PKStrokeRecognizer` (OS 27) per stroke group, with Vision as the fallback. It stores `inkWords`
(text + box per word, per page), so search hits highlight the exact spot, and it enables
spellcheck underlines and **word complete** (grey ink suggestion) on OS 27. Recognition runs
incrementally on changed strokes only (P12), never whole pages.

### G7. Math assist **M**
Write `=` after an expression: it's recognised (G6), evaluated with the N10 parser, and the answer
appears in handwriting-style ink. It flags wrong steps when the two sides disagree.

### G8. Study mode with spaced repetition **M** 🔒
Lasso → flashcard (front: the selection; back: what's under tape or typed). A **Study** view with
FSRS scheduling (open-source algorithm, small, in TroveCore with tests). Cards from notes, sketches
and AI ("make flashcards from this notebook", exists as a note). Review state syncs (`card` records).

### G9. Zoom window **M**
A magnified strip at the bottom: write big, land small, auto-advance at the margin. iPad and Mac.

### G10. Presentation mode **S**
Hide the UI, external display via the AirPlay/second screen scene, laser (exists), a pen that fades,
page thumbnails on the presenter's screen.

### G11. Whiteboards at 10k+ strokes **M**
The quadtree (P13), tile LOD (draw a simplified outline below 25 % zoom), progressive load
(nearest tiles first). Target: a GoodNotes whiteboard with 20k strokes opens in < 1 s and pans at 120 Hz.

### G12. The iPad canvas: PencilKit or Trove's own renderer ❓
Today PencilKit draws on the iPad, so Trove's pen styles (dashes, grain, fill, arrows) show as plain
strokes there (NOTES). Options: (a) keep PencilKit (best latency, least work); (b) a Metal renderer
with Trove's outlines and predicted touches (`UITouch.predictedTouches`) on the iPad too, so all
devices look the same. (b) is **L** and must match PencilKit's ~9 ms latency. Recommendation: (a)
now, (b) only if the styles matter to the user.

---

## 7. Capture everywhere (the "save anything" promise)

### X1. Quick capture from anywhere **M**
- **Mac**: a global hotkey for Quick Note (a separate hotkey from ⌥Space), a menu-bar "New note",
  the Services menu ("Save to Trove" on selected text), and dragging onto the menu-bar icon.
- **iPhone/iPad**: **Control Center controls** and **Lock Screen controls** (iOS 18 `ControlWidget`)
  for New note, Voice note, Save clipboard and Scan. The **Action button** via the same App Intents.
  Interactive home-screen widgets.
- A **Quick Note panel** on the iPad (a small floating window scene) for jotting in Stage Manager / Slide Over.
- Back Tap → Save clipboard (a Shortcut the onboarding offers).

### X2. Share extension that takes everything **S**
Accept attributed text from Notes, multiple images, PDFs, web pages with the selection, and files of any type. Show a folder picker and tags in the sheet. Fully offline (seals to the local inbox, exists).

### X3. App Intents for every action **M**
One `TroveCommand` list (O2) exposed as `AppIntent`s plus **`AppEntity`** for items, folders and
clips (Shortcuts can search, open, create, append to Today's note, add to a pinboard, run Ask).
**Spotlight actions** and **Siri suggestions** come free from App Shortcuts (no Siri entitlement
needed for App Shortcuts). `IndexedEntity` (iOS 18) puts entities in Spotlight with less code than P6.

### X4. Automations instead of plugins **S**
Folder rules (exist as auto-filing) get actions: when a new item matches → tag, move, add to pinboard,
run a Shortcut, or summarise with AI.

### X5. Document scanning **S**
VisionKit `VNDocumentCameraViewController` on iPhone/iPad → PDF with OCR text, filed. Continuity
Camera on the Mac ("Import from iPhone → Scan Documents").

### X6. Web clipping that keeps the page **M**
The extension saves a **Readability-style article** (clean text and images, encrypted) with each
link, plus highlights on any page (ROADMAP §7). Safari via the app's extension. The clip template
(title, URL, selection, tags) is configurable.

### X7. Email, messages and bots **S**
Exists via bridges (email needs a domain ❓). Add an iMessage/Shortcuts route: share to Trove from
Messages saves the link or photo with the sender's name.

---

## 8. AI: local first, cheaper, more useful

### A1. Ask with citations in the apps **S**
The website has citations and "Save as note"; the apps' Ask should too (NOTES says the apps lack them).

### A2. Look back and suggest links in the apps **S**
Port the website's weekly digest, "on this day", possible duplicates and Suggest links (no AI) to the apps.

### A3. Answers that point at the exact place **S**
Citations carry page and section (the lettered grid exists), a clip handle or an audio timestamp;
tapping opens the spot.

### A4. On-device first, everywhere it can be **M**
- iPad: Foundation Models for titles, summaries, tags, keywords and note actions (exists), now with
  `@Generable` outputs and tool calling into AskTools for a **free, private Ask** on the iPad (with
  your own AI as the "Smarter" option).
- Every device: NaturalLanguage for language, entities (people, places, organisations become
  properties O6) and sentiment-free keywords (exists); Vision for OCR, barcodes and document
  detection; Speech for transcripts.
- Image search by content: `VNClassifyImageRequest` labels stored as hidden keywords ("receipt",
  "dog", "whiteboard"), free and on-device.

### A5. Spend controls that never surprise **S**
Exists (limits, meter, Activity). Add a per-feature monthly budget and a "this will cost about …"
line before any bulk AI job (exists for keywords; do it for handwriting and Ask's long answers).

### A6. Semantic search everywhere in the apps **S**
Use `NLContextualEmbedding` (multilingual, better than word vectors) where available, quantised
(P4), with rank fusion (exists).

---

## 9. Sync, data and security

### S1. Conflict UI **S**
Conflicted text fields exist (`Record.conflicts`). Add a side-by-side merge view with "keep mine /
keep theirs / keep both", and a badge in the sidebar.

### S2. Health page **S**
Settings → Sync shows each device, its last sync, what's waiting, the segment count, vault size, the
last checkpoint, and errors in plain words, with "Copy diagnostics" (no content).

### S3. Locked notes and app lock **M** 🔒
- **App lock**: Face ID/Touch ID when Trove opens (and after N minutes), plus blurred app-switcher snapshots.
- **Locked items**: a per-item extra key, derived from a lock password via Argon2id/scrypt and
  wrapped by the vault key, so even an unlocked device needs the password (Apple Notes' model).
  Locked items are excluded from AI, Spotlight, widgets and the search index body (titles optional).

### S4. Passkeys for the website **M** 🔒 (ROADMAP §7)
WebAuthn PRF unwraps the website's stored keys.

### S5. Key rotation after removing a device **L** 🔒 (ROADMAP §7)

### S6. Shared spaces **L** 🔒 (ROADMAP 5.4)
Unlocks shared notebooks, shared pinboards (Paste), collaboration (GoodNotes, Apple Notes) and a
remote MCP. Needs its own design doc first.

### S7. Backups you can trust **S**
A scheduled encrypted export (vault bundle) to a folder the user picks (iCloud Drive or an external
disk), plus "Restore from backup". A plain export (Markdown + files + PDFs of sketches) on demand.

### S8. Data integrity checks **S**
A background verifier (charger only) that re-reads blobs and checks hashes, finds orphans and
missing attachments, and reports them in the health page.

---

## 10. Import, export and interop

### I1. Apple Notes everywhere **S**
Mac: AppleScript import (exists). iPad/iPhone: accept Notes' **Markdown export (iOS 26)** and the
share sheet, keeping attachments. A mapping test with a real export.

### I2. Obsidian vault import **S**
A folder of Markdown with front matter → notes with Properties (O6), `[[links]]` intact, attachments,
and folder structure kept. Canvas files → Boards (O8).

### I3. More importers **M**
Bear (`.bearbk`), Evernote (`.enex`), Notion (exists in TroveCore, add UI), Readwise (exists, add
UI), Day One (JSON), Craft (Markdown), Notability (`.note`, if feasible), Raindrop/Pocket CSV.

### I4. Two-way plain files **M**
The Obsidian mirror (Mac) becomes a general "Plain folder" bridge: Markdown out, edits in, on Mac
and (via the Files app) iPad.

### I5. Export **S**
Any item or folder as Markdown, PDF, HTML or a zip. Sketches as PDF with or without paper.
Notebooks back to `.goodnotes`? ❓ (hard; probably no).

---

## 11. Design, accessibility and feel

### D1. Pick the design direction ❓ **(blocks G1 and D2)**
A Glass, B Editorial or C Midnight (NOTES, artifact link). Everything visual waits on it.

### D2. Liquid Glass done right (OS 26) **M**
Glass toolbars and the palette behind `#available`, `.glassEffect` only on floating chrome (not on
lists, which costs GPU and battery), and a solid fallback for Reduce Transparency and for OS 18/15.

### D3. Gallery and attachments views **S**
Apple Notes' attachments browser: every photo, PDF, sketch, link and file as a grid filtered by kind.

### D4. Accessibility **M**
VoiceOver labels on every control (audit with the accessibility inspector in CI UI tests), Dynamic
Type in all lists, Reduce Motion (the box animations), keyboard navigation on the iPad (focus,
⌘-shortcuts discoverable with ⌘-hold), Voice Control names, colour contrast in all three themes.

### D5. Keyboard first on Mac and iPad **S**
Every action has a shortcut (from O2), with a cheat sheet, ⌘N, ⌘⇧N, ⌘K, ⌘O, ⌘L (link), ⌘⌥1–9 for sidebar sections.

### D6. Every screen size **S**
The foldable iPhone (two-pane on the inner display like Paste's Duo layout), iPad windows in Stage
Manager at any size, the Mac at small window widths. Size-class tests in CI snapshots.

### D7. Haptics and sound **S**
Subtle haptics on Pencil Pro squeeze (exists), tick on checklist, success on capture; all optional.

### D8. Onboarding that sets up capture **S**
After pairing: offer the hotkeys, Control Center controls, the keyboard, the share sheet, Apple
Notes and GoodNotes imports, each one tap.

### D9. Localisation **M**
String catalogs (`.xcstrings`) everywhere so translations are possible. English first.

---

## 12. Quality: measure, test and ship without an Apple Silicon Mac

### Q1. Benchmarks for the new hot paths **S**
TroveCore: ChangeSet application, `ItemRow` building, P5 rebuild from SQLite, binary index load,
`Links` incremental update, FSRS, and the math parser, all in the existing benchmark gate.

### Q2. A generated big vault **S**
`trove-gen` (TroveCore executable, also used in tests): 50k items, 50k clips, a 500-page notebook,
200 PDFs, with a seed. A debug-only "Load test vault" in the apps so the user can feel it on a device.

### Q3. XCTest on the macOS CI runner **M**
- A unit test target for the app (not just TroveCore) runs on macOS on CI.
- **Performance tests** with `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric` and
  `XCTStorageMetric` over the generated vault: reload after one edit, search keystroke, opening a
  big notebook, palette open.
- **Simulator UI tests** (iPhone and iPad simulators exist on the runner): launch
  (`XCTApplicationLaunchMetric`), open a note, type, search, open a sketch, draw with synthesised
  touches, open the clipboard. They catch crashes before the user does, since none of the apps have
  run on a device in CI.
- Snapshot tests of key screens at several sizes and themes, as artifacts.
- Baselines stored in the repo, and a > 20 % regression fails the build (like the web bench).

### Q4. Real-device numbers **S**
MetricKit payloads (exist) get a "Send to Trove's diagnostics" toggle that stores them **in the
vault** (encrypted, as items in a hidden folder), so a cloud session can read them from the website
and see real launch times, hangs and energy. No third-party analytics.

### Q5. Crash and hang reports **S**
`MXDiagnosticPayload` (crashes, hangs, CPU exceptions, disk write exceptions) into the same hidden
folder, symbolicated on CI with the build's dSYMs (kept as artifacts).

### Q6. Code health **M**
Split the giants: `AppModel.swift` (1,560 lines), `InkEditorModel.swift` (2,284), `PencilCanvas.swift`
(1,365), `MainView.swift` (1,045), and on the web `draw.js` (2,665) and `app.js` (2,183), along the
store boundaries from P3. Swift 6 strict concurrency stays. No new `@unchecked Sendable`
(`LocalDatabase` is one; wrap SQLite in an actor or `Mutex` from Synchronization).

---

## 13. Decisions for the user ❓
1. **Design direction** (A Glass, B Editorial, C Midnight). It blocks G1, D2 and the notebook shelf.
2. **iPad pen renderer** (G12): keep PencilKit (recommended) or build Trove's own so styles match everywhere.
3. **Locked notes password model** (S3): one lock password for all locked notes (Apple Notes' way, recommended) or per note.
4. **Diagnostics in the vault** (Q4/Q5): OK to store MetricKit and crash payloads in a hidden folder so cloud sessions can read them?
5. **Segment pruning** (P18): OK to delete relay and iCloud segments older than 30 days once every device has a newer checkpoint? (It saves space and speeds new devices; old history then lives only in checkpoints.)
6. **Export back to `.goodnotes`** (I5): wanted, or is PDF enough?
7. **Bases-style Views** (O7) as a headline feature: worth an **L** round now, or after the editor?
8. **Order**: the suggested order below, or a different first item?

---

## 14. Suggested order

| Round | What | Why then |
|---|---|---|
| **1. Speed core** | P1 change feed · P2 rows · P6 Spotlight · P8 clipboard watcher · P9 sockets/App Nap/tolerance · Q2 big vault · Q3 XCTest perf + simulator UI tests | The biggest speed and battery wins; small protocol risk; CI proves them |
| **2. Fewer wakes, less memory** | P10 batched segments (relay + clients) · P11 iCloud NSMetadataQuery · P4 search actor + binary save · P7 thumbnails · P15 launch · P16 budgets | Radio and memory; launch under 400 ms |
| **3. The editor** | N1 TextKit 2 editor · N2 · N3 · N4 · O1 switcher · O2 command palette · O4 backlinks | The largest product gap; built on the fast core |
| **4. Organise** | O5 embeds/aliases · O6 Properties · O7 Views (table/cards/board) · N5/N6 templates and periodic notes · N11 Recently Deleted · O3 tabs/splits | Obsidian/Notion-level structure |
| **5. Clipboard** | C1 pinboards · C2 stack · C3 prediction · C4–C7 · C9 palette speed | Paste parity, mostly small items |
| **6. Capture** | X1 controls/hotkeys/widgets · X3 App Intents · X2 share · X5 scan · X6 reader view | "Save anything" everywhere |
| **7. Notebooks** (after D1) | G1 shelf · G2 outline/links · G3 planners · G5 insert space · G9 zoom window · G10 present · P13 Mac tiles + page checkpoints · G11 | GoodNotes parity |
| **8. Beyond** | G4 audio synced to ink · N9 transcripts · G6 word recognition · G7/N10 math · G8 study | Where Trove passes GoodNotes and Apple Notes |
| **9. Trust** | S1 conflicts · S2 health · S3 locks · S7 backups · S8 integrity · P5 ops out of RAM · P18 pruning | Data safety at scale |
| **Later** | S4 passkeys · S5 key rotation · S6 shared spaces (collaboration, shared pinboards, remote MCP) · G12 own renderer · I3/I4 | Design docs first |

Each round updates NOTES.md, keeps the website working (only 🌐 items reach it), and adds its
benchmarks to the gate before claiming a speed-up.

---

## Sources
- Paste updates feed: https://pasteapp.io/updates/rss.xml
- Paste 7 "Intelligent Clipboard" (third-party): https://chatgate.ai/post/paste-7
- Introducing GoodNotes 6: https://goodnotes.com/blog/introducing-goodnotes-6
- GoodNotes 2024 features (Ask Goodnotes, Smart Ink, Math Assist): https://goodnotes.com/blog/livestream-event-major-new-features
- GoodNotes 6 AI handwriting features: https://thejournal.com/articles/2023/08/29/goodnotes-6-debuts-with-ai-handwriting-features-ai-math-help.aspx
- GoodNotes vs Notability 2026: https://setapp.com/app-reviews/goodnotes-vs-notability
- Notability audio transcripts: https://ipadworker.substack.com/p/notabilitys-new-feature-audio-transcripts
- Obsidian changelog v1.14.4 (Bases kanban, large-vault input lag): https://obsidian.md/changelog/2026-10-05-desktop-v1.14.4/
- Obsidian changelog v1.14.3 (large-vault fixes): https://obsidian.md/changelog/2026-09-29-desktop-v1.14.3/
- Apple Notes Markdown import/export in iOS 26: https://apple.gadgethacks.com/how-to/how-to-import-and-export-markdown-in-apple-notes-on-ios-26/
- Apple Notes on macOS Tahoe: https://macos-tahoe.com/blog/macos-tahoe-notes-app-complete-guide-troubleshooting-tips-2025/
