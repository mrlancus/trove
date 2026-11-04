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
- `docs/MASTER_PLAN.md`: the plan for what to build next (improve everything, performance and battery first)
- `docs/ROADMAP.md`: the earlier plan, mostly landed

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

## App quality checklist (read before touching `App/`; every item is a mistake already made once)
The apps can't be run here, so a mistake usually reaches the user's iPad before anyone sees it. Check
each change against this list before pushing, and say in the commit what you checked.

**SwiftUI that can't crash or lag**
- Keep view types shallow. A `body` or `@ViewBuilder` property that grows past roughly 15 child views,
  or any `ViewThatFits`/`if`/`switch` holding several large alternatives, gets split into its own
  `struct … : View` (best: also redraws less) or wrapped in `AnyView` at that boundary. A too-deep type
  overflowed the main thread's stack and crashed the editor on opening (InkEditorView.toolbar, 0.1.169).
- One view, one job: new screens and toolbars are made of small named structs, each watching only the
  `@Observable` state it shows, so a change redraws one part, not the screen (MASTER_PLAN P3).
- Nothing slow in `body` or a getter it calls: no file or database reads, PDF/image decoding, sorting or
  filtering of big arrays, regex, or `Date()` formatting in loops. Work it out once (cached, or in the
  model when its input changes) and off the main thread (`Task.detached`), then show it.
- Lists and grids of user content are `Lazy…`; images are decoded at the size shown (P7).
- Main-thread budgets (docs/prompts/develop-perf-testing.md): a tap shows feedback within 50 ms, a frame
  takes under 16.7 ms (8.3 ms on ProMotion), no hang over 100 ms, Pencil-to-ink adds nothing to PencilKit.
  Anything that might break one is measured (Diagnostics, `perfWorkflow`, an XCTest metric), not assumed.
- Drawing and zooming: never re-render a whole page or the visible area as one image per zoom step;
  use vector layers, the GPU ink, or tiles (`InkTiledPageLayer`) so detail arrives tile by tile.

**Swift 6 and the build**
- Don't capture a `var` in a `Task`; copy it to a `let` first. Mark static helpers called from
  `Task.detached` `nonisolated`; never call `@MainActor` code from a background closure.
- A tuple with optional elements doesn't take a non-optional value reliably: use a small struct.
- When rewriting a block with a script or a range replace, list the declarations in it first
  (`grep -n '^struct \|^final class \|^enum \|func '`) and make sure every one you didn't mean to
  remove is still there afterwards (ItemConceptsSection was cut out with the old answer pad).
- Two branches can each add the same name (two `DiagnosticsSection`s after merging Sketch 2): grep a
  new type or view name across `App/` before adding it.

**Checking a push**
- A push isn't done until CI says so. Read the TroveCore result from the Swift Testing lines (`✘`,
  "Test run with N tests … failed"), not the XCTest "All tests passed" line, which prints even when
  Swift Testing fails. `RESULT skipped` on the ci-logs branch means the build never ran: find out why.
- Changing behaviour means updating the tests that pinned the old behaviour in the same commit, with a
  comment saying what changed and why; never delete an assertion to get green.
- A crash report (`.ips`) from the user is read before guessing: the faulting thread's first frames in
  `Trove` name the function.

**Looks**
- Every new screen uses `Theme` tokens (colours, `Theme.Space`, `Theme.Radius`, `card`, `glass`), one
  clear primary action, 44 pt targets, Dynamic Type, and works at iPhone SE width and iPad Split View.
- The user judges at first glance ("if it doesn't immediately look good that's a massive problem"):
  no default grey forms for main screens, no walls of text or numbers, empty states that say what to do.
