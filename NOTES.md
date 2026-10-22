# NOTES: status and next steps

_Last updated by a cloud session (Linux, no Xcode; Swift 6.3.1 for TroveCore can be installed to /opt/swift). The user has only an Intel Mac, so there is no local Xcode._

## Status
| Part | State | Tested |
|---|---|---|
| `server/` relay (Worker + Durable Object + R2, WebDAV, email-in, AI proxy, price watches, publish-to-link, serves the web app) | ✅ Done | 35 tests on the Workers runtime (incl. a real MIME email) |
| `Packages/TroveCore` (sync, crypto, merge, importers, search, library, price watches, publishing, folders, links, versions, GoodNotes ink, drawing, sketch tools, clip insights, power policy, notes, PDF marks) | ✅ Done | 158 tests (run on Linux with Swift 6.3.1 at `/opt/swift` when installed), plus an end-to-end test against `wrangler dev` |
| Crypto/sync compatibility Swift ⇄ Worker ⇄ extension ⇄ web app | ✅ Verified both directions | fixtures + scripts |
| Import (zip, folders, exports; app + website) | 🟡 Core + website tested (Swift + JS on one zip fixture, Chromium e2e); app builds on CI, not run on a device | 5 Swift + 1 JS test, UI e2e |
| `extensions/browser` (Chrome; Safari via app target) | ✅ Done | crypto test + real-Chromium e2e (save, offline queue) |
| `web/` web app (any browser, served by the relay): create vault, recovery, add devices, inbox import, folders, viewer, connections, select mode, sources, GoodNotes viewer, drawing, sketch tools, clip editor | ✅ Done | 28 unit/interop tests; 9 e2e (relay + real Chromium, incl. `draw.e2e.mjs`) passing locally. Deployed (version 3d43d4ca, at f01c8a3) |
| `App/` (macOS + iOS/iPadOS app, share ext, widgets, Safari ext) | 🟢 **Builds** on GitHub Actions (Xcode 26.3) for macOS (universal) and iOS (last: 3cb7fcd, sketching/clipboard places/Paste round); not yet run on a device | CI: `.github/workflows/apps.yml`; downloads at the `latest` release |
| **Clipboard history** (Mac ⌥Space palette, iPhone/iPad screen + Trove keyboard, website view; synced clips, PROTOCOL.md §8): source app/page/window, insights, rule tags, AI names/summaries, OCR, editing, main search, auto-save | 🟡 Core + website tested; apps build on CI, not yet run on a device | 8 Swift + 3 JS unit tests, `clip-cases.json` (insights + rules), Chromium e2e |
| **Folders + auto-filing, file previews, versions, connections/graph** (PROTOCOL.md §9) | 🟡 Core + website tested; apps written, building on CI, not yet run on a device | 9 Swift + 7 JS unit tests on shared fixtures, Chromium e2e (`organize.e2e.mjs`) |
| **Notes: Today's note, templates, checklists** (PROTOCOL.md §12) | 🟡 Core + website tested; apps build on CI, not yet run on a device | 4 Swift + 3 JS unit tests on `notes-cases.json`, Chromium e2e (`notes.e2e.mjs`, desktop + phone width) |
| **PDFs like a PDF app** (find, text highlights, quotes, links, forms, export as annotations; PROTOCOL.md §10) | 🟡 Core + website tested; apps (PDFKit reader) build on CI, not yet run on a device | `pdf-cases.json` (Swift + JS), pdf.js export test, Chromium e2e (`pdf.e2e.mjs`) |
| **Drawing / Apple Pencil** (sketches and ink on PDFs/images, PROTOCOL.md §10): 6 pens, laser, 3 erasers, scribble to erase, lasso, shapes, text, pictures, 17 papers, page sizes, scroll/flip layouts, zoom 10–1000 %, Pencil squeeze palette, page panel, endless canvas, PDF export, handwriting search, editing (S3: lasso actions, shape tool, connectors, ruler/protractor, text on the page, elements library) | 🟡 Core + website tested; apps written (PencilKit pens + Trove tools on iPad/iPhone, all tools on Mac), build on CI, not yet run on a device | Swift + JS unit tests on `ink-cases.json`, `ink-geometry.json`, `ink-editing.json`; 3 Chromium e2e (incl. `editing.e2e.mjs`) |
| **GoodNotes notebooks with handwriting** (`docs/GOODNOTES.md`) | 🟡 Website checked against real notebooks and GoodNotes' PDF exports; apps building on CI | shared fixture `ink.goodnotes` (Swift + JS) |
| Relay + web app deployed to Cloudflare | ✅ **https://trove-relay.lancus.workers.dev** (version 28f6c644, at c5eb332, after the performance/GoodNotes-editing round) | web e2e, Chromium UI e2e and the Swift integration test all pass against production |

**Design mockups:** three directions (A Glass, B Editorial, C Midnight; Mac + iPhone each) in a
private artifact: https://claude.ai/artifact/A9P4DTybx1EaSzG3TcayJg. Ask the user which one to build
before restyling `App/Sources/Views`. The web app currently uses a neutral style close to Midnight.

