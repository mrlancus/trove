# NOTES: status and next steps

_Last updated by a cloud session (Linux, no Xcode; Swift 6.3.1 for TroveCore can be installed to /opt/swift). The user has only an Intel Mac, so there is no local Xcode._

## Status
| Part | State | Tested |
|---|---|---|
| `server/` relay (Worker + Durable Object + R2, WebDAV, email-in, AI proxy, price watches, publish-to-link, serves the web app) | ✅ Done | 35 tests on the Workers runtime (incl. a real MIME email) |
| `Packages/TroveCore` (sync, crypto, merge, importers, search, library, price watches, publishing, folders, links, versions, GoodNotes ink, drawing, sketch tools, clip insights) | ✅ Done | 82 tests (run on Linux with Swift 6.3.1 at `/opt/swift` when installed), plus an end-to-end test against `wrangler dev` |
| Crypto/sync compatibility Swift ⇄ Worker ⇄ extension ⇄ web app | ✅ Verified both directions | fixtures + scripts |
| Import (zip, folders, exports; app + website) | 🟡 Core + website tested (Swift + JS on one zip fixture, Chromium e2e); app builds on CI, not run on a device | 5 Swift + 1 JS test, UI e2e |
| `extensions/browser` (Chrome; Safari via app target) | ✅ Done | crypto test + real-Chromium e2e (save, offline queue) |
| `web/` web app (any browser, served by the relay): create vault, recovery, add devices, inbox import, folders, viewer, connections, select mode, sources, GoodNotes viewer, drawing, sketch tools, clip editor | ✅ Done | 28 unit/interop tests; 9 e2e (relay + real Chromium, incl. `draw.e2e.mjs`) passing locally. Deployed (version 9a68b61f, after the clipboard + sketching round) |
| `App/` (macOS + iOS/iPadOS app, share ext, widgets, Safari ext) | 🟢 **Builds** on GitHub Actions (Xcode 26.3) for macOS (universal) and iOS; not yet run on a device | CI: `.github/workflows/apps.yml`; downloads at the `latest` release |
| **Clipboard history** (Mac ⌥Space palette, iPhone/iPad screen + Trove keyboard, website view; synced clips, PROTOCOL.md §8): source app/page/window, insights, rule tags, AI names/summaries, OCR, editing, main search, auto-save | 🟡 Core + website tested; apps build on CI, not yet run on a device | 8 Swift + 3 JS unit tests, `clip-cases.json` (insights + rules), Chromium e2e |
| **Folders + auto-filing, file previews, versions, connections/graph** (PROTOCOL.md §9) | 🟡 Core + website tested; apps written, building on CI, not yet run on a device | 9 Swift + 7 JS unit tests on shared fixtures, Chromium e2e (`organize.e2e.mjs`) |
| **Drawing / Apple Pencil** (sketches and ink on PDFs/images, PROTOCOL.md §10): 6 pens, erasers, lasso, shapes, text, pictures, page panel, endless canvas, PDF export, handwriting search | 🟡 Core + website tested; apps written (PencilKit pens + Trove tools on iPad/iPhone, all tools on Mac), build on CI, not yet run on a device | 5 Swift + 3 JS unit tests on `ink-cases.json` + `ink-geometry.json`, 2 Chromium e2e |
| **GoodNotes notebooks with handwriting** (`docs/GOODNOTES.md`) | 🟡 Website checked against real notebooks and GoodNotes' PDF exports; apps building on CI | shared fixture `ink.goodnotes` (Swift + JS) |
| Relay + web app deployed to Cloudflare | ✅ **https://trove-relay.lancus.workers.dev** (not yet with the search/tags round) | web e2e, Chromium UI e2e and the Swift integration test all pass against production |

**Design mockups:** three directions (A Glass, B Editorial, C Midnight; Mac + iPhone each) in a
private artifact: https://claude.ai/artifact/A9P4DTybx1EaSzG3TcayJg. Ask the user which one to build
before restyling `App/Sources/Views`. The web app currently uses a neutral style close to Midnight.

## The user's setup (important)
- **No Apple Silicon Mac.** The user's Mac is Intel, and current Xcode needs M1 or later. So:
  - **The website is the main client for now:** https://trove-relay.lancus.workers.dev. It can create the vault, sync, import the inbox and add devices.
  - **The Apple apps are built on GitHub Actions** (`.github/workflows/apps.yml`, Xcode 26.3 on `macos-15`; the repo is public, so it's free). Compile errors are fixed from cloud sessions:
    1. `git fetch origin ci-logs` then `git show origin/ci-logs:macos-errors.txt` (and `ios-errors.txt`, the full `*.log`, `RESULT`).
    2. Run status: `gh api repos/mrlancus/trove/actions/runs`.
  - **Installing:** the run's artifacts are `Trove-macOS` (universal, signed with Trove's self-signed certificate) and `Trove-iOS` (`Trove.ipa`, unsigned). The user installs the IPA with **Sideloadly** using their free Apple ID; that needs redoing every 7 days.
- **The relay is deployed** with `ALLOW_NEW_VAULTS=true`. The user needs that to create the vault on the website. **After they've made their vault, set it to `"false"` and redeploy.** The token for `wrangler deploy` is in the cloud environment (`CLOUDFLARE_API_TOKEN`).

## Latest round (user: "sheet off the page, clipboard tags, GoodNotes source, type to search, where's sketching, no emoji, faster search, Liquid Glass icon")
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
- Tests: TroveCore 85 (new: GoodNotes sources, sorted-vocabulary prefixes, `#tag`, tag colours),
  web 31 unit + 9 Chromium e2e (new: tag sections, type-to-search, Sketches section).
- **Website not deployed this round**: the deploy was blocked by the session's permission
  settings. Deploy with `cd server && npx wrangler deploy` (the token is in the cloud environment).

## Round before (user: "clipboard upgrade" + "sketching, aiming at GoodNotes")
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

## Two rounds before (user: "QR sheet should close; select and delete; GoodNotes files; sources; phone; clipboard; build the Pencil drawing")
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
1. **This round on devices**: the user tries drawing with Apple Pencil on the iPad (app and Safari),
   GoodNotes notebooks, select mode, the iPhone tabs and clipboard; we fix what breaks.
   - Sketching next: inline text editing in the apps (now a sheet), a ruler, rotating selections,
     handwriting recognition on the website (no on-device OCR in browsers; could use the relay's AI),
     "export with markup" saved back as a new file version, page templates/sizes (A4, letter).
   - Clipboard next: check the Mac's page/window capture with real browsers; the website can't watch
     the clipboard or run OCR/AI itself.
   - GoodNotes, not drawn yet: sticky notes, rotated lasso items, audio recordings.
2. **The apps compile** (done in 3 CI rounds). Downloads: https://github.com/mrlancus/trove/releases/tag/latest (`Trove.ipa`, `Trove-macOS.zip`). Next: the user runs them, and we fix what breaks at runtime from their screenshots and descriptions.
   - CI builds without signing, so entitlements (App Groups) aren't checked there. When sideloaded with a free account, App Groups may not work; `SharedConfig.container` then falls back to a local folder, and the share extension should use the relay path.
   - The Mac build is ad-hoc signed, so the data protection keychain is unavailable; `Keychain` falls back to the login keychain on macOS.
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
