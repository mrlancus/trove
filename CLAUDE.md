# Trove: notes for Claude

Trove is a "save anything" second brain plus notes app for Mac, iPhone and iPad. It syncs through
the user's iCloud Drive, with an optional Cloudflare relay, and it's end-to-end encrypted. Start
every session by reading **NOTES.md** (status, what's next, manual steps). Specs:
**The product is the Mac, iPhone and iPad apps** (the user's words: "the main thing of this is the app
for mac and ios/ipados; the website is not primary and is there just because we can have it"). Build
and polish features for the apps first; the website gets them only where it's cheap. Prefer Apple's
on-device frameworks (Foundation Models, Vision, NaturalLanguage, PencilKit, Speech) over web or
cloud equivalents.
- `docs/RESEARCH.md`: product spec and constraints
- `docs/PROTOCOL.md`: the byte-level contract shared by Swift, the Worker and the extension
- `docs/ARCHITECTURE.md`: code map
- `docs/ROADMAP.md`: the plan for what to build next

## Layout
- `server/`: Cloudflare Worker relay (TypeScript). **Done and tested.** Don't rewrite it. Change it
  only for a real bug or a protocol gap, and update PROTOCOL.md and the tests in the same commit.
- `Packages/TroveCore/`: shared Swift package (sync, crypto, merge, importers, search). **Done and
  tested on Linux.** Keep it free of UIKit/AppKit/SwiftUI so it stays testable everywhere.
- `extensions/browser/`: MV3 extension (Chrome now; Safari via the app's TroveSafari target).
- `web/`: the web app (vanilla JS, no build). `web/public` is served by the relay as static assets.
  Its `core/` is a JS port of the TroveCore sync code; keep it in step with the Swift code. The
  interop fixtures in `web/test` and `WebInteropTests.swift` catch drift.
- `App/`: the Apple apps. **Written on Linux and never compiled.** Expect compile errors on the first
  `xcodebuild`, and fix them. `project.yml` is the source of truth (XcodeGen); never hand-edit the
  `.xcodeproj`.

## Commands
```bash
./scripts/test-all.sh                                  # relay + TroveCore + extension tests
cd App && xcodegen                                     # (brew install xcodegen) → Trove.xcodeproj
xcodebuild -project App/Trove.xcodeproj -scheme Trove -destination 'platform=macOS' build
xcodebuild -project App/Trove.xcodeproj -scheme Trove -destination 'generic/platform=iOS' build
cd Packages/TroveCore && swift test
cd web && npm test                                     # web core + Swift interop fixtures
cd web && npm run test:e2e                             # needs `npx wrangler dev --local --config wrangler.test.jsonc` in server/
```

## Rules
- User constraints:
  - **Free Apple ID**: no CloudKit, push or Siri entitlement; 10 App IDs per 7 days; 3 apps per device; iOS installs expire after 7 days.
  - Only the **iPad** has Apple Intelligence.
  - The user has a Cloudflare account.
- Swift 6 strict concurrency. Deployment targets are iOS 18 and macOS 15. Use Liquid Glass and Foundation Models behind `#available(iOS 26, macOS 26, *)`.
- Never put vault secret keys anywhere but the main app's Keychain. Extensions get the public key only (`SharedConfig.Capture`).
  The one exception is the web app, which the user adds on purpose and can revoke. It keeps only
  non-extractable WebCrypto keys in IndexedDB, never raw key bytes (PROTOCOL.md §7). The user has no
  Apple Silicon Mac, so the apps are built and checked on GitHub Actions (NOTES.md); that doesn't
  make the website the main product.
- Commit after each working step and push to `main`. Keep NOTES.md current (what's done, next steps, manual steps for the user) so a fresh session can say "read NOTES.md and continue".
- Ask the user before decisions that are theirs (name, design direction, anything that costs money).
