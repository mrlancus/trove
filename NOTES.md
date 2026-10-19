# NOTES: status and next steps

_Last updated by the cloud session that wrote the code (Linux, no Xcode)._

## Status
| Part | State | Tested |
|---|---|---|
| `server/` relay (Worker + Durable Object + R2, WebDAV, email-in, AI proxy, price watches, publish-to-link, serves the web app) | ✅ Done | 33 tests on the Workers runtime (incl. a real MIME email) |
| `Packages/TroveCore` (sync, crypto, merge, importers, search, library, price watches, publishing) | ✅ Done | 49 tests, plus an end-to-end test against `wrangler dev` |
| Crypto/sync compatibility Swift ⇄ Worker ⇄ extension ⇄ web app | ✅ Verified both directions | fixtures + scripts |
| `extensions/browser` (Chrome; Safari via app target) | ✅ Done | crypto test + real-Chromium e2e (save, offline queue) |
| `web/` web app (any browser, served by the relay) | ✅ Done | 11 unit/interop tests, relay e2e, real-Chromium UI e2e |
| `App/` (macOS + iOS/iPadOS app, share ext, widgets, Safari ext) | 🟡 Written, **never compiled** | all files pass the Swift parser only |
| Relay + web app deployed to Cloudflare | ✅ **https://trove-relay.lancus.workers.dev** | web e2e, Chromium UI e2e and the Swift integration test all pass against production |

**Design mockups:** three directions (A Glass, B Editorial, C Midnight; Mac + iPhone each) in a
private artifact: https://claude.ai/artifact/A9P4DTybx1EaSzG3TcayJg. Ask the user which one to build
before restyling `App/Sources/Views`. The web app currently uses a neutral style close to Midnight.

## Next steps (Mac session)
1. **Get it compiling.**
   1. Run `brew install xcodegen`, then `cd App && xcodegen`, then open `Trove.xcodeproj`.
   2. In Xcode, select each of the 4 targets → Signing & Capabilities → choose the user's Personal Team. Or set `DEVELOPMENT_TEAM` in `project.yml` and re-run xcodegen.
   3. `xcodebuild … -destination 'platform=macOS' build`, then fix errors until it builds. Then do the same for iOS.
   4. Likely trouble spots:
      - Exact Foundation Models API shapes in `OnDeviceAI.swift` (`@Guide(.count(3...6))` and `.anyOf`)
      - Strict-concurrency complaints (closures capturing non-Sendable types)
      - `supportedDestinations` in XcodeGen (needs XcodeGen ≥ 2.39)
      - The Safari extension resources folder reference
   5. If App Groups can't be provisioned on the free team, `SharedConfig.container` falls back to a local folder. The share extension then can't hand items over, so note it and use the relay path.
2. **Run Phase 0 spikes** and record the results in `docs/RESEARCH.md` §11:
   - **The big one:** whether iPhone/iPad can read/write a picked iCloud Drive folder with a free account. The flow is onboarding → "Choose a folder".
   - Whether Foundation Models are available on the iPad (Settings → Intelligence shows the status).
   - Whether speech transcription works on the iPhone.
   - Whether the Safari extension loads.
3. **Mac MVP pass.**
   1. Create a vault in iCloud Drive. Add notes, links and files, and check the cards, detail view and search.
   2. Test the ⌘⇧Space capture window and the menu bar.
   3. Show the user the UI and iterate on the design. The prompt asks for 2–3 directions.
4. **iPhone + iPad.**
   1. Pair with the QR code from Mac Settings → Devices.
   2. Test share sheet saves, widgets, the Control Center control, and Shortcuts ("Save Clipboard to Trove" for Back Tap).
   3. Check that the iPad enriches items saved on the other devices.
5. **Relay.** It's **already deployed** at `https://trove-relay.lancus.workers.dev`, with R2 bucket `trove-blobs` and `CLAUDE_MODEL=claude-haiku-5-5`. To redeploy from the Mac, run `npx wrangler login` once, then `npx wrangler deploy` in `server/`.
   1. Connect it in the app's Settings → Cloudflare relay.
   2. **Once the user's vault exists,** set `ALLOW_NEW_VAULTS` to `"false"` in `server/wrangler.jsonc` and redeploy, so strangers can't create vaults.
   3. No `ANTHROPIC_API_KEY` secret is set yet, so cloud AI is off. Ask the user before adding one: it's billed separately.
   4. Then test:
   - live sync and the browser extension
   - GoodNotes WebDAV with a big notebook, and optionally email-in
   - **the web app**: open the relay URL in a browser and paste a setup code from Add a device
   - **price-drop alerts**: on a product link, ⋯ → Track price drops. Check it in the detail view after a sync
   - **publish to link**: on a note, ⋯ → Publish to link; the link is copied. Open it in a private window, then Remove public link
6. **Polish / later:**
   - A TextKit 2 live-styling Markdown editor
   - Move `SyncEngine` snapshot persistence from JSON to SQLite once vaults are big
   - SpeechAnalyzer on OS 26
   - Places map, resurfacing ("on this day")
   - Web app: offline support (service worker), collections editing, a richer editor
   - Notion and Readwise import UI (parsers exist in TroveCore)

## Manual steps for the user
- **Install and sign in:** install Xcode and sign in with your Apple ID (Xcode → Settings → Accounts).
- **iPhone/iPad:**
  - Plug in, tap Trust, then turn on Settings → Privacy & Security → Developer Mode.
  - After the first install, go to Settings → General → VPN & Device Management → trust your Apple ID.
- **Every 7 days:** plug in and run the app from Xcode again (free account limit). Your data is safe in iCloud.
- **Mac permissions:**
  - Automation → Notes, for Apple Notes mirroring.
  - Keep "Trove" in iCloud Drive set to **Keep Downloaded** (right-click it in Finder). Do the same in the Files app on iOS.
- **Relay:** already deployed at https://trove-relay.lancus.workers.dev. Optional extras in `server/README.md`: an Anthropic key for cloud AI (costs money, so it is your call) and email routing (needs a domain).
- **GoodNotes:** Settings → Cloud & Backup → Auto Backup → WebDAV, using the values from Trove Settings.

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
