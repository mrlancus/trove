# NOTES: status and next steps

_Last updated by the cloud session that wrote the code (Linux, no Xcode)._

## Status
| Part | State | Tested |
|---|---|---|
| `server/` relay (Worker + Durable Object + R2, WebDAV, email-in, AI proxy) | ✅ Done | 20 tests on the Workers runtime |
| `Packages/TroveCore` (sync, crypto, merge, importers, search, library) | ✅ Done | 45 tests, plus an end-to-end test against `wrangler dev` |
| Crypto compatibility Swift ⇄ Worker ⇄ extension | ✅ Verified both directions | fixtures + scripts |
| `extensions/browser` (Chrome; Safari via app target) | ✅ Done | crypto test |
| `App/` (macOS + iOS/iPadOS app, share ext, widgets, Safari ext) | 🟡 Written, **never compiled** | all files pass the Swift parser only |
| Relay deployed to Cloudflare | ⬜ Not yet | – |

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
5. **Relay.** Deploy with `server/README.md`, connect it in Settings, then test live sync, the browser extension, GoodNotes WebDAV with a big notebook, and optionally email-in.
6. **Polish / later:**
   - A TextKit 2 live-styling Markdown editor
   - Move `SyncEngine` snapshot persistence from JSON to SQLite once vaults are big
   - SpeechAnalyzer on OS 26
   - Places map, resurfacing ("on this day"), price-drop alerts (Worker cron), publish-to-link, a web app
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
- **Relay:** `server/README.md` (Cloudflare login, R2 bucket, deploy; optional Anthropic key and email routing).
- **GoodNotes:** Settings → Cloud & Backup → Auto Backup → WebDAV, using the values from Trove Settings.

## Decisions made so far
- **Name:** working name "Trove". Ask the user for the final name and suggest 5.
- **Storage:** iCloud Drive vault with per-device journals is the source of truth. The relay is an optional add-on. CloudKit can come later if the user pays for the developer account.
- **Mac app:** not sandboxed (personal use: iCloud Drive path, AppleScript, Obsidian folder). Extensions are sandboxed.
- **Relay AI model:** `CLAUDE_MODEL` defaults to `claude-opus-5-5`. The user wants costs at pennies, so suggest `claude-haiku-5-5` when deploying.
- **Bundle ids:** `com.mrlancus.trove(.share/.widgets/.safari)`. App Group: `group.com.mrlancus.trove`.