## The user's setup (important)
- **No Apple Silicon Mac.** The user's Mac is Intel, and current Xcode needs M1 or later. So:
  - **The apps are the product; the website is secondary** (the user: "the main thing of this is the
    app for mac and ios/ipados, the website is not primary and is there just cus we can have it").
    Apps first, Apple frameworks first; website only where cheap. The website
    (https://trove-relay.lancus.workers.dev) is still handy for creating the vault and adding devices.
  - **The Apple apps are built on GitHub Actions** (`.github/workflows/apps.yml`, Xcode 26.3 on `macos-15`; the repo is public, so it's free). Compile errors are fixed from cloud sessions:
    1. `git fetch origin ci-logs` then `git show origin/ci-logs:macos-errors.txt` (and `ios-errors.txt`, the full `*.log`, `RESULT`).
    2. Run status: `gh api repos/mrlancus/trove/actions/runs`.
  - **Installing:** the run's artifacts are `Trove-macOS` (universal, signed with Trove's self-signed certificate) and `Trove-iOS` (`Trove.ipa`, unsigned). The user installs the IPA with **Sideloadly** using their free Apple ID; that needs redoing every 7 days.
- **The relay is deployed** with `ALLOW_NEW_VAULTS=true`. The user needs that to create the vault on the website. **After they've made their vault, set it to `"false"` and redeploy.** The token for `wrangler deploy` is in the cloud environment (`CLOUDFLARE_API_TOKEN`).

## Latest round: notes (daily note, templates, checklists) and PDFs like a PDF app (user: "do all that and the pdf viewer")
Picked up the two unfinished branches (`wip/notes`, `wip/pdfs`, both merged in). Shared code is tested
on Linux (Swift + JS on the same fixtures); the website is checked in Chromium (`notes.e2e.mjs`,
`pdf.e2e.mjs`); the apps build on CI for macOS and iOS but **haven't run on a device**.
- **Notes** (PROTOCOL.md §12; `Notes.swift` = `core/notes.js`, `Fixtures/notes-cases.json`):
  - **Today's note**: Today button in the toolbar, ⌘T in the Add menu, Mac menu bar "Today's Note";
    website: Today. Id `daily-yyyy-mm-dd`, so every device opens the same note; made from your
    template named "Daily note" if you have one, else the built-in one. The apps sync first when
    it's not there yet (so two devices don't both write the template).
  - **Templates**: Add menu → New from template (Daily note, Meeting, Journal, Recipe, plus yours);
    website: "From template…". Any note becomes one with "Use as template" (item ⋯ menu; website:
    button on the note); it's a `template` tag. Placeholders: `{date}`, `{time}`, `{datetime}`,
    `{longdate}`, `{weekday}`, `{day}`, `{month}`, `{year}`, `{clipboard}`, `{title}`. The clipboard is
    read only for templates that use `{clipboard}` (iPhone/iPad ask "Allow Paste?" then).
  - **Checklists**: tap a checkbox in Read mode (website: in the preview) to tick it.
  - Left out of the draft for now: embeds (`![[…]]`), pasted-image names, folding headings (they
    belong to the richer editor, ROADMAP "Notes").
- **PDFs** (ROADMAP S5, PROTOCOL.md §10 "PDF text, highlights and forms"):
  - **Apps** (`Drawing/PDFReader.swift`, PDFKit): find (every hit marked, ↑/↓), select text →
    colour swatches to highlight, Quote (highlight + quote item in Quotes & Highlights), Copy; tap a
    highlight to recolour, quote, copy or remove it. Links work (PDFKit). Forms fill in place and
    the values are saved as `field` elements every 1.5 s and when the PDF closes (the file never
    changes). Trove's ink, highlights and text boxes are drawn by the pages (`TrovePDFPage`), so
    inked PDFs now open in the reader too ("Draw on it" still opens the editor). Export with
    annotations (button on the PDF) → share, or Save as a new version.
  - **Website** (`pdfviewer.js`): the same, with pdf.js's text layer. PDFs added on the website get
    their text for search (`ocrText`) at once, so they're searchable without an Apple device.
  - The apps' PDF text for search now matches the website's exactly (`PDFText.join`, page by page).
  - **Check on the iPad/Mac**: (1) find "the" in a long PDF: hits marked, arrows step; (2) select a
    line with the Pencil/finger → swatches appear at the bottom; highlight sits exactly on the text
    (also on a rotated/landscape page); (3) Quote makes a card in Quotes & Highlights; (4) tap a
    highlight → recolour/remove; (5) a PDF form: type, tick, choose; close and reopen: values back,
    and on the website; radio buttons and nested field names (`parent.child`) are the least sure
    part (PDFKit's `fieldName`); (6) a PDF with ink: the ink shows in the reader at the right place;
    (7) Export with annotations → open in Files/Preview: ink, highlights and text editable there.
  - Not done yet: a PDF's outline (bookmarks sidebar), highlights in the live drawing editor's own
    layer on iPad (they show in previews and behind the page when rendered).
- **The website changes go live when the user says "publish"** (not deployed: Today/templates,
  ticking checkboxes, the new PDF viewer).
- **Next**: notebooks (S4; design direction ❓8 still open), the file viewer for every type (§7,
  shares the PDF viewer code), handwriting as text (S6), audio + study (S7), the richer note
  editor (embeds, folding headings, slash menu).

## Round before: iPad fixes (user, iPad Air M3 + Pencil Pro: "import does nothing", "sharing says open Trove once", "sketch opens partly hidden", page colours, a dark page, "Allow Paste" every launch)
Written on Linux; builds on CI for macOS and iOS (run on `wip/ipad-fixes` at bdcaab7, no errors); not yet
run on a device. **Check on the iPad** after installing the new build
(SideStore update, or Sideloadly; reinstalling over the old one keeps the data).
- **Import on iPhone/iPad** (Choose files did nothing): SwiftUI on iOS presents only one
  `.fileImporter` per view tree, and the window's own (Import files… in the + menu) sat above the
  Import screen's two, so theirs never opened (the Mac shows panels differently, so it worked there).
  The scan button had the same problem inside the + menu. Now one set of pickers serves each window
  (`Views/ImportPickers.swift`: `.importPickers()`, asked for through `pickFiles`, `pickPhotos`,
  `scanDocument`, `showImporter`). The Import screen on iPhone/iPad has **Files…** (several, any
  kind, folders), **Photos…** (several photos and videos, imported as files) and **Scan**; the +
  menu has Import from Photos too. Check: each opens, and what's picked arrives with the progress ring.
- **Share sheet "open Trove once"**: the app, its share extension, widgets and keyboard meet in the
  App Group container. SideStore/AltStore (free Apple ID) re-sign the app and rename the group to
  `group.com.mrlancus.trove.<TEAMID>`; Trove only tried the original name, so the app and the
  extension each fell back to a private folder and never saw each other's files. Now
  `SharedConfig.appGroupFound` tries the names listed in `ALTAppGroups` (which SideStore writes into
  the app's Info.plist; the extension reads the app's too), the original, then the original plus the
  team ID (from the re-signed bundle id or the keychain's access group). The app writes the capture
  settings (public key only) on every launch and whenever it comes to the front. The extension now
  says which problem it is: settings not written yet, or no shared storage at all.
  **Check:** Trove → Settings → About → "Share sheet and widgets" should say Connected (and the group
  name). Then share a file or link to "Save to Trove".
  - If it says "Can't share storage on this install", the signing tool dropped the App Group (this
    can't be fixed in code). Then use **Trove in the share sheet's row of apps** ("Copy to Trove"):
    Trove now declares that it opens any file, iOS copies it into Trove and Trove imports it
    (`AppModel.openFile`). Installing with SideStore keeps App Groups; Sideloadly may not.
- **Sketch opened partly hidden (10 %)**: the canvas fitted the zoom on its first layout, when
  SwiftUI had given it its width but not yet its height; fitting the whole page into a ~0-point-tall
  view gave the 10 % minimum, and since the width never changed it was never fitted again. Now it
  fits once the view has a usable size, again when the width changes (rotation, Split View) or when
  the last fit was made while it was still too short, unless zoomed by hand; it opens at the top of
  the page, centred. The Mac canvas had the same race (fit before the window had a size) and now
  fits when its scroll view lays out (`InkScrollView`). Check: open existing sketches, PDFs and
  images several times, rotate, use Split View.
- **Colours**: pages stay white (#ffffff, as before) and the area around them is the same light
  grey on iPad, iPhone and Mac, whatever the system's appearance (it used to turn near-black in dark
  mode; the Mac used the system's under-page colour).
- **Dark page** (new): a moon/sun button in the sketch editor's toolbar (sketches only), remembered
  per device (`ink.darkPage`), off by default. On: pages black, only black and white ink swapped
  (greys within 0.2 of black or white and nearly colourless, channel by channel 1 - c), every other
  colour as it is, text boxes and what the lasso drags too; dark grey around the pages. Display
  only (`Drawing/InkDark.swift`): stored colours, sync and PDF/image export stay light. PencilKit
  is kept in light mode (it would otherwise invert dark ink itself); the iPad canvas draws each
  stroke in its shown colour and turns a new stroke's colour back before storing it. PDFs and
  pictures keep their look. The website editor didn't get it (apps first). Check: black and white
  pens swap, red/blue stay, a stroke drawn in dark mode is black on another device, export is light.
- **"Allow Paste?" on every launch** (and "Paste from MacBook" at random): Trove read the
  clipboard each time it came to the front (and on every change, including Universal Clipboard
  arriving from the Mac), and Capture read it to offer "Paste link". iPhone/iPad now never read the
  clipboard by themselves: they only note that something new is there (no question), and the
  system Paste button (Clipboard screen, Capture) reads it when tapped, which never asks. The Trove
  keyboard and the Save Clipboard shortcut still work; the Mac's clipboard history is unchanged. The
  "Save what I copied when I open Trove" toggle is gone on iPhone/iPad. Other questions (location
  for clipboard places, notifications for price alerts, Photos for screenshots, microphone and
  speech for voice notes, calendar) only come up when that feature is first used. The user can
  also set Settings → Apps → Trove → Paste from Other Apps → Allow.

## Battery round (ROADMAP §3.7, branch `battery`, merged into main; user: "build 3.7")
Written on Linux; TroveCore tested on Linux, the apps build on GitHub Actions; **not yet run on a device**.
- **TroveCore** (`Sync/PowerPolicy.swift`, tests in `PowerPolicyTests.swift`): `PowerState` (Settings
  mode, Low Power Mode, charger, heat, sketch open) → `PowerPolicy` (push rule, ping window, minimum
  poll, checkpoints, enrichment budget, recognition level). `PushCoalescer` (push after a 30 s pause or
  3 min of writing, never within 60 s of the last push; 30/180/300 s when saving; only on close when
  very hot), `Throttle` (pings, widget), `PowerCounters`, `VectorCache` (binary Float32 meaning
  vectors), `SyncEngine.allowCheckpoints`. **Simulated 3-hour writing session** (seeded; bursts,
  pauses, 18 page changes): 67 pushes batched vs 200 with the old rule modelled faithfully (the
  roadmap's "about 900" estimate assumed a push every 12 s; the old timer only pushed after 4 s
  pauses). Low Power Mode: ≤ 45.
- **Apps**: pushes batched while sketching and flushed on close/background; live pings merged
  (30 s sketching, 60 s saving; held until close when very hot) and the socket closed in the
  background; inbox only on a ping, on becoming active or every 15 min, price watches every 6 h, AI
  status once per launch and when Settings → Intelligence opens; enrichment on battery only for what
  this device saved in the last hour, 5 a round, none in Low Power Mode / hot / sketching, stops
  mid-batch at `.serious`; the overnight charger task now runs on the iPhone too (no on-device AI
  there) and takes everything else; handwriting re-reads only pages whose strokes changed (local
  per-page cache `Caches/trove-handwriting-pages.json`), `.fast` Vision when saving; meaning-vector
  cache binary (old JSON read once) and, like the search index, written after 60 s quiet, on
  background or at once on the charger; checkpoints only on the charger or with no sketch open;
  widget reloads only when recent/pinned/counts change, at most every 15 min.
- **Settings → Battery** (per device, not synced): Automatic / Save battery / Full speed, the state
  right now, counters for this sketch, the last sketch and since launch (pushes, pulls, requests,
  syncs, pings, ink reloads, pages read, AI calls, saves, cache KB), and the **battery report**:
  MetricKit's daily payloads (iPhone/iPad; diagnostics on the Mac too) kept as JSON in Application
  Support/Trove/metrics, each shareable. Signposts (Instruments → Points of Interest): Sync, Enrich,
  Read handwriting, Checkpoint (event), Open library.
- **How to read the battery report**: the first payload arrives about a day after installing. In
  the JSON look at `cumulativeCPUTime`, `cumulativeGPUTime`, `cellularConditionTime`/network
  `cumulativeWifiUpload/Download`, `cumulativeLogicalWrites` (disk) and `cumulativeForegroundTime`.
  Compare a day of writing before and after; also iPadOS Settings → Battery → Trove (% and screen
  time) after an hour of writing, and Settings → Battery → "Last sketch" counters (an hour of
  writing should show ~20 pushes, not hundreds).
- **Check on the iPad**: an hour of writing → "Last sketch" pushes ≈ 20, pages read only for pages
  you wrote on; strokes reach the Mac within ~3 min (instantly on closing the sketch); the widget
  still updates; Low Power Mode → "Right now" says so; an item saved on the iPad gets its AI title on
  battery, items from the Mac wait for the charger.
- **Not done here**: no Low Power Mode rule for clipboard pictures: since the iPad fixes iPhone/iPad never read the clipboard by themselves (the clipboard reads
  belong to the iPad-fixes work, and none happen automatically now).
- **Sketch editor (§3.7 items 1, 8, 9, 11; done after the iPad fixes reached `main`)**:
  - The open editor reloads only when a sync pulled ink (`AppModel.inkPulledRevision`), not after
    its own saves (it reloaded and re-sorted every stroke about every 4 s while writing). Reloads are
    counted ("ink reloads") and signposted ("Reload ink"); an hour of writing alone should show ~0.
  - iPad canvas: the ids of the strokes on the canvas are kept in order (`canvasOrder`), so a new
    pen stroke and the update after it no longer sign every stroke; signatures remain the fallback.
    TroveCore keeps the newest ink time per item (`RecordStore.newestInkTime`), so adding a stroke
    no longer reads every stroke of the notebook.
  - Closing a sketch: previews (sketch pages, inked PDFs/pictures) redraw only pages whose ink
    changed; the catch-up pushes first and refreshes lists 2 s later at utility priority; handwriting
    reads only changed pages (`.fast` when saving).
  - Text boxes and tape have their own layer (drawn past the screen's edges, redrawn when they change);
    lasso, eraser and hover moves redraw the overlay straight from the model
    (`InkEditorModel.overlayListener`) instead of re-evaluating the SwiftUI editor on every move. The
    Mac canvas is unchanged. Not done: per-shape `CAShapeLayer`s (the overlay still redraws its own
    area, now without the text).
  - A page change asks the push batching to send soon (`sketchPageChanged`).
  - **Check on the iPad**: text boxes and tape still show over the ink, move with the lasso, hide
    while typed in, and peek; the eraser circle follows the Pencil; strokes drawn fast never vanish
    or double; a stroke from the Mac still appears in an open sketch.
- CI: the Apple builds of `battery` (267ba50, then 99f609b with items 1, 8, 9, 11) passed for macOS and iOS. The `ci-logs` branch is
  shared by every run: check `RESULT` names your commit before reading the errors.

## Current round: the roadmap (user: "Bridges", iPad Air M3 + Pencil Pro; later "session ran out, continue; renaming clips doesn't work")
Built from `docs/ROADMAP.md` with parallel workers on branches, merged into `main` one by one after
the full test suites pass. **Not deployed yet**: the website/relay changes below go live when the
user says "publish" (`cd server && npx wrangler deploy`).
- **Landed:**
  - **Bridges** (ROADMAP §5; PROTOCOL.md §4 "Bridges"): the relay seals what it fetches into the inbox.
    Webhook "add" addresses (Shortcuts, scripts), RSS feeds, GitHub stars, a Telegram bot, link
    previews (`POST /preview`, SSRF-checked). Website: Settings → Bridges. Apps: Settings → Bridges.
    Optional Worker secret `BRIDGE_KEY` encrypts stored tokens (needed before saving a GitHub/Telegram
    token: `npx wrangler secret put BRIDGE_KEY` with a random 32-byte base64 value).
  - **trove-mcp** (`mcp/`, ROADMAP §5.2 step 1): Claude Desktop / Claude Code read and add to Trove;
    joins as an `agent` device. Setup in `mcp/README.md`. After the website's sealed local store
    landed, its file store broke (a CryptoKey can't go in a JSON file); fixed: file stores set
    `plainAtRest` (the folder is owner-only), and the e2e passes again.
  - **Website speed**: ops stored in append-only chunks sealed with a non-extractable AES-GCM key
    (`core/localstore.js`, PROTOCOL.md §7 "At rest"); offline app + installable (`sw.js`, manifest);
    drawing code loads lazily; one live ping per push on the relay.
  - **Apps**: thumbnail cache capped by size, sync loop backs off, signposts; `SyncBackoff` in TroveCore.
  - **CI** (`.github/workflows/tests.yml`): relay, web unit + benchmarks (fails if >20 % slower than
    `web/test/bench-baseline.json`), Chromium e2e, trove-mcp unit + e2e, TroveCore + release-mode
    benchmarks, on every push and PR. Dependabot for npm and Actions.
  - **Search** (ROADMAP Q1–Q4, §3.5): website index (postings + sorted vocabulary) in a Web Worker
    (`core/search.js`, `search-worker.js`), typo tolerance, `"phrases"`, `-word`, `title:` `in:`
    `type:` `from:` `has:` `before:`/`after:` `#tag`, bold snippets (handwriting/file labels), saved
    index (gzipped, AES-GCM with a non-extractable key, IndexedDB `trove-search`). Apps: same in
    TroveCore (`search-cases.json` fixture shared with JS), `search-index.json` snapshot, Float32/vDSP
    meaning vectors with a disk cache, rank fusion, `ClipIndex` from 20,000 clips. Bench: 50k items +
    50k clips, median 3.9 ms, p90 20 ms per keystroke (roadmap target 5 ms for 1–2 letters not yet met).
    Website search by meaning (an in-browser model from jsDelivr/Hugging Face): **dropped for now**,
    since the apps are the product and already search by meaning with Apple's on-device NLEmbedding.
    The loader stays blocked by `script-src 'self'`; don't open the CSP for it.
  - **Drawing feel + pens** (ROADMAP S1, S2, S8; PROTOCOL.md §10): strokes drawn as one filled outline
    (`strokeOutline` / `InkOutline`, fixture `ink-outline.json`); website pen layer desynchronized +
    predicted points (input-to-paint 13 ms median in headless Chromium), 512 px tiles per zoom step and
    a stroke grid for eraser/lasso (2,000-stroke canvas pans at 7 ms median); pen settings (smoothing,
    pressure curve, min width) synced in `settings.ink`; up to 10 favourite pens; pencil grain;
    dashes/dots, arrowheads, shape fill; highlighter straightens when held; your/recent colours, hex,
    eyedropper (website); tape (`type: "tape"`). Pencil Pro (written, untested): hover preview, barrel
    roll as nib, haptics. Compact `points2` (~2.5× smaller; version 2 keeps positions to 1/256 pt so
    the rounding never shows even at 10× zoom on a 3× screen; version 1 at 1/20 pt still reads) is written only after "Smaller drawings" is
    turned on (vault flag `settings.ink.compactPoints`): **tell the user to turn it on only once every
    device runs this build** (older builds would see empty strokes). Swift point decoding ~6× faster.
    Not done: OffscreenCanvas in a Worker, Mac CGLayer tiles, page checkpoints (S8 says design first).
    On iPad PencilKit draws the ink, so pen settings, dashes/fill/arrows/grain show as plain strokes.
    **Ask the user:** should tape's open/closed state sync? Should iPad draw styled strokes in Trove's
    overlay instead of PencilKit? **iPad checks:** hover dot (doubled with PencilKit's?), barrel roll, haptics.
  - **AI** (ROADMAP A1–A3; PROTOCOL.md §4 AI, §11): relay counts tokens per vault per UTC month
    (`AI_MONTHLY_LIMIT`, default 1M, friendly 429 over it), `GET ai/status`, `POST ai/action` (text and
    picture actions); default model is the cheapest Haiku. Website: Ask Trove with citations and "Save
    as note", AI menu on notes, flashcards (note tagged `flashcards`), Settings → AI usage, Suggest
    links (no AI), Look back (weekly digest `digest-YYYY-wNN`, on this day, possible duplicates). Apps:
    note AI menu (Foundation Models on iPad, else cloud), weekly digest, overnight enrichment drains the
    queue. **Cloud AI stays off** until the user decides ❓3; then `npx wrangler secret put
    ANTHROPIC_API_KEY`, deploy, switch on under AI. Hook for drawing: `runPageAction` in `ai.js`
    (not yet wired into the lasso). Apps lack Ask-with-citations, Look back and Suggest links.
    **Ask the user:** is 1M tokens/month right? Digest weeks in UTC or local time?
  - **Sync scaling** (ROADMAP §3.1, S8; PROTOCOL.md §3 Checkpoints, §4, §7): encrypted checkpoints
    ("TRC1", DEFLATE, TRV1 with the segment key) of all records + text ops + covered op ranges; a new
    device starts from the newest one and skips the segments in it. Written after a clean sync once
    5,000 ops have piled up and the newest is a day old. Relay `PUT/GET /checkpoints/:id`, R2, newest 3
    kept; iCloud `.sync/<device>/checkpoints/`. Older relays answer 404 and devices replay as before;
    segments are never deleted. Apps: local copy in SQLite (`vault.sqlite`, `LocalDatabase` in
    TroveCore; `state.json` migrates once). CI installs `libsqlite3-dev`. **Needs a relay deploy**
    for checkpoints to go live. Open: prune old segments once every device reads checkpoints?
  - **Clip renaming fixed.** Apps: the clip form saved only with the Save button at its bottom, so
    Return, swiping the sheet away or picking another clip lost the name, and on iPhone/iPad the
    row's four buttons all fired at once (Cancel too). Now Return saves the name, closing saves
    unless Cancel was pressed, buttons are borderless. Website: a clip opened from the main
    search's "From your clipboard" was rebuilt by a sync while typing (Safari then drops the
    change); it now waits while you type (e2e checks focus survives a render). **Ask the user**
    where they tried to rename (Mac palette, Mac window, iPhone, website) if it still fails.
- **Sketch fixes from the iPad** (user: lasso crash, Pencil taps not registering, ballpoint, shade
  around pages, battery/heat). Written on Linux; **check on the iPad**:
  - **Lasso crash**: a lasso drag replaced PencilKit's whole drawing on every pointer move (and the
    paper view redrew each time). Now the selection is lifted off the drawing when a drag starts and
    drawn in the overlay while it moves (`display(_:lifted:)`, `dragPreview`), so a drag rebuilds the
    drawing twice, not 120 times a second. Also: strokes PencilKit "reports" while the lasso/eraser is
    in hand are ignored (they were echoes that got added as duplicates), canvas strokes are matched
    by what the canvas holds (several ids per look-alike signature), no `Int()` of NaN/huge numbers
    (signature, page keys, eraser resampling, outlines), non-finite or degenerate lasso transforms are
    never stored (`Transform.isUsable`), lasso writes run one after another.
  - **Pencil taps**: plain buttons only answered where their label had pixels (a Pencil tap is a
    point): tools, colours, sizes, favourites, palette, page rows now take the whole frame
    (`inkTapArea`). Gesture settings are set only when they change (each lasso move reset them). A
    short tap with the lasso selects the text box/picture/tape or strokes under it; corner handles 20 pt.
  - **Ballpoint** (before the pencil, apps + website; PROTOCOL.md §10): even width, stored at
    pressure 1 so older apps (which draw unknown tools as a pen) draw it right. iPad: PencilKit
    monoline (like the marker; the tool in hand tells them apart).
  - **Around the pages**: iPad/iPhone light grey, near black in dark mode (Mac and website already had it).
  - **Battery**: while a sketch is open on iPhone/iPad (`AppModel.sketchCovers`) only the vault syncs
    (poll ≥ 2 min, live pings still pull); lists, search by meaning, Spotlight, widget, clipboard,
    which-items-have-ink scan, inbox, price watches, enrichment and AI wait until it closes. Editor:
    paper drawn ¼ screen past the edges and redrawn only when scrolling leaves it (was every frame),
    no Trove hover tip under pens (PencilKit shows its own; ours redrew the overlay per hover move),
    stroke stamps rounded to 1/20 pt (a reload no longer rebuilds the PencilKit drawing), page panel
    redraws only the current page, inked-file previews wait behind the editor. `strokes(on:)` sorts
    on precomputed times (3,000 strokes: 84 → 32 ms debug, `InkSafetyTests`).
  - **Editing faster than GoodNotes** (ROADMAP S3; PROTOCOL.md §10 "Lasso", "Arranging", "Groups",
    "Shape picker", "Handles", "Connectors", "Ruler and protractor", "Straighten", text style,
    "The elements library"): one core on both sides (`core/inkedit.js` = `InkEditing.swift`,
    `InkStickers.swift`, `InkArrange.swift`), checked by `Fixtures/ink-editing.json`.
    - Lasso: turning knob above the box (snaps to 15°, shows the angle), turn a quarter, flip both
      ways, front/back, group/ungroup (groups are picked as one), straighten, copy as image, convert
      to text (apps: Vision on the device; website: the relay's cloud AI, hidden while it's off),
      Ask AI (summarise, explain, solve, make flashcards; apps use Apple Intelligence on the
      handwriting when the device has it, else cloud AI on a picture), save as element; "Picks"
      everything / ink / text / pictures.
    - Shape tool: line, arrow, connector, rectangle, ellipse, circle, triangle, diamond, star,
      heart, speech bubble (fill, dashes, arrows from the line options). A lone shape shows
      handles: drag a line's middle to bend it into a curve, drag corners. Connectors stay joined
      when what they join moves, turns or is reshaped.
    - Ruler (720 pt, angle on it) and protractor (angle of the pen); a pen put down on an edge or
      the arc draws along it. iPad uses PencilKit's own ruler (draws along it live, two fingers
      turn it); the protractor is Trove's there, moved with a finger, turned by its knobs.
    - Text boxes are typed on the page (no more sheet): font (sans, serif, mono, rounded), bold,
      italic, bullets (Return continues a list), size and colour; turned boxes stay turned.
    - Elements library: built-in arrows, checkboxes, dividers, star, heart and planner tags, plus
      your own (`sticker` records, synced, in folders); placing one adds it as one group.
    - Circle-to-select was removed everywhere (the user doesn't want it). Scribble-to-erase stays opt-in.
    - Tests: web unit + `test/editing.e2e.mjs` (Chromium: shapes, connector following a moved
      shape, bent line, turn/front/group, copy as image, text font/bold, lasso by type, ruler line,
      save and place elements, all checked on a second device); Swift `InkEditingTests` (fixture +
      library edits). The apps build on CI for macOS and iOS (run on `wip/editing` at 3372a66, no errors); not yet run on a device.
    - **Check on the iPad** (Air M3 + Pencil Pro): the lasso's knob and handles with the Pencil;
      Shape tool drags; PencilKit's ruler appears from the ruler button and lines snap to it; the
      protractor moves with a finger while the Pencil draws, and arcs drawn on it snap; the text
      field sits exactly over the box at any zoom and the keyboard doesn't hide it; Ask AI with
      Apple Intelligence (iPadOS 26); Copy as image pastes into Notes; the Elements popover.
    - **Ask the user:** should Trove's own ruler replace PencilKit's on the iPad (same look as the
      Mac, but drawn along only after the stroke ends)? Should more built-in elements ship (which)?
- **PDFs (S5)**: done later (see "Latest round"). (Back up worker commits to `wip/*` branches on
  GitHub so a lost container doesn't lose them.)
- **Published** (the user allowed it): `BRIDGE_KEY` set, relay + website deployed (version
  3f05d8e6, at 2f8bc9c). Against production: relay e2e 5/5 and the browser test that creates a
  vault pass; "set up with a code… live updates" failed once (it passes locally; likely live-update
  timing over the network). Not re-run: the session's permission rules block more test vaults on
  production. Check it next time a run against production is allowed.
- **Next**: notebooks (S4; design direction ❓8 still open), handwriting and audio (S6,
  S7; a study view for flashcards), then the rest of the roadmap (§7). The website/relay changes of
  the editing round go live when the user says "publish".

## Round before (user: "GoodNotes whiteboards miss the normal writing; edit GoodNotes with our sketching; clipboard search and switching menus laggy; Connections should fill the right side; two-row sketch toolbar; sketching laggy, use little battery; 'Whole strokes' → 'Strokes'; smaller squeeze menu; everything faster")
- **Why drawing lagged** (found, not guessed): every stroke reloaded the drawing three times, rebuilt
  the whole PencilKit drawing twice (all tiles redrawn), and each reload scanned every record in the
  vault (thousands of Paste clips) and decoded every stroke; the whole editor (toolbar too) re-rendered
  per stroke and per eraser move; 1 s after each pause the whole vault was JSON-encoded on the main
  thread and pushed 2 s later. Fixes:
  - `RecordStore` (Swift + web `records.js`) indexes ids by kind and ink by item; `records(kind:)`,
    `ink(on:)`, `stamp(of:)` are O(that kind). Library/vault ink, clips, folders, items use them.
  - Editor: no reload after its own writes, strokes decoded once per version (`lineCache`), reload
    skipped when `inkSignature` is unchanged, `inkChanged` debounced 2 s, style changes on
    `styleRevision`; canvas/zoom pill/undo buttons are separate views.
  - iPad: `PencilCanvas.apply` diffs by id + `InkLine.stamp` and keeps unchanged PKStrokes (no rebuild
    when nothing changed), the tool is set only when it changes, no blurred page shadow per scroll
    frame, the overlay redraws only when it has something. Mac: finished ink cached as a bitmap,
    only the pen's tail invalidated. Website: pointer moves drawn once per frame, ink redrawn only
    when something was erased, stroke views cached per record version.
  - While an editor is open saves wait 4 s and pushes 8 s; the snapshot is encoded off the main
    thread (`SnapshotWriter`, never older over newer).
- **Toolbar** (apps + website): tools on top, the chosen tool's colours, 3 size presets, slider and
  eraser modes in a second row (tap the chosen tool again to hide it). Squeeze palette is a small
  two-row card (5 tools + undo, 5 colours + sizes); picking closes it. "Strokes" eraser label.
- **Clipboard search** (apps): typing narrows the previous results (`ClipQuery.narrows`), clips'
  folded text kept as bytes and searched with `memmem`. **Section switching**: sidebar counts and the
  visible list cached per `dataVersion` (they re-filtered the whole library a dozen times per switch).
- **Connections** (apps) is a two-column split (sidebar + graph); the open item closes, tapped points
  open in a sheet.
- **GoodNotes whiteboards missing handwriting**: no whiteboard sample to test against. Checked against
  the 10 public sample notebooks (all ink read) and made the readers robust: point arrays found
  wherever the format has them (A(u) or A(f)), nested/grouped strokes split, coordinates to ±1e6,
  unlisted `notes/` members of one-page boards merged, shape fills drawn. Ink still unreadable is
  counted and shown ("N strokes couldn't be read"). **Ask the user** whether whiteboards now show
  their writing; if the note appears, ask for a small test whiteboard (`.goodnotes`).
- **Editing GoodNotes**: first open in the editor copies ink, shapes and text into Trove strokes/text
  on the notebook's layer (PROTOCOL.md §10, `editableInk`, fixture-checked in Swift and JS); item field
  `goodnotesInk`; viewers then draw background + Trove's copy. Website button: "Edit handwriting".
- Tests: TroveCore 100 (index, GoodNotes layouts, editable ink), web 36 unit + 11 Chromium e2e (new:
  GoodNotes edit). Website deployed (version 28f6c644, at c5eb332).

## Round before (user: "GoodNotes whiteboards open as a huge blank page; Connections should close what's open and switch Notes/Clipboard; Paste imports show as JSON; open clips on the right")

- **GoodNotes whiteboards**: an endless canvas with no background (or a huge blank PDF) and the drawing
  far from 0, 0. Both decoders now crop such pages to their content plus a margin (`fitToContent`,
  docs/GOODNOTES.md "Page size and whiteboards"); the viewers draw very big pages softer instead of
  blank. Not checked against a real whiteboard file: if one still looks wrong, ask the user for it.
- **Paste's JSON wrapper**: newer Paste stores text as `{"type":"text","text":…,"textLength":…}`.
  `PasteImport.unwrap` / `pasteimport.js unwrap` take it off on import, and `repairWrappedClips`
  (Swift: hourly with pruning; website: once per session in the clipboard) fixes clips already
  imported, folding any that become duplicates into the existing clip.
- **Connections**: opening it closes the item open on the right (website `select`, apps
  `AppModel.selection` didSet). A Notes / Clipboard switch shows the clipboard graph there too; the
  apps use `ClipGraph` (TroveCore, a port of `buildClipGraph`).
- **Clips open on the right** (Mac and iPad): in the window's clipboard, a click opens the clip in
  the detail column (`ClipDetailPanel`), double-click copies. iPhone keeps tap-to-copy and the ⓘ sheet.

## Round before (user: "sketches getting deleted, better crossing out, precise eraser, zoom 10–1000 %, Pencil squeeze, sketch folders and connections, GoodNotes-level sketching, crashes, clipboard connections with where/when/geolocation, empty 1970 notes, Clipboard under Sketches, laggy scrolling, import from Paste")
- **A session ran out before committing**, so this round was redone from scratch and committed step by step.
- **Drawings vanishing (iPad):** when the Pencil lifted, the canvas could be redrawn from a copy of
  the page taken before the stroke reached the model, wiping it. Now it reads the model fresh and
  keeps strokes still being handed over; the editor also keeps unsaved strokes/erasures across
  reloads. (There was no auto cross-out before: the user's guess was wrong, but scribble-to-erase
  is now a real, opt-in feature.)
- **Empty "Untitled, 56 years ago" notes:** edits written to ids that weren't items (and deletes
  without a kind) made bare item records with no kind or date. `Library.update`/`setBody` and the
  website's `update`/`setBody` now skip unknown ids, deletes keep the record's kind, and such
  "stray items" are hidden everywhere (PROTOCOL.md §3). Not proven which code path made the user's;
  ask if new ones appear.
- **Crashes:** not reproduced (no device). Likely causes removed: a 4096-pixel picture per page
  (memory) and strokes with no/NaN points handed to PencilKit. **Ask the user for a crash report**
  (Settings → Privacy & Security → Analytics Data → Trove-…) if it still crashes.
- **Sketching** (website `draw.js`, apps `App/Sources/Drawing`):
  - 17 papers (PROTOCOL.md §10, shared `paperShapes`/`InkPaperShapes`, `Fixtures/ink-papers.json`),
    10 page colours, page sizes (iPad, A4, A5, Letter, Legal, square, 16:9, phone) with
    portrait/landscape, per page or every page, in a **Page** popover with paper pictures.
  - Pages **scroll down, scroll sideways or flip** (page turn; swipe, arrows, ←/→). Opens showing
    the **whole page** (or its width, in Settings) and refits on rotation/resize.
  - **Zoom 10 %–1000 %** with a bottom-left pill: slider/presets, **Reset to 100 %**, whole page,
    width (100 % = one page point per screen point). Far-in zoom draws only what's on screen.
  - **Precise eraser** (exactly the tip's size, cuts strokes), **scribble to erase** (opt-in in
    Settings; needs a real scratch-out: 6+ turns, dense, crossing what it removes; shared
    `scribbleTargets`/`InkScribble`, `Fixtures/ink-scribble.json`), **laser pointer** (fades, never saved).
  - **Apple Pencil squeeze / double-tap** follow the system setting (Settings → Apple Pencil): eraser,
    last tool, or Trove's palette at the Pencil tip (tools, colours, size, eraser mode, undo/redo).
  - The iPad/iPhone canvas now holds all pages on one PencilKit canvas (`PencilCanvas.Slot`).
    Mac still shows one page at a time with the page bar; zoom pill works there too.
  - One-row toolbar that scrolls sideways on narrow screens (website); Done stays put.
  - **Sketch folders:** Sketches shows its folders as tiles with New folder; inside one, New sketch
    here; drag sketches onto folders. **Connect** button inside the website editor.
- **Clipboard:**
  - Under Sketches in the sidebar (website + apps; iPhone keeps its tab too).
  - Every copy, paste and reuse is a `clipEvent` record (PROTOCOL.md §8): app/site, page, window,
    device, time, **place from the device's location** (never IP; apps name it via Apple; synced
    setting `recordPlaces`, on). Mac ⌥Space pastes record the app pasted into. Website records its
    own copies/uses (it can't see other apps' pastes). `_headers` now allows geolocation for the site.
  - Filters (copied from, pasted into, where, when), a **Map** view (graph of clips joined by source,
    destination, places, days, tags, connections), a clip's **history timeline** and
    **connections** (to clips and items) on the website; history list in the apps.
- **Import from Paste** (website, Import → "Everything from Paste"): reads Paste's own database
  (`~/Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite` + `-wal`,
  or old `Paste.db`) in the browser with a small SQLite reader (`core/sqlite.js`) and plist/keyed
  archive decoder (`core/bplist.js`); pinboards become tags, times and apps kept. Paste's schema is
  undocumented: tables/columns are found by name and content and tested on synthetic databases only.
  **Ask the user how many clips it found**; if it reads nothing, get the table names it prints.
- **Paste in the Mac app** (follow-up: the user imports on the Mac, not the website): Import →
  "Everything from Paste" finds the database itself (`PasteImport.candidates`: App Store
  `~/Library/Containers/com.wiheads.paste/…`, direct download `~/Library/Application Support/com.wiheads.paste-direct`,
  Setapp) and imports into the Clipboard. Dropping `db.sqlite` anywhere does the same. Swift ports of
  the reader (`SQLiteReader`, `BinaryPlist`, `PasteImport`, `Library.importClips`) check
  `Fixtures/paste-*.sqlite/.db` against `paste-expected.json` (made by `web/test/make-paste-fixture.mjs`).
- **Mac lag** (follow-up, Intel MacBook): every sync (30 s) replaced `items`, folders, links, the index
  and bumped `inkRevision` even when nothing changed, redrawing every screen and card; now
  `Library.stamp(of:)` gates each refresh. The Import drop zone's border animated 30×/s forever; now still.
- **Mac crash (0.1.50, NSToolbar insert exception):** the Clipboard moved into the window's content
  column brought its own `.searchable` next to the window's; two search fields in one toolbar is a
  known SwiftUI/AppKit crash. In the window the clipboard now uses the window's search box
  (`ClipsView.ownSearch`). The report also showed memory allocation failures (MALLOC ~780 MB on an
  8 GB Mac); watch for memory if it crashes again.
- Paste imports show the Import screen's progress ring (`ImportRun.unit`/`destination`); the sidebar's
  section buttons line up with the count pills (`sidebarHeaderButton`).
- **Asked the user:** which Obsidian-style AI features to build (local MCP server on the Mac for
  Claude Desktop/Code, Ask Trove with citations, link suggestions, digests). Notes are already
  Markdown with Preview/Edit. Re-importing the same folder makes second cards (blobs are deduped).
- **Clipboard lag after the user's full Paste import (thousands of clips):** each row re-ran the
  kind classifier (regexes) several times per draw, tag pills recounted every clip, and the list
  held every row. Now `ClipboardStore.facts` (kind, title, snippet, colour, search text) is worked out
  once per clip version in the background, tag counts once per change, and `ClipsView` shows 400 rows
  at a time (more load near the end). Imported text clips no longer set `needsEnrichment` (only
  images need OCR); without AI the enrichment marks text clips seen 400 at a time inside
  `SyncEngine.hold()/release()` (one refresh), instead of 10 every 30 s with a full clipboard reload each time.
- **Scrolling:** card snippets cut to 400 characters, no whole-grid animation diff on every sync
  (apps); off-screen clips skip layout (website).
- **img1** from the user's message never reached the session; ask them to send it again.
- Tests: TroveCore 92, web 34 unit + 10 Chromium e2e (new: zoom/flip/precise/scribble e2e, papers,
  scribble, clip events, Paste import). Website deployed (version 3d43d4ca, at f01c8a3) when the user said "publish everything"; apps for f01c8a3 are on the `latest` release.

## Round before (user: "sheet off the page, clipboard tags, GoodNotes source, type to search, where's sketching, no emoji, faster search, Liquid Glass icon")
- **Mac sheets ran off the screen** (the GoodNotes reader asked for 700×800 at least, and its
  two-way scroll view grew the sheet). Sheets now use `.sheetSize(width:height:)` (Style.swift):
  the wanted size, shrunk to the window and screen when the sheet opens.
- **Search speed** (the user: "even with a couple of items it's incredibly slow"). Causes found:
  - Apps: every keystroke waited 150 ms, then queued behind the Library and SyncEngine actors,
    which were busy decrypting full files for every result card (no thumbnail cache; Macs drew
    full-size images; GoodNotes covers parsed the whole notebook). Now: `AppModel` keeps a copy of
    the `SearchIndex` (a value) and searches it on the main actor each keystroke; prefixes come from
    a sorted vocabulary (binary search); semantic scores are blended in 250 ms later; card pictures
    are made once per file at card size (ImageIO) and cached (`ThumbnailCache`); `loadBlob` reads
    and decrypts off the engine actor; clips keep their folded search text per version.
  - Website: every keystroke rebuilt the item views, the whole search index, the link graph, the
    sidebar and every card. Now item/clip views and search docs are cached per record version,
    the sidebar redraws only when the vault or selection changes, and cards are reused. About
    3-12 ms per keystroke for 3,000 items in Node.
- **Clipboard tags with colours** (PROTOCOL.md §8 "Tags with colours", record `settings.tags`):
  "+ Tag" makes a tag with one of 12 colours; tags show as sections above the clips (click to
  filter); a clip's menu (apps) or its details (website) ticks tags on and off; right-click a
  tag (apps) or select it (website) to recolour or delete it. `#tag` searches by tag in the
  clipboard and the library. Item tag chips use the colour too.
- **Type to search** in the clipboard: the Mac palette refocuses its search box on every open and
  sends stray typing there; the Mac clipboard sheet and an iPad with a keyboard put the cursor in
  the search box; the website sends typing to the search box in the Clipboard view.
- **GoodNotes source**: notebooks imported by zip were only under "Import". Any item holding a
  `.goodnotes` file is now listed under GoodNotes too (derived, so it covers what's already there;
  also the Handwriting collection).
- **Sketching was hard to find** (it was only in the "…" Add menu). Now: a **Sketches** section in
  the sidebar (apps + website) with a New sketch banner, a pencil button in the toolbar (Mac,
  iPad, iPhone), and on the Mac a sketch opens in **its own window** instead of a sheet.
- **No emoji**: website glyphs (✎ ✓ ✕ ☰ 🔗 ☎ ▣ ● ▾ ↶ ↷ ▤) are inline SVG line icons (`icons.js`);
  app strings with ✓/☁︎ are plain text; the extension's badge says "OK".
- **Icon**: the iOS app icon gained dark and tinted variants (Contents.json appearances), so
  iOS 26's tinted/clear Liquid Glass modes show the box as a glyph like other apps instead of a
  grey square. Not done: an Icon Composer `.icon` file (true layered Liquid Glass, also for macOS
  26). It can't be made or checked without Icon Composer; try it if the variants aren't enough.
- **How much clipboard history to keep** (the user asked for it in Settings): "Keep clips for" (1
  week to 2 years, or forever) and "Keep at most" (500 to 50,000, or no limit), synced in
  `settings.clipboard` (`keepDays`, `keepCount`). Apps: Settings → Clipboard. Website: Clipboard →
  "How much history to keep". Changing it prunes at once. **Older app builds still prune at 30
  days / 1,000**, so update every device before choosing more.
- **Settings follow you** (the user: "settings like that should auto sync across all devices"):
  clipboard history on/off, hold passwords briefly, save copies on open, record page and window,
  automatic updates and cloud AI now live in the synced `settings.app` record (`SharedSetting`,
  `AppModel.setShared`). Folder paths, permissions and layout stay per device.
- Tests: TroveCore 87 (new: GoodNotes sources, sorted-vocabulary prefixes, `#tag`, tag colours),
  web 31 unit + 9 Chromium e2e (new: tag sections, type-to-search, Sketches section).
- Website deployed (version fdbed6d6) once the user said "publish" (the session's permission
  settings block deploys until the user asks).

## Two rounds before (user: "clipboard upgrade" + "sketching, aiming at GoodNotes")
- **Clipboard** (PROTOCOL.md §8):
  - Each copy keeps the app, and on the Mac the window title (Accessibility) and page address
    (Chromium's pasteboard marker, else a quick AppleScript to Safari/Chrome/Arc/Brave/Edge; macOS asks
    once per browser; Settings → Clipboard can turn it off), plus device and time.
  - Insights on copy (title, counts, links, emails, phones, colours, hashtags) and **rule tags** (kind,
    site, code language, `contact`), the same in Swift and JS (`clip-cases.json`).
  - Enrichment: Vision reads images; Apple Intelligence (iPad), cloud AI (if on) or the rules name,
    summarise and tag. Devices with AI pick up clips only the rules have seen (last 14 days).
  - Rename, edit text, tags, note (website: open a clip; Mac palette: ⌘E; iPhone/iPad: ⓘ). Clips show
    in the main search ("From your clipboard"). Saved clips keep `origin` (app, page, window).
  - **Save to Trove automatically**: a synced setting (website: Clipboard → "Save to Trove
    automatically"; apps: Settings → Clipboard). Chosen without asking: off by default; the device
    that made the copy saves it.
- **Sketching** (PROTOCOL.md §10; website `draw.js`, apps `App/Sources/Drawing`):
  - Pens: pen, pencil, fountain pen, brush pen, marker, highlighter. Eraser: whole strokes or partial,
    optionally highlighter only. Lasso: move, resize (corner handles), recolour, duplicate, copy, cut,
    paste, delete. Shapes: a shape mode, and holding still at the end of a line snaps it (line, joined
    lines, triangle, rectangle, polygon, circle, ellipse; `ink-geometry.json` keeps Swift and JS alike).
  - Text boxes and pictures (`element` records). Pages have ids: a page panel adds, duplicates,
    reorders and deletes them, with paper (8 styles) and colour per page. A sketch can be one
    **endless canvas** instead. Two-finger tap undoes, three-finger tap redoes. Export to PDF (website:
    a vector PDF writer, `pdfwrite.js`; apps: Core Graphics).
  - Handwriting search: Apple devices read sketches with Vision into `inkText` (when the editor closes,
    and from enrichment for sketches drawn on the website). Text boxes are searchable everywhere (`sketchText`).
  - Apps: iPad/iPhone keep PencilKit for pens (best Pencil latency) with Trove's own eraser, lasso and
    text over it; the Mac draws every tool itself. Text is typed in a sheet. Builds on CI (Xcode 26.3,
    build ce3409a); not yet run on a device.
- CI now prints TroveCore's real compiler errors (`core-errors.txt` on `ci-logs`). The Mac compiler
  timed out type-checking a long `?? ""` array in `Clip.matches` that Swift 6.3 on Linux accepts: keep
  such expressions split into typed pieces.

## Three rounds before (user: "QR sheet should close; select and delete; GoodNotes files; sources; phone; clipboard; build the Pencil drawing")
- **Add a device** (Settings → Devices): waits for the new device on the relay, shows "… is set up" and closes. Done button.
- **iPhone**: tabs (Library, Clipboard, Search) on navigation stacks. Tapping an item now opens it
  (the split view never pushed the detail on iPhone). List layout by default, swipe to pin/delete.
- **Select several** (apps + website): Select button, ⌘/⇧-click (Mac, website), bar to move, pin,
  add to a collection or delete; Delete key / Escape on the Mac and website.
- **Clipboard on iPhone/iPad**: saves what was copied whenever Trove opens (Settings → Clipboard);
  iOS asks "Allow Paste?" unless the user allows it in iOS Settings → Apps → Trove → Paste from Other Apps.
- **Sources**: an item that arrives again from another source records it in `alsoFrom` (PROTOCOL §9)
  and is listed under every source. The website gained a Sources section.
- **GoodNotes**: `.goodnotes` files open page by page with the handwriting (pen, pencil, highlighter,
  shapes, typed text, images, PDF/template backgrounds), website and apps (`docs/GOODNOTES.md`).
- **Drawing** (`docs/DRAWING_PLAN.md` phases 1–4; the user said "build it, as good and easy as
  possible"): sketches (✎ Sketch on the website, Add → New sketch / ⇧⌘D in the apps) with
  blank/lined/squared/dotted paper and pages; "Draw on it" for PDFs and images (the file never
  changes). Pen, pencil, marker, highlighter, eraser, colours, size, undo/redo. Website: Apple Pencil
  draws and fingers scroll/pinch. iPad/iPhone: PencilKit (double-tap/squeeze → eraser). Mac: mouse,
  trackpad (Force Touch pressure), pinch zoom. Chosen without asking: pages (not an infinite canvas),
  and a stroke eraser (no partial erase yet).
- CI: TroveCore test failures were hidden by `| tail`; now `pipefail`. Bundles carry the real
  version/build number (SideStore rejected build 23); CI fails if they don't.

## Earlier round (user: "sync isn't working right; previews, versions, folders, Obsidian-style links; plan for Pencil")
- **Sync fixes** (the user didn't say exactly what went wrong, so these are the bugs found by reading the code):
  - **App**:
    - A live ping that arrived mid-sync was dropped. The app then waited up to 30–60 s for the next
      loop, and enrichment and the Mac mirror held the sync lock the whole time, so website changes
      showed up late. Now a request during a sync runs right after it, and the slow steps run after
      the lock is released.
    - App edits were only uploaded by the 30/60 s loop. They now push about 2 s after an edit.
    - The live socket reconnects when the app comes back to the foreground.
  - **Website and app both reading the inbox**: they could both import the same entry (extension,
    email, GoodNotes) and make two items. Now the item id comes from the inbox entry id, so they write
    the same item.
  - **Bridging device** (the Mac with both iCloud and the relay): it now also copies attachments
    across, so files uploaded on the website open on iCloud-only devices.
  - **Ask the user** what exactly looked wrong, if it still does after this round.
- **Folders** (the "main part"):
  - Every new item is filed automatically: by the folders it was dropped or zipped in, else by type
    (Documents, Handwritten, Images, Links, Recipes…).
  - The folder tree is in the sidebar on the website and in the apps. You can drag items and folders
    onto folders, and new/rename/move/delete folders.
  - Unfiled + "Tidy up" files everything already in the vault. **The user's existing items are
    unfiled until they press Tidy up** (or file them by hand).
- **Previews**:
  - The website renders PDFs (vendored pdf.js), GoodNotes notebooks (cover and the documents inside),
    Word, Excel, PowerPoint, Pages/Keynote/Numbers previews, CSV/text, and images, audio and video.
  - The apps add Quick Look for every file, plus GoodNotes and iWork previews.
  - Card thumbnails are made once and synced.
- **Versions**:
  - Uploading a new version or editing a text/CSV file in place keeps the old file. GoodNotes
    re-backups do the same.
  - Note text has a History view with restore.
- **Connections** (Obsidian-like):
  - `[[` autocomplete, links and backlinks, links to notes that don't exist yet (tap to make them),
    unlinked mentions, "maybe related", and Connect to….
  - A small graph per item, and a full Connections graph coloured by folder, with optional tag and
    folder nodes.
- **Drawing**: researched and planned, not built (`docs/DRAWING_PLAN.md`).

## Next steps
**The full plan is `docs/ROADMAP.md`** (sketching vs GoodNotes, search, performance, AI, bridges to
other services, GitHub). Its "Decisions for the user" list is still open; ask before starting items marked ❓.

1. **This round on devices**: the user tries drawing with Apple Pencil on the iPad (app and Safari),
   GoodNotes notebooks, select mode, the iPhone tabs and clipboard; we fix what breaks.
   - Sketching next: the Mac editor's scroll/flip layouts (it shows one page at a time), Connect
     inside the app editor, inline text editing in the apps (now a sheet), a ruler, rotating selections,
     handwriting recognition on the website (no on-device OCR in browsers; could use the relay's AI),
     "export with markup" saved back as a new file version, page templates/sizes (A4, letter).
   - Clipboard next: check the Mac's page/window capture with real browsers; the website can't watch
     the clipboard or run OCR/AI itself.
   - GoodNotes, not drawn yet: sticky notes, rotated lasso items, audio recordings.
2. **The apps compile** (done in 3 CI rounds). Downloads: https://github.com/mrlancus/trove/releases/tag/latest (`Trove.ipa`, `Trove-macOS.zip`). Next: the user runs them, and we fix what breaks at runtime from their screenshots and descriptions.
   - CI builds without signing, so entitlements (App Groups) aren't checked there. When sideloaded with a free account, App Groups may not work; `SharedConfig.container` then falls back to a local folder, and the share extension should use the relay path.
   - The Mac build has no Apple team, so the data protection keychain is unavailable; `Keychain` falls back to the login keychain on macOS.
     The login keychain asks "Trove wants to access key…" (login password) once per item each time the
     app's code changes (every update) and on every read not yet allowed. The user saw it repeatedly
     (two items, and `relayClient` read the token on every use). Now the Mac keeps all secrets in one
     item (`secrets`), read once per launch and cached: at most one question per update. Older builds'
     two items move into it the first time (that launch may still ask twice). Only a paid Apple
     developer team (or a Mac that can build with a personal team) removes the question entirely.
2. **The user tries the website**: create a vault, save the recovery code, add the Chrome extension (Devices & extension → extension code), and set up the iPhone (Safari → the site → Setup code; optionally the share Shortcut). Then close the relay to new vaults.
3. **Sideload on iPhone/iPad** once the IPA builds. Pair the app with a setup code from the website (Devices & extension → paste the recovery code → Make a setup code). Note the web-created vault has no iCloud folder; the app should use the relay.
   - Check: does the app join a relay-only vault cleanly (`VaultStore.join` with no iCloud folder)? Fix if not.
4. **Mac app on the Intel Mac**: unzip, right-click → Open. If macOS is older than 15, lower `deploymentTarget.macOS` in `project.yml`.
5. **Clipboard on real devices:** on the Mac, check ⌥Space opens the palette over other apps, typing searches, ⏎ pastes into the front app after Accessibility is allowed, the watcher records copies (and skips 1Password/Keychain), and images/files paste back. On iPhone, add the Trove keyboard (Allow Full Access) and check clips appear. If App Groups don't work with sideloading, the keyboard shows "Nothing here yet"; then it would need another way to get clips (e.g. Full Access + relay with a read-only clips token, which would need a protocol change).
6. **Then:** price-drop alerts and publish-to-link in the apps (the website doesn't have them yet), the design direction (user hasn't picked yet), and link previews for links saved on the website (needs a relay unfurl endpoint, since browsers can't fetch other sites).
7. **Polish / later:**
   - A TextKit 2 live-styling Markdown editor
   - Move `SyncEngine` snapshot persistence from JSON to SQLite once vaults are big
   - SpeechAnalyzer on OS 26
   - Places map, resurfacing ("on this day")
   - Web app: offline support (service worker), collections editing, a richer editor
   - Notion and Readwise import UI (parsers exist in TroveCore)

## Manual steps for the user
- **Start on the website:** https://trove-relay.lancus.workers.dev → New vault → save the recovery code in a password manager.
- **iPhone/iPad now:** open the site in Safari → Setup code tab, using a code from Devices & extension on the computer. Then Share → Add to Home Screen.
- **Chrome extension:** load `extensions/browser` unpacked (chrome://extensions → Developer mode), then paste the extension code from Devices & extension.
- **Mac updates (one-time setup):** in GitHub → mrlancus/trove → Settings → Secrets and variables → Actions,
  add three repository secrets: `MAC_CERT_P12`, `MAC_CERT_PASSWORD` and `UPDATE_SIGNING_KEY`. A cloud
  session generated their values and gave them to the user privately; they're never in the repo. If
  they're lost, generate new ones (see `scripts/ci-build-apps.sh`) and put the new public key in
  `TroveUpdatePublicKey` in `App/project.yml`. Builds that already have the old key won't trust the new
  one, so the user would download one build by hand. With the secrets set, every build is signed with
  the same certificate, so macOS keeps Trove's permissions across updates, and `update.json` is
  published. The app checks it about 15 s after launch and every 6 h, downloads, verifies the Ed25519
  signature, and asks to restart (Settings → General → Updates; Trove → Check for Updates…).
  - **Status:** ✅ the secrets are set and working. Build 23 (c94035d) was the first signed with the
    certificate ("Trove Self-Signed Code Signing"), and its `update.json` signature was checked
    against `TroveUpdatePublicKey`. If signing breaks again, `macos.log` on `ci-logs` names the
    failing step and fingerprints of the secrets (never their values).
  - Builds up to 23 had version 1.0 (1) inside the app (XcodeGen's default Info.plist), so SideStore
    rejected the IPA and the Mac updater stayed off. Fixed in build 24 (`project.yml` sets both keys
    from `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; CI fails if a bundle's numbers differ).
    **The user has to download build 24+ of the Mac app by hand once**; it updates itself after that.
  - **First time only:** download Trove-macOS.zip by hand, use Open Anyway, and grant Accessibility
    again. After that it updates itself.
- **SideStore sign-in error -80045** (Apple changed sign-in for all sideloading tools in Oct 2026). What
  fixed it for the user: Settings → User Customizations → turn off On-Device Anisette; Anisette
  Servers → "SideStore (new)", auto rotation off; User Customizations → Reset adi.pb (untick keep
  headers); restart SideStore; sign in once. Don't retry repeatedly: Apple can lock the account (-20209).
- **iPhone/iPad with SideStore (instead of Sideloadly):** install SideStore once (needs the Mac for the
  pairing file). Then in SideStore → Sources add
  `https://github.com/mrlancus/trove/releases/download/latest/sidestore.json`. New builds show up as
  updates and install over the old one, keeping its data. SideStore refreshes the 7-day signature on
  the phone by itself.
- **The real apps:** download from https://github.com/mrlancus/trove/releases/tag/latest.
  - **iPhone/iPad:** install `Trove.ipa` with Sideloadly (sideloadly.io; works on Intel Macs) using your Apple ID. Then on the device: Settings → General → VPN & Device Management → trust it, and turn on Developer Mode if asked. Redo every 7 days.
  - **Mac:** unzip `Trove-macOS.zip` and move Trove to Applications. On first open, macOS blocks it; go to System Settings → Privacy & Security → **Open Anyway**.
- **Relay:** deployed at https://trove-relay.lancus.workers.dev. Optional extras in `server/README.md`: an Anthropic key for cloud AI (costs money, so it's your call) and email routing (needs a domain).
- **GoodNotes:** Settings → Cloud & Backup → Auto Backup → WebDAV, using the values from Trove Settings (in the app; the website doesn't show WebDAV settings yet). Set **File Format to PDF** (or both) to see your handwriting in Trove; a GoodNotes-format backup only shows the cover and the documents inside.
- **Existing items:** on the website, Folders → Unfiled → **Tidy up** files everything that was saved before folders existed.

## How the newer features work (built without a Mac)
- **Price-drop alerts:**
  - The item field `priceWatch` is the source of truth. `PriceWatchSync` (run on every sync by relay devices) creates and removes relay watches to match it.
  - The relay checks schema.org prices every ~12h with a Durable Object alarm and pings live sockets on a drop.
  - Apps show a local notification (no push on a free Apple ID), so alerts appear when a device syncs.
  - Privacy: the relay sees product URLs for tracked items only.
- **Publish to link:**
  - The note is stored on the relay in **plaintext** by the user's choice, at `/p/<vault>/<random slug>`.
  - It's rendered with everything escaped and served with a strict CSP and noindex.
  - Re-publishing updates the page; edits aren't pushed automatically.
- **Web app:**
  - It joins as device kind `web` and keeps only derived, non-extractable keys in IndexedDB (see CLAUDE.md rules and PROTOCOL.md §7).
  - It can browse, search, write notes, add links, upload files, resolve conflicts and toggle collections, and it updates live.
  - It can't read the sealed inbox (no private key); the apps import it.
  - One tab at a time; a second tab takes over.

## Decisions made so far
- **Name:** working name "Trove". Ask the user for the final name and suggest 5.
- **Storage:** iCloud Drive vault with per-device journals is the source of truth. The relay is an optional add-on. CloudKit can come later if the user pays for the developer account.
- **Mac app:** not sandboxed (personal use: iCloud Drive path, AppleScript, Obsidian folder). Extensions are sandboxed.
- **Relay AI model:** `CLAUDE_MODEL` defaults to `claude-opus-5-5`. The user wants costs at pennies, so suggest `claude-haiku-5-5` when deploying.
- **Web app keys:** the web app stores derived keys in the browser. That's the one exception to "secrets only in the Keychain". If the user would rather not, remove the `assets` block from `server/wrangler.jsonc`.
- **Bundle ids:** `com.mrlancus.trove(.share/.widgets/.safari)`. App Group: `group.com.mrlancus.trove`.
