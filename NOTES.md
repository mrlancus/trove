# NOTES: status and next steps

_Last updated by a cloud session (Linux, no Xcode; Swift 6.3.1 for TroveCore can be installed to /opt/swift). The user has only an Intel Mac, so there is no local Xcode._

## In progress
- Cloud session 2026-11-05 (session_01BrjgWvEbe6KQZPGGaKA59d): building `docs/plans/learn-pivot-plan.md` from
  `docs/plans/learn-pivot-build-prompt.md`, step by step (see "Learn pivot" below for where it's got to).

## Learn pivot (2026-11-05): Trove is now a place to learn
**Start here.** The plan is `docs/plans/learn-pivot-plan.md` (§9 order of work, §10 decisions, all taken),
built from `docs/plans/learn-pivot-build-prompt.md`. Read the review (`learn-pivot-review.md`) before changing
anything it covers. Decisions from plan §10, short form:
- Q1 the section is **Learn** (was Develop); the app stays Trove (a rename later is the display name only).
- Q2 RSS feeds and add addresses stay; the Telegram bot is hidden like the GitHub bridge.
- Q3 the Mac's Markdown copy of notes is **off by default**, with a setting.
- Q4/Q7 Haiku 5.5 writes questions in the style of real papers: write at low, check at low, rewrite once at
  medium on failure; switch to medium-first if more than half need the rewrite.
- Q5 iPhone tabs: Home · Learn · Library · Clipboard · Search.
- Q6 relay AI allowance 10M tokens/month (Worker secret `AI_MONTHLY_LIMIT`, already set).
- Q8 new vaults on the relay need an 8-digit code (`VAULT_CREATE_CODE`, which you set).
- Q9/Q10 close copies of real questions are the goal; only exact or near-exact wording is refused.
- Q11 the shared question bank (uploads private to your users' vaults); Q12 overnight batches, off until the
  relay has `ANTHROPIC_API_KEY`.

Decisions this session took for you (undo in brackets):
- The website doesn't pause bridges itself; the apps do it on launch (one place to get it right). [port
  `BridgePause` to `web/public/core` if you want the website to do it too.]
- The readable copy setting is per Mac (`VaultConfig.readableCopy`), like the mirror owner. [none needed]
- Practise this makes 3 questions at a time; the start of a long lecture (12,000 characters of material) is used.
  [`practiseThis(_:count:)`, `LearningMaterial.limit`]
- Specification statements are worked out on each device and cached, not stored as records (they're the same on
  every device from the same PDF, and a course has hundreds). Problems and attempts name them by concept id.
  [store them as `spec` records with `inSpec` edges if the website ever needs them without the PDF]
- A streak's rest day: one missed day between practice days. [`PracticeStats`: allow more, or none]
- Mixing topics: a set draws from topics it doesn't have yet first. [`Practice.mixTopics = false`]
- "Explain why" isn't saved; saying it is the point. [keep it on the attempt if you'd like to see it again]
- A typed question in your own course is a note (so it syncs, searches and shows its answer). [none needed]
- Trove-made questions are notes in Learn → Trove-made → course, with the scheme under "**Answer:**". [none needed]
- "More like this" writes 2 questions at a time. [`makeQuestions(like:count:)`]
- The bank is one Durable Object for every course (simple, serialised); bank reads need a device of a vault on your
  relay. [split per course if it ever gets busy]
- Which bank questions this device has taken is kept on the device (UserDefaults), not synced. [sync it if you
  practise the same course on two devices and see repeats]

Steps done (plan §9):
- **Step 0** (docs): README, CLAUDE.md's first lines and docs/RESEARCH.md's pitch lead with learning; "Develop"
  is **Learn** in the UI (sidebar, iPhone tab, screen title, the Develop card label). Code names (`DevelopModel`,
  `.develop`) are unchanged on purpose.
- **Step 1** (hide, plan §3): `App/Sources/Platform/Features.swift` and `web/public/features.js` (`graph`,
  `obsidian`, `githubBridge`, `telegramBridge`, all off). Hidden: Connections (sidebar, iPhone list, ⌘K), the
  graph on items, the clipboard Map (website), Settings → Obsidian sync, GitHub and Telegram in Bridges. On
  launch the app pauses running GitHub/Telegram bridges on the relay and remembers them in the synced
  `settings.features` (PROTOCOL §8), so turning a flag on resumes exactly those (`BridgePause`). The Mac's
  Markdown copy is **off by default**: Settings → Other apps → "Keep a readable copy of my notes in iCloud
  Drive" (says it isn't encrypted), with "Delete the copy…". trove-mcp: a "paused" line in `mcp/README.md`.
  Tests: `BridgePauseTests`, Mac `FeaturesTests`, UI `testConnectionsIsHidden` / `testConnectionsWithFeaturesOn`
  (`-TroveFeatures all`), web e2e flags off and on (`trove.features`). Device tests: `docs/testing/learn.md`.
  To show a feature again: set its flag to `shipped: true` (apps) or `true` (website) and build.
- **Step 2** (privacy, plan §7): location recording is **off by default** (`SharedSetting.recordPlaces.standard`
  false, `ClipboardStore.recordPlaces = false`, the website's `appSetting`), and every new vault writes
  `recordPlaces: false` into `settings.app` (apps: `writeNewVaultDefaults`; website: `Vault.create`) so older
  builds agree. Existing vaults keep an explicit choice; a vault where nobody chose now reads as off in new
  builds. The Settings line says what it records. Tests: `PrivacyDefaultTests`, `core.test.mjs`, `relay.e2e.mjs`.
- **Step 2b** (vault code, plan §7 E2): `server/src/gate.ts`. With the secret `VAULT_CREATE_CODE` set, `POST
  /v1/vaults` needs `x-trove-create-code`; 5 wrong per IP an hour, 50 across the relay an hour (then a pause);
  hashed constant-time compare; `GateObject` Durable Object (migration `v2`). No secret: as before. The website's
  Create form and the apps' Settings (Turn on the relay / Connect relay) show a code field only when the relay
  asks. PROTOCOL §4 "Creating a vault". Tests: `server/test/gate.test.ts` (6), `VaultCodeTests`, `core.test.mjs`.
  **Not deployed.** Your steps: (1) choose an 8-digit code; (2) Cloudflare dashboard → Workers & Pages →
  trove-relay → Settings → Variables and Secrets → Add → type Secret, name `VAULT_CREATE_CODE` (or `npx wrangler
  secret put VAULT_CREATE_CODE` in `server/`); (3) say "publish" so the new relay code is deployed. Until both
  are done, the relay still accepts new vaults from anyone.
- **Step 2c** (specifications, plan §C6): every finder records the course's specification as a `spec` doc
  (`<spec id>-spec`; how each board is read: docs/CATALOGUE.md "Specifications"); the catalogue was rebuilt.
  Choosing a course downloads it first (`downloadPlan` puts it first; `fetchSpecification` on adding a course and
  once per launch for existing ones, Wi-Fi only; synced like a downloaded paper). `SpecReader` (TroveCore) reads it
  on the device into numbered statements with their text (headings, codes like AQA Maths' N1, History's options;
  contents pages, running footers and front/admin chapters dropped), cached per file. The course screen shows a
  Specification section (topics → statements). Catalogue bug fixed: option papers (AQA GCSE History) pair with
  their own option's mark scheme (`Catalogue.optionKey`), never another's. Tests: `SpecReaderTests`,
  `optionPapersPairWithTheirOwnOptionsScheme`, `RealSpecTests` (real specs by `scripts/catalogue/spec-sample.py`,
  never committed; checked on AQA 7408 (191 statements), 8461 (126), 8300 (79), 8145 (22)).
- **Step 3** (navigation, Home, first launch, plan §4 B1–B3): iPhone tabs Home · Learn · Library · Clipboard ·
  Search; the sidebar has Learn second. Home: greeting and the next goal date, Up next (one small session, due
  cards), three quiet numbers, Continue, Jump back in, Pinned, and small New note / New sketch / Import. Split into
  small views; the shelves are worked out off the main thread when the library changes. After a new vault: "What
  are you learning?" (an exam course → the course picker; something of my own → Make your own course; just my
  notes). Tests: UI `testLearnComesSecond`, `testLibraryScrollsAndShows`; TEST-HOME-001 updated; TEST-LEARN-007.
- **Step 3b** (study rules, plan §1.1): Up next is 3 questions (~10 min); "days in a row" counts a single missed
  day as a rest day (two in a row end it), shown with a calendar, no flame and no warnings; `Practice.pick` mixes
  topics (draws from new topics first) and `interleave` keeps the same topic from coming twice in a row (cards
  are untouched: StudyView keeps decks in blocks); "Got it right. In a sentence, why does it work?" after a right
  answer only; the hint ladder never gives the full solution before you've written something; attempts record
  `shownAt` / `shownBeforeTrying` when the scheme or a full solution was shown. Tests: `aRestDayKeepsTheStreak`,
  interleaving in `practicePicksAreSeededFreshAndFiltered`, `DevelopHintTests` (with a fake model).
- **Step 4** (half-built items, plan §4 B4): Your work groups questions by the specification's subtopic
  (questions are tagged with the statement they're about when split, and old ones once the spec is read:
  `SpecReader.best`, `Library.addSkills`); thumbnails of the working on each attempt; Library, Settings, item card
  and item detail moved onto `Theme` tokens where the values matched exactly (no visual change). Still to do
  from "Not done": a Lock button on the website.
- **Step 5** (own courses, plan §C1): Learn → Add a course → Make your own… (or first launch's "Something of my
  own"): a name and topics. The course screen lists topics with Add a question (typed question and answer, kept
  as a note, marked by you) and New note for this topic, and Practise (its topics' questions, mixed). Goals on own
  courses find questions by topic (`Goal.practiceFilter`, `Practice.Filter.orSkills`). A course this device's
  catalogue doesn't know shows "Not in the catalogue" instead of a spinner. PROTOCOL §13. Tests: `CourseTests`
  (sync, topics, campaign filter, shared fixture `course-cases.json`), web `develop.test.mjs`. Update every device
  in the same week: older builds can't open an own course.
- **Step 6** (questions in the style of real papers, plan §C2.3, §C9): `QuestionWriter` (TroveCore): brief v1 as a
  cached system block, the topic's real questions and schemes as a cached block (`cache_control`), structured
  output (`output_config.format`, a closed JSON schema), Haiku 5.5 at low; free code checks (scope, marks adding
  up, answers inside their ranges, an earlier answer printed later, copied wording or guidance, every tag); a check
  call at low that never sees the scheme; one rewrite at medium; dropped if it fails again. In the app: **More
  like this** after marking a question (your key only), saving what passes as a "Trove-made, in the style of …"
  note with `madeFrom` edges to its examples, and **This is wrong** on a Trove-made question. The tutor rule was
  step 3b. **Test set run** (docs/plans/learn-pivot-effort-tests.md "Run 2"): no key of yours here, so it ran with
  Haiku subagents on the real PDFs: 7 of 9 kept (5 at low, 2 after the rewrite), 2 dropped, rewrites 44%, so
  writing stays at low. Tests: `QuestionWriterTests` (fixtures `question-cases.json`, a fake model for the whole
  pipeline, the exact Claude request), `TestSetCodeChecks` (by hand, `TROVE_TESTSET=`).
- **Step 6b** (shared bank, plan §C7): relay `server/src/bank.ts` (`BankObject`, R2 `bank/<spec>.json`), PROTOCOL §4
  "Question bank": device tokens of this relay's vaults only, the whole course per file, well-formed uploads only,
  50 a vault a day, pending → good after 3 different vaults' attempts, out after 2 flags, only hashes of vaults
  kept. The app looks in the bank before writing (`QuestionBank.pick`: unseen, same spec point, good first), offers
  what it writes from board papers (never from your own material; Settings → AI → "Share the questions Trove writes
  from board papers", on by default), reports attempts and "This is wrong". Tests: `server/test/bank.test.ts` (5),
  `anUnseenBankQuestionIsPickedBeforeWriting`. Not deployed.
- **Step 6c** (overnight batches, plan §C8): `server/src/batches.ts`, run by the bank's alarm, **off until the relay has
  `ANTHROPIC_API_KEY`** (your money). Nightly: short spec points (under 3 questions) in courses your users read,
  ≤ 200 requests, within `AI_MONTHLY_LIMIT`; Message Batches at low with the real paper and scheme as PDFs (fetched
  from the board at batch time, never stored); code checks; a check batch; passes added as pending; failures
  rewritten once at medium the next night. PROTOCOL §4. Tests: `server/test/batches.test.ts` (a fake batch API:
  submit, poll, results out of order, check, pending, medium rewrite, cap, allowance). Not deployed.
- **Step 7** (cards in Learn, plan §4 B1): Learn → Cards lists your flashcard decks with due and new counts (most due
  first) and opens the existing StudyView for a deck or for everything due; Home's Up next shows the due count.
  Test: `DeckTests`, TEST-LEARN-011.
- **Step 8** (notes and the clipboard, plan §6): a course's spec topic lists its notes (`about` edges) with **New note
  for this topic** (own courses had it in step 5); **Practise this** on any note, PDF or sketch writes 3 questions from
  it (with real questions on the same topic as the style when there are some; never shared) and opens them in
  Learn, the item linked as their source; on a sketch with a recorded lecture it's **Make questions from this
  lecture**. Transcripts (ink audio, already built) now use SpeechAnalyzer on iOS/macOS 26 when the locale's model is
  installed (checked at runtime, installed on first use), else the old recognizer a minute at a time. A clip's
  details have **Save to a course…** (course → topic). Test: `yourOwnMaterialBecomesQuestions`, TEST-LEARN-012.
  The location permission text now says it's off unless chosen.
- **Step 9** (other kinds of practice and checkpoints, plan §C3, §C5): problems carry `format` (`written` default and
  not written down, `recall`, `rated`, `spoken`; PROTOCOL §13). In your own course, Add a question has a Kind. A
  rated one shows a timer and four ratings (Couldn't yet / Shaky / Mostly / Nailed it → 0, ⅓, ⅔, 1), a spoken one
  records you, writes it down on the device and shows it beside the answer, then you rate it; both are self-marked
  evidence. Goal plans put a checkpoint (a short mixed quiz of what you've practised, never what's already safe)
  every 4th day and split each day into sessions of at most 20 minutes. Tests: `PracticeFormatTests` (do-and-rate
  is self-marked evidence; older records are written), checkpoints in `CampaignTests`.
- **Catalogue rebuilt** (2026-11-05): 683 courses, 666 with their specification (AQA 111/111, OCR 96/96, Eduqas 77/77,
  WJEC 101/102, Cambridge 133/133, Pearson 148/164: some GCSEs aren't tagged by Pearson's search; AS courses
  share the A level's document). WJEC's Health and Social Care site didn't answer once (502); it kept its listing.

## Decisions taken for you (Develop, performance and testing; overrule any of them)
From `docs/prompts/develop-perf-testing.md` ("don't ask me, decide and log it"). Full reasoning:
`docs/DEVELOP_PLAN.md` §F (and `docs/PERF_AUDIT.md` for Part 2). Short form, with how to undo:
1. **Slice spec: AQA A-level Physics 7408, topic momentum** (the seeded momentum skills appear only for a Physics course). Superseded for papers by 2.
2. **Catalogue: every board that can be read, GCSE + IGCSE + AS/A-level, every subject** (you, 2026-11-04: "all
   subjects", "include CIE and IGCSE", "terms don't matter with the way we're doing it"). Built from the boards'
   own listings by `scripts/catalogue/build.py`, rebuilt weekly by CI (docs/CATALOGUE.md). In: AQA, OCR, Eduqas,
   WJEC, Cambridge, **Pearson Edexcel** (through its finder's search service with the key its page gives every
   visitor: your choice, 2026-11-04; public files only). **Not in: CCEA**: it answers 403 "Your IP or Country has been
   blocked" to cloud machines whatever the request says (tested 2026-11-04), so it's not worked around. You
   chose the in-app browser instead: Upload → From a board's website → CCEA (on your own connection).
   BPhO/UKMT and anything else: your uploads.
3. **Board papers you download sync too** (changed by you, 2026-11-04: "can't it technically count as an
   upload"): each is kept as a `paper.<doc id>` item in your trove (Practice papers → the board, not sent for
   enrichment), so another device copies it instead of downloading. A switch on each course ("Sync downloaded
   papers to my other devices", on by default) turns it off. Your own uploads were already items and sync.
   Cost: iCloud Drive space, roughly 1–3 MB a file. Undo: turn the switch off.
4. **Develop data syncs to the website, no website UI yet** (JS port of the formats and mastery only).
5. **Marking on the device by default** (tick the mark scheme, numeric check); **AI marking only when you tap it**,
   sending a crop of a handwritten answer. Handwriting reading stays on the device (MASTER_PLAN decision 9 kept).
6. **No XP.**
7. **AI defaults: Haiku 5.5 low; medium only for hard questions by a fixed rule; one medium re-check of uncertain
   marks; never a dearer model by itself.** The relay should cache and count cache reads at a tenth; the 1M-token
   allowance stays (raising it spends your money).
8. **Navigation: Develop in the iPad/Mac sidebar, a 4th iPhone tab "Practise", and Practise this on items.**
9. **Mastery: ability (1PL, information-weighted) + FSRS retention, derived from attempts, never stored.**
10. **Concept ids from names; automatic merge only for identical word sets.**
11. **Edges are their own records** (deterministic ids); old `links` and wikilinks read as `related`.
12. **No topic lists shipped**: parsed on your device from the downloaded spec. Get legal advice and ask the
    boards before any public launch.
13. **Anki: TSV with guids first, `.apkg` (legacy schema) next, never `.colpkg`.**
14. **Develop is designed around the iPad first.**
15. **Diagnostics: local only, with Export and an optional "Save a copy to the vault"** (overrides MASTER_PLAN
    decision 4's "always in the vault").
16. **Design: A Glass** (MASTER_PLAN decision 1; NOTES said it was still open). Tokens in one place.

17. **Courses are synced records** (`course.<spec>`, PROTOCOL §13): choose once, every device shows them; each
    device downloads the papers it practises.
18. **Splitting: best of the board's layout and a generic one** (whichever finds more marks); parts carry their
    stems; uploads without readable text become one question per page.
19. **The apps fetch the catalogue from this repo** (`raw.githubusercontent.com/mrlancus/trove/main/catalogue/`) at
    most once a day, with the bundled copy as the fallback, so new series arrive without an app update.
20. **The tutor speaks only when you tap** (you, 2026-11-04).
21. **One sketch per attempt**, in Sketches → Practice → course → topic; Try again makes a new one, so
    attempts can be compared. Undo: none needed; delete the folder to clear them.
22. **The question is an unlocked picture** on the page (you can lock it); on a whiteboard it's 520 points wide.
23. **The app opens on Home** (was Recent; UI_AUDIT U2 said Recent on iPhone). Undo: `AppModel.selection`'s default.

## Status
| Part | State | Tested |
|---|---|---|
| `server/` relay (Worker + Durable Object + R2, WebDAV, email-in, AI proxy, price watches, publish-to-link, serves the web app) | ✅ Done | 35 tests on the Workers runtime (incl. a real MIME email) |
| `Packages/TroveCore` (sync, crypto, merge, importers, search, library, price watches, publishing, folders, links, versions, GoodNotes ink, drawing, sketch tools, clip insights, power policy, notes, PDF marks) | ✅ Done | 233 tests (run on Linux with Swift 6.3.1 at `/opt/swift` when installed; incl. Develop and trove-gen), plus an end-to-end test against `wrangler dev` |
| Crypto/sync compatibility Swift ⇄ Worker ⇄ extension ⇄ web app | ✅ Verified both directions | fixtures + scripts |
| Import (zip, folders, exports; app + website) | 🟡 Core + website tested (Swift + JS on one zip fixture, Chromium e2e); app builds on CI, not run on a device | 5 Swift + 1 JS test, UI e2e |
| `extensions/browser` (Chrome; Safari via app target) | ✅ Done | crypto test + real-Chromium e2e (save, offline queue) |
| `web/` web app (any browser, served by the relay): create vault, recovery, add devices, inbox import, folders, viewer, connections, select mode, sources, GoodNotes viewer, drawing, sketch tools, clip editor | ✅ Done | 28 unit/interop tests; 9 e2e (relay + real Chromium, incl. `draw.e2e.mjs`) passing locally. Deployed (version 3d43d4ca, at f01c8a3) |
| `App/` (macOS + iOS/iPadOS app, share ext, widgets, Safari ext) | 🟢 **Builds** on GitHub Actions (Xcode 26.3) for macOS (universal) and iOS (last: 7ba494d, the Open / file viewer round); not yet run on a device | CI: `.github/workflows/apps.yml`; downloads at the `latest` release |
| **Clipboard history** (Mac ⌥Space palette, iPhone/iPad screen + Trove keyboard, website view; synced clips, PROTOCOL.md §8): source app/page/window, insights, rule tags, AI names/summaries, OCR, editing, main search, auto-save | 🟡 Core + website tested; apps build on CI, not yet run on a device | 8 Swift + 3 JS unit tests, `clip-cases.json` (insights + rules), Chromium e2e |
| **Folders + auto-filing, file previews, versions, connections/graph** (PROTOCOL.md §9) | 🟡 Core + website tested; apps written, building on CI, not yet run on a device | 9 Swift + 7 JS unit tests on shared fixtures, Chromium e2e (`organize.e2e.mjs`) |
| **Notes: Today's note, templates, checklists** (PROTOCOL.md §12) | 🟡 Core + website tested; apps build on CI, not yet run on a device | 4 Swift + 3 JS unit tests on `notes-cases.json`, Chromium e2e (`notes.e2e.mjs`, desktop + phone width) |
| **PDFs like a PDF app** (find, text highlights, quotes, links, forms, export as annotations; PROTOCOL.md §10) | 🟡 Core + website tested; apps (PDFKit reader) build on CI, not yet run on a device | `pdf-cases.json` (Swift + JS), pdf.js export test, Chromium e2e (`pdf.e2e.mjs`) |
| **Drawing / Apple Pencil** (sketches and ink on PDFs/images, PROTOCOL.md §10): 6 pens, laser, 3 erasers, scribble to erase, lasso, shapes, text, pictures, 17 papers, page sizes, scroll/flip layouts, zoom 10–1000 %, Pencil squeeze palette, page panel, endless canvas, PDF export, handwriting search, editing (S3: lasso actions, shape tool, connectors, ruler/protractor, text on the page, elements library) | 🟡 Core + website tested; apps written (PencilKit pens + Trove tools on iPad/iPhone, all tools on Mac), build on CI, not yet run on a device | Swift + JS unit tests on `ink-cases.json`, `ink-geometry.json`, `ink-editing.json`; 3 Chromium e2e (incl. `editing.e2e.mjs`) |
| **GoodNotes notebooks with handwriting** (`docs/GOODNOTES.md`) | 🟡 Website checked against real notebooks and GoodNotes' PDF exports; apps building on CI | shared fixture `ink.goodnotes` (Swift + JS) |
| Relay + web app deployed to Cloudflare | ✅ **https://trove-relay.lancus.workers.dev** (version dfb1e28e, at 737aeb5, 2026-11-04: cache-weighted AI metering, website PDF selection fix) | web e2e, Chromium UI e2e and the Swift integration test all pass against production |

**Design mockups:** three directions (A Glass, B Editorial, C Midnight; Mac + iPhone each) in a
private artifact: https://claude.ai/artifact/A9P4DTybx1EaSzG3TcayJg. **Decided: A Glass** (MASTER_PLAN §13
decision 1, confirmed in "Decisions taken for you" 16); restyle after `docs/UI_AUDIT.md`. The web app currently uses a neutral style close to Midnight.

## The user's setup (important)
- **No Apple Silicon Mac.** The user's Mac is Intel, and current Xcode needs M1 or later. So:
  - **The apps are the product; the website is secondary** (the user: "the main thing of this is the
    app for mac and ios/ipados, the website is not primary and is there just cus we can have it").
    Apps first, Apple frameworks first; website only where cheap. The website
    (https://trove-relay.lancus.workers.dev) is still handy for creating the vault and adding devices.
  - **The Apple apps are built on GitHub Actions** (`.github/workflows/apps.yml`, Xcode 26.3 on `macos-15`; the repo is public, so it's free). Compile errors are fixed from cloud sessions:
    1. `git fetch origin ci-logs` then `git show origin/ci-logs:macos-errors.txt` (and `ios-errors.txt`, the full `*.log`, `RESULT`).
    2. Run status: `gh api repos/mrlancus/trove/actions/runs`.
    3. **Since 2026-11-04 the build and the app tests are separate workflows.** "Apple apps" (`apps.yml`) is the
       build (~9 min once it has a Mac) and publishes `latest`. "App tests" (`app-tests.yml`: Mac unit +
       iPhone/iPad UI, 30–45 min) starts when each build succeeds, so it runs for every build without delaying
       one; a newer build cancels older tests. It can be cancelled any time (the user may ask, e.g. after testing
       on their PC) and run by hand from Actions. Logs: `ci-logs-tests` branch.
  - **The user's Windows 11 PC: not used** (decided 2026-11-04: the sessions and GitHub already run TroveCore's
    tests, and the PC can't build the apps). Only if the user starts editing code themselves, WSL2 could run them:
    Swift 6.3.1 is ~1 GB to download, 3.3 GB unpacked; the repo ~0.2 GB; a build folder ~0.4 GB. To keep it on
    D: `wsl --install --no-distribution`, restart, then `wsl --install -d Ubuntu-24.04 --location D:\WSL\Ubuntu`
    (or move an existing one: `wsl --manage Ubuntu-24.04 --move D:\WSL\Ubuntu`).
  - **Installing:** the run's artifacts are `Trove-macOS` (universal, signed with Trove's self-signed certificate) and `Trove-iOS` (`Trove.ipa`, unsigned). The user installs the IPA with **Sideloadly** using their free Apple ID; that needs redoing every 7 days.
- **The relay is deployed** with `ALLOW_NEW_VAULTS=true`. The user needs that to create the vault on the website. **After they've made their vault, set it to `"false"` and redeploy.** The token for `wrangler deploy` is in the cloud environment (`CLOUDFLARE_API_TOKEN`).

## Latest round: practice in real sketches, a tutor, locked pictures, Home (2026-11-04, `docs/prompts/practice-space-home.md`)
Your words are saved in that prompt first. Also this round: **Sketch 2 was merged** (it had been left on
`claude/trove-research-improvements-dwcw63`; see "Round before: Sketch 2" below), plus one merge fix
(two `DiagnosticsSection`s: the Sketch 2 one is now Settings → Sketch frames).
- **Lock pictures** (every sketch): lasso-tap a picture, text box or tape → the lock button. Locked: the loop
  and Select All leave it out (so they pick the writing on it), it can't be moved, resized or deleted, and you
  write over it. Lasso-tap it (where there's no ink) to unlock. Synced (`locked`, PROTOCOL §10); the website
  respects it. `LockTests`, TEST-NB-011.
- **Practise in a real sketch**: each question opens a page or a whiteboard (⋯ to switch; remembered), with the
  question as a picture across the top (move it, or lock it). Kept in Sketches → Practice → course → topic and
  linked from the attempt (`work`, PROTOCOL §13), so you can go back. A bar on the sketch: the question, Tutor,
  Mark it (back to marking). `PracticeWork`, `PracticeWorkTests`, TEST-DEV-034.
- **Tutor**: Ask in a practice sketch is the tutor: it gets the question and the mark scheme before your
  handwriting, with Check my working, A hint, Where did I go wrong?, Explain the idea, Next step. Only when you
  tap (your choice). Hints and Mark with AI on the question screen read your handwriting too. TEST-DEV-035.
- **Your work**: Develop shows every attempt by course and topic, folded until opened, with average rings,
  trend, "try 1 of 2", open the working, Try again. Topic = the question's skill, else the paper without its
  series (every year of 7408/2 together). TEST-DEV-036.
- **Look**: Develop has an Up next card in Trove's colours, three numbers (this week, days in a row, recent
  average), and a redesigned practice screen (progress segments, question card, Work it out, result ring).
- **Home**: the app opens on Home (sidebar top; the iPhone's first tab): greeting, New note / New sketch /
  Practise / Import, three numbers, Develop's next step, Jump back in, Pinned. TEST-HOME-001.
- **Later the same night**: questions split v2 (only the question, cropped to its marks, with its stem and
  lead-in; "c)", "(i)", "Question 1"; older splits redone on launch; TEST-DEV-037); PDF/picture pages
  sharpen in tiles (`InkTiledPageLayer`); **crash on opening any sketch fixed** (the slim toolbar's SwiftUI
  type overflowed the stack; 0.1.169's report). Builds at 340eaf1. CLAUDE.md now has an app quality checklist.
- **Not done / next**: topics from the course's spec (on the device) instead of the paper; thumbnails of the
  working in Your work; the rest of the app on `Theme` (Library, Settings); a Lock button on the website.

## Round before: every exam board, courses, uploads from anywhere (2026-11-04)
User: "how can we add all the other exam boards" → A-level, GCSE and IGCSE, all subjects, Cambridge too; uploads
should sync per trove; "this is to test, not what I'm using".
- **Catalogue** (docs/CATALOGUE.md): `scripts/catalogue/` finders for AQA (its finder's search service), OCR
  (Assessment pages), Eduqas and WJEC (the Past papers tab feed), Cambridge (IGCSE and International AS & A Level
  past-paper pages: one recent series + specimens only). Output `catalogue/index.json` + `catalogue/specs/*.json`
  (replaces `papers.json`). Weekly rebuild + link sample in `.github/workflows/catalogue.yml`.
- **TroveCore**: `Catalogue` v2 (index + spec files, tiers, titles, option papers, `search`, `specs(level:)`,
  `downloadPlan(papers:)`), `ProblemLevel.igcse`, `Course` records, generic splitter (`numberParts` rewrite,
  3-level keys 1.2.1, stems, robust margin, `splitBest`). Tests: `CourseTests`, `GenericSplitTests`,
  `RealPaperSplitTests` (real papers via `split-sample.py`, never committed).
- **Apps**: Develop → Your courses (picker by level with search, subject badges, progress per course), a course
  screen (papers by series, tier filter, tap a paper to download it with its scheme, Download every paper,
  auto-split), Your own papers → Upload (Files, Photos, camera scan) saved as items in your trove.
- **Goals** (your feedback): New goal with your AI is a short chat (`GoalChat`: one question at a time with
  tappable answers, at most 6, never a guessed date) ending in a goal to confirm; without AI, a form. Goals
  carry courses, papers, target and a summary; they're editable and removable (synced). No fixed minutes a day:
  the card asks "How long have you got today?" and sizes today's questions; the latest answer is the usual for
  later days. Start practises from the goal's courses. New look: readiness ring, days left, chips.
- **Pearson Edexcel** (done 2026-11-04): `scripts/catalogue/pearson.py` reads the search behind Pearson's
  past-paper finder (key read from the page each run, never stored). 164 specs, ~17,900 files: GCSE, International
  GCSE, AS/A level, International AS & A Level; QP/MS/ER. Only public files (`/content/dam/pdf/`, 200); the newest
  series are under `/content/dam/secure/` and need a Pearson login (401), so they're left out. Legacy specs are
  dropped (no public paper since 2019, or replaced: 4CH0 → 4CH1, 1CP1 → 1CP2, IAL 2013 → 2018). Link check: 313
  sampled, 0 broken. Splitter changes for Pearson's layout (vertical edge labels ignored, footer page numbers
  aren't questions, "(Total for Question 3 is 1 mark)" for a part-less question): real papers split to their
  printed totals (9PH0/1 90, 9CH0/1 90, 4PH1/1P 110, WPH11 80, 1SC0/1BF 60; 1MA1/1F 78 of 80). Tests:
  `PearsonSplitTests`, `RealPaperSplitTests`. In build.py's FINDERS, so CI rebuilds it weekly.
- **Upload names and board websites** (2026-11-04, your ask; builds on GitHub Actions for macOS and iOS, run 41849975160, published as "latest"; not yet tried on a device): uploads open a "Name this
  paper" sheet. `PaperTitle` (TroveCore, tested) reads the first page, the PDF's title and the file name and
  suggests e.g. "CCEA GCSE Physics Unit 1 Foundation, June 2023"; on the iPad Apple Intelligence tidies it, but
  its version is used only if the board's name is unchanged (`keepsBoard`). Type over it; Use suggestion puts it
  back; Rename… on an upload. Catalogue papers keep the board's names. **Upload → From a board's website**
  (`BoardBrowser.swift`): CCEA and Pearson's newest papers in a web view on your own connection; Add to Trove on
  a PDF downloads it through the web view (so a Pearson login works) and names it the same way. Tests:
  TEST-DEV-029/030. Check on a device: does CCEA's site open from home (if it shows "Access Denied", it blocks
  people too)? CCEA's start page is its home page (its past-papers URL couldn't be checked from here).
- **Split into questions, explained** (2026-11-04): the course button downloads every paper, then splits each into
  its questions and parts with marks (so you practise one question at a time with its mark scheme). It looked
  dead because once everything was split it did nothing visible, and its message only showed on the Develop
  screen. Now it says what it'll do ("Split 3 papers into questions"), shows "Splitting…", reports on the course
  screen, and reads "Every paper is split" when there's nothing left. Board-paper sync: `Library+BoardPapers.swift`
  (test `aDownloadedBoardPaperSyncsLikeAnUpload`, TEST-DEV-031), `DevelopModel.syncPapers()`.
- **Goals take your own papers** (2026-11-04, your ask): Edit goal → Your own papers. Uploads whose name matches
  the goal (its course's board, level and subject; without a course, its name, e.g. "CCEA GCSE Physics" or "BPhO
  round 1") join automatically ("Matches this goal"); tick others, untick matches (`uploads` / `excludedUploads`
  on the campaign record, `GoalUploads`). Upload papers… and Add a PDF from your trove… are right there. "Change it
  by chatting with your AI" opens the goal chat on the current goal (it may change anything, uploads too; you
  still Save). A goal with no course and no uploads still practises from everything. Tests: `GoalUploadsTests`,
  TEST-DEV-032.
- **Fixes from your first try (2026-11-04):** Edit goal froze: it read every PDF's name for each row on each
  redraw (n² name reads); now names are read once per upload (`GoalUploads.Entry`, cached in DevelopModel) and
  matches are worked out when the courses/name/notes change (`manyUploadsMatchQuickly`). Goal chat "The answer
  was cut off": it asked for 800 tokens and thinking (on by default) counts against that. The reply itself is
  ~100–250 tokens, so thinking is now off for it where the model allows (`AIClient.canSkipThinking`: Haiku 5.5,
  Opus 5, Sonnet 5…; Opus 5.5 / Sonnet 5.5 reject it, so they think at low effort), with the plan budget (3,000)
  as the ceiling and one retry at double. **Your papers** screen (Develop → Your own papers → All your papers): search by any words of
  a name or goal, sort (newest, name, most questions), rename, split, open, delete (with a confirm), upload, and
  "Include every PDF in my trove". Uploads from Develop are marked `developUpload`. Test: TEST-DEV-033.
- **Not done / next**: CCEA papers come through the browser only; Pearson's newest series (login only); the look of the rest of the app; mark-scheme matching on non-AQA boards is
  best-effort (the scheme's page is always one tap away); Cambridge's older series aren't public.

## Round before: Develop, no lag, cheap AI and a full test plan (`docs/prompts/develop-perf-testing.md`, 2026-11-03)
The user: "follow it from the top … don't ask me for permission; log the decisions you take for me". On `main`
from b5c07b9 (saved as `archive/main-before-develop`). **Continue with "Next" below.**
- **Part 1 (done, stop point reached):** `docs/DEVELOP_PLAN.md`: what exists (every AI call site), the 12
  positions, architecture (PROTOCOL §13 draft), roadmap, UX wireframes, decisions (logged above). Doc fixes
  (ARCHITECTURE: SQLite local copy, record kinds, tool-based Ask; NOTES: relay model is Haiku). Found: the
  prompt's "no prompt caching anywhere" is wrong (Ask and the notebook chat cache; the relay and
  `AIProvider.complete` don't).
- **Part 2 step 0 (done):** `TroveGen` (seeded big vaults, Zipf text; `writeFolderVault`), benchmarks on the
  budget vault, app **Diagnostics** (hang watchdog, frames/hitches session, Screen signposts, time-to-content,
  Settings → Battery → Lag and frames → Export), **test targets** `TroveTests` (Mac) and `TroveUITests`
  (iPhone/iPad) run by job `app-tests` (`scripts/ci-app-tests.sh`; logs and screenshots on branch
  `ci-logs-tests`), debug-only `-TroveTestVault small|tiny|full`. `docs/PERF_AUDIT.md` is current.
- **Part 2 fixes (measured, Linux release, budget vault):** one notebook page's ink 113.0 → 0.5 ms (page
  index, B2); search p90 102 → 65 ms (B3, still over the 5 ms budget); the editor decodes strokes off the
  main thread (B4, implemented, needs device numbers); `inkByItem` kept strokes moved to other items (Swift
  and JS fixed).
- **Part 3 (stop point reached):** `docs/testing/` README, SMOKE (25 tests), critical/high tests for every
  existing area, RESULTS log. Develop's and the catalogue's tests filed with the code.
- **Develop's first slice (TroveCore, done):** `Develop/` records, `EdgeIndex`, `ConceptMatch`, `Mastery`,
  `Practice`, `Difficulty`, `DevelopAI.route`, `Catalogue`, `PaperSplitter`, `AnkiExport`;
  `catalogue/papers.json` (AQA 7408 2022–23, links checked live); JS `core/develop.js`; PROTOCOL §13;
  `Fixtures/mastery-cases.json`. 233 TroveCore tests, 73 web unit tests pass on Linux.
- **Then (user: "build the rest of everything that isn't done and test it all", 2026-11-04):**
  - **Develop in the apps** (built on CI, not yet on a device): Develop in the iPad/Mac sidebar, a Practise tab on
    iPhone; AQA papers downloaded on Wi-Fi into a local cache and split into questions (PDFKit text); practice one
    question at a time with the original page; **Show mark scheme** + ticks (no AI), **Mark with AI** on a tap
    (scheme quoted point by point, unsure marks to review, one medium re-check); the **Pencil answer pad** (default
    on iPad; marked from a picture only on a tap); the **hint ladder** (5 levels, cost credit); skills with mastery,
    a "why" sentence and calibration; **goals/campaigns** (diagnostic first, what slips, readiness sentence);
    **practise from your own PDFs**; **Anki .apkg** export; concepts on items with ✓/✕ (✕ sticks).
  - **Search** (B3): numbered docs + postings with frequencies + top-k (identical results, checked by
    `SearchEngineEquivalenceTests`): p90 65 → 28.1 ms on the budget vault; and in the apps search runs off the
    main thread, so typing is never blocked. 5 ms is still missed as a computation (PERF_AUDIT B3 options).
  - **Notebook** opens on its visible page first. **Relay** counts cached tokens at their price (not deployed).
  - **Website PDF bug fixed**: selecting text right after highlighting lost the selection (the cached viewer was
    moved during a redraw). `pdf.e2e.mjs` wasn't flaky; all 25 website e2e tests pass locally. Not deployed.
  - **UI audit** (`docs/UI_AUDIT.md`) from the first simulator screenshots: U1 Recent's empty message, U2 iPhone
    opens on Recent, U6 "Pick a result": fixed. `Theme.swift` tokens for direction A Glass.
  - **Tests**: TroveCore 241, web unit 73, web e2e 25/25, relay 59, extension 2 (Linux); Mac app tests 7/7 on CI;
    UI tests on 4 simulators: 16 pass at d1961da (Develop on three devices); iPad search typing and the launch
    metric fixed in the tests at 234a0e7 (check that run's `ci-logs-tests`); the iPad mini simulator itself
    failed to launch/stop the app. All logged in `docs/testing/RESULTS.md`.
- **Known bugs:** search over budget as a computation (B3).
- **Not done (next sessions):** other boards in the catalogue (each needs a verified list of links on the
  board's own site; Pearson's didn't answer by pattern), Develop's timed whole-paper mock, scanned papers
  (Vision text for splitting), Anki review-log import, moving the rest of the views onto `Theme` tokens,
  the iPhone top bar (U4), checking iPhone landscape (U7), search's remaining 5 ms (MaxScore bound).
- **Deployed** 2026-11-04 (version dfb1e28e): the relay metering change and the website PDF fix.

## Round before: Sketch 2 (2026-11-03, merged into main 2026-11-04) (user: "everything is so cluttered in the top … the zoom pill hidden … set a new 100% … NEVER see lag … AI writing light blue, looks like handwriting, rub it out normally … Ask box you can move and resize … the AI can't see handwriting … a live outline where the AI is looking … select an area and size for what it makes … handwriting with my pens and colours … new sketch asks for page settings": built on branch `claude/trove-research-improvements-dwcw63` and left unmerged by mistake; replayed onto main 2026-11-04)

Plan: `docs/plans/sketch-2-plan.md` (brief `sketch-2-prompt.md`, review `sketch-2-review.md`). Built:
- **Lag (S1–S3).**
  - **Measuring it:** Settings → Sketch frames shows slow frames for the last pan and pinch. It can also make a 30-page stress-test notebook (`InkStress`).
  - **iPad:** paper, PDF and picture pages, pictures, text and tape are GPU layers inside a host scaled by the zoom (`PageLayers.swift`), so nothing is repainted while you move. PDF detail renders *during* a pinch at 2×.
  - **Ink:** drawn by Trove's own Metal renderer (`InkMetalView.swift`, `InkTessellator` in TroveCore) at the exact zoom every frame. PencilKit keeps only the live stroke and hands it over in the same frame. Highlighters sit under the ink.
  - **Fallback:** Settings → Sketch → "Sharp ink at every zoom (GPU)" off, or the editor's More → Classic ink.
  - **Mac:** the ink cache survives panning. Metal on the Mac is still to do.
- **Toolbar (T1–T5).**
  - One slim bar: Done + title menu (page settings, pages, dark page, present, export) · Pens (the six pen types are in its tray) · highlighter, eraser, lasso, shapes, text · Insert (+) · the tool's colours and sizes inline · undo/redo, Ask, More (⋯).
  - Nothing scrolls. When narrow, sizes fold away first, then colours, then Insert and shapes/text move into More.
  - Tap the chosen tool again for its tray.
  - The zoom pill sits inside the safe area. "Make this zoom my 100%" and "Reset 100% to the original" are in its menu. ⌘0, ⌘+ and ⌘- work.
- **AI.**
  - The chat now reads handwriting from what this device holds (the synced signature made it skip). It refreshes before every question and reads ink on PDFs and pictures, plus PDF page text per page.
  - Handwriting synthesis (`InkHandwriting`, EMS Tech / EMS Allure single-line fonts, OFL, `scripts/glyphs.py`) is sized like the writing around it.
  - **Math Assist** writes light-blue handwriting strokes (`by: assist`). You can rub them out. It won't re-answer over your edits, and its answer goes when you undo the `=`.
  - **Ask** floats: drag it, resize it from any edge or corner, fold it, or tuck it into a bubble. It fades for a hovering Pencil. On iPhone it's a sheet.
  - A dashed "AI is looking here" outline shows while it reads and thinks.
  - **Placing output:** Diagram → "Place on the page…", or an answer → "Write on the page…". Drag a box or tap, see it faintly in your pen and handwriting, drag again to move or resize, then Keep (one undo, grouped, `by: ai`) or Tweak a diagram.
  - **Page pictures:** Ask may send them for pages that are mostly drawing, after asking (allow, this session, always, not now; Settings → Sketch).
- **New sketch (T6)** asks first: name, notebook or whiteboard, paper, size, orientation, colour. It starts at your last choice. "Ask every time" can be turned off.

**Try on the iPad** (nothing here has run on a device yet):
1. Settings → Sketch frames → make the test notebook; pan and pinch it, then read the slow-frame count.
2. Pinch ink, a PDF and a picture: do they stay sharp?
3. Write `12×4=`: a blue handwritten 48? Rub half of it out.
4. Ask about a handwritten page.
5. Move and resize the Ask box.
6. Make a diagram and place it.
7. The toolbar in Split View.
8. New sketch.

If the GPU ink looks wrong, turn it off in Settings → Sketch and say what you saw.

## Round before: the master plan, round 1 (user: "do everything!"; GoodNotes first; merged to main at 98a39e8, relay deployed as feab0b38)
Plan: `docs/MASTER_PLAN.md` (decisions §13, order §14). Built on CI from the branch with
`workflow_dispatch` (branch builds never publish the `latest` release). Not yet run on a device.
- **Speed and battery** (P1, P6, P8, P9): TroveCore has a **change feed** (`RecordStore.changes(since:)`,
  `SyncEngine.changes`, `Library.itemChanges`): the search index and the item list update only the
  records that changed instead of walking the library. Mac clipboard checks adapt (0.3 s while you use
  the Mac, 1 s, 2 s when idle, 25 % timer tolerance) and stop while the screen sleeps; sync, the live
  socket and clipboard pause on sleep and resume with one sync on wake; the live socket pings every
  50 s (was 25 s); while live, polling is a 5–10 min safety net; Spotlight remembers what it indexed
  (`spotlight-indexed.plist` in Caches) so launches don't re-index everything, and drops items deleted
  elsewhere; open items found by id, not by scanning. **CI: built OK** (20c8b56).
- **Math Assist** (G7, N10): `TroveCore/Math` (parser and solver: arithmetic, powers, roots, %, trig in
  degrees, variables down the page, linear equations, checks with ✓/✗, worked steps), `EqualsDetector`
  (spots `=` from two strokes' shapes, no model), `MathLine` (only the line left of the `=`),
  `MathCandidates` (top-10 guesses × look-alike swaps, the one that's valid maths wins; unsure → "?"),
  `MathCache` (one recognition per line). App: `MathAssistController` (after 0.4 s of pen rest, Vision on
  a ~48 px crop of the line, answer as a text box; on request only in Low Power Mode/hot), sketch
  Settings menu → Math Assist, lasso → Solve. Test `testAnHourOfMathsReadsEachLineOnce`.
- **Appearance** (D1b): Settings → Appearance: Style Automatic / Liquid Glass / Standard, Theme,
  Cards. `.troveAppearance()` on every window; `Glass` draws solid panels in Standard.
- **Ask this notebook** (G14): `StudyChat.swift` (`AIRules` grounded/no yes-man/concise, also used by
  Ask; `StudyContext` handles `[p3.4]`; big notebooks trimmed to relevant pages with a note;
  `studyReply` caches the notebook; `StudyMemory` Markdown summaries in Application Support/Trove/
  sessions; `DiagramSpec` parse, layout, tweak). App: Ask button in the sketch editor → side panel
  (`StudyPanel.swift`): chat, shortcuts, temporary chat, cost, "Show N places" highlights (Vision now
  stores each line's box in `HandwritingPages`), diagram preview Keep / Remove / Tweak.
- **Export to GoodNotes** (G13): `GoodNotesWriter` (round trip: original zip, GoodNotes' own ink and
  text marked erased, Trove's appended, outlines that own fills kept; fresh notebooks/whiteboards;
  `ZipWriter`). Editor → Export → GoodNotes notebook. **Unverified with real GoodNotes**: ask the user to
  import a few exports on the iPad and to send a blank notebook + whiteboard exported from GoodNotes.
- **Notebooks** (G1, G2, G5, G10): covers (item menu → Cover; `cover` field), page names + Outline in
  the pages panel (`pageList[].name`, kept by the website), Add/Remove space here, Present (no tools,
  laser).
- **Study** (G8): `Study.swift` FSRS-5 (card records `card.<note>.<sha12(front)>`, PROTOCOL.md §12
  "Study"), queue with 20 new cards a day; `StudyView` (item menu → Study these cards, ⇧⌘Y).
- **Sync** (P10, P11): relay `POST segments/batch` (one request for up to 200 segments; **needs a relay
  deploy**, older relays fall back), the engine fetches wanted segments together and applies them in
  one go; iCloud folder listings reused while a device folder's modification date is unchanged.
- **Cards** (P7): card pictures cached on disk as small JPEGs (`Caches/thumbs`).
- **Notes editor** (N1): `LiveMarkdownEditor` (TextKit 2 `UITextView`/`NSTextView`, styles from
  TroveCore `MarkdownSyntax`, only the edited paragraph restyled; tap checkboxes, Return continues lists,
  `[[` suggestions, Writing Tools) replaces the plain editor in the item view. **Check on device**: typing
  feel, undo, the suggestion bar, checkbox taps.
- **Open Quickly** (O1, ⌘O, `FuzzyMatch`), **Recently Deleted** (N11, 30 days, Restore; File menu and
  Settings → Vault), **clipboard pause** (C5) and **palette hidden from screen sharing** (C6), **controls**
  for Today's Note and Study (X1) and App Shortcuts (X3), **handwriting search jumps to the line** (G6).
- **Audio synced to ink** (G4): Record in the sketch toolbar (AAC 32 kbps), `recordings` field
  (PROTOCOL.md §10), Recordings menu plays back with the strokes written at that moment marked, lasso →
  Play from here, transcripts on the device (searchable). **Check on the iPad**: microphone prompt,
  marks following the audio.
- **More**: planners (G3, Add → New planner), maths in notes (N10, Return after `=`), slash menu (N3),
  reminders (N8, item menu → Remind me), plain export (I5, Select → Export as Markdown and files), Link it
  on mentions (O4), command palette (O2, ⌘K), sorting (N12), app lock (S3 first part, Settings →
  Privacy), predicted next paste (C3). The website's sync also uses `segments/batch`.
- **Next** (§14): check CI for the later commits; then G9 zoom window, G11 whiteboard quadtree, G3
  planners, GoodNotes library import with folders, G6 word recognition, G4 audio synced to ink, G8 study;
  P10 batched segment fetch (relay + clients), P11 iCloud NSMetadataQuery, P4 binary search index, P7
  thumbnails, P15 launch; then N1 editor.

## Round before: Ask that reads whiteboards, searches the clipboard and spends less (user: "AI activity bugs out and you can't go back", "model selection not centred, show relative cost and proper names", "whiteboards too low resolution", "make it more concise, read fewer pages, only specific sections", "a keyword summary of each note", "tailored to the app", "let it access clipboard history, VERY well optimised")
Not yet run on a device.
- **Activity and costs** (Mac): the Settings window has no back button, so the page pushed into it
  was a dead end, and it laid out up to 400 rows at once. It now opens in its own window
  (`Window "ai-activity"`) as a lazy `List`, with every total worked out once per change.
- **Model picker** (Ask): a capsule the same height as the send button (the `Menu` drew its own
  bezel, off-centre) opening a panel: Fast/Smarter/Best, each model's proper name
  (`AIModelName.pretty`: "Claude Sonnet 5.5", "GPT-5 Mini", "Gemini 2.5 Flash") and what a question
  costs next to Fast (`AIPrices.relativeLabel`, list prices weighted 4:1 input to output: Sonnet
  5.5 20×, Opus 5.5 40× Haiku). Settings shows the same beside each model. Ask is tinted Trove's
  orange (Chats was the system accent).
- **Legible pages** (`Handwriting.pageImages`): pictures are sized by the page, up to 2 px a point
  and 1568 px. A page bigger than ~1568 points (whiteboards, endless sketches) comes whole with a
  lettered grid (squares ≤1400 points, at most 6×6) and the note "ask for a section like B2"; `view`
  with `section` draws that square sharp (the page drawn at most ~40 MP, then cropped).
- **Spending less**: Settings → AI → Answers (Concise / Balanced / Detailed) and Pictures of pages
  per question (default 6, 0 = none; `AskTools.Budget` refuses more and tells the model to answer
  from what it has). Items and clips are named by 8-character handles instead of 36-character ids;
  lines are `handle | title | kind | date | folder | snippet`.
- **Keywords**: the index gives each item the words that say what it's about, worked out on the
  device (`KeywordCache`, no AI, no cost, cached until the item changes): its most distinctive words
  (frequent in it, rare in the library, not in its title) until they carry 60 % of what sets it
  apart, 3 to 15. Made with the search index's own `Tokenizer.terms` (folding, stemming), so every
  keyword is a word `search` finds the item by; the tool descriptions say so.
- **Keywords from your AI** (Settings → AI, `AIKeywording`, user asked for it, "fairly cheap even with
  100,000 items"): Improve keywords shows how many items need them and the estimated cost first,
  then progress, cost so far and Stop. Each item goes as a brief (title | its on-device keywords |
  first 300 characters, ~120 tokens), 20 to a request, numbered not by id; empty items are marked
  done unsent; an item is redone only when its title or start changes. It runs at low effort (at
  medium Haiku thought ~100 tokens per item, most of the cost): about $0.04 per 1,000 items, ~$4 for 100,000
  (estimates are priced per request, so Haiku's long-prompt price never applies). The token limit
  leaves room for that thinking (at 40 items with ~3,900 tokens every answer was cut off), and a
  request that's still cut off is split in two and retried instead of stopping the run. Saved as `aiKeywords` (searchable, shown in Ask's index). "Keep keywords up to
  date" does new and changed items (this week) in the background, one request a round, inside the
  monthly limit (keywords count as background spending).
- **Clipboard**: a `clipboard` tool (words, kind, dates; `c:` handles; one line per clip, 90
  characters) and `read` on a clip for all of it. Never clips that look like passwords, keys or
  codes (`SensitiveDetector`). Settings → AI → "Ask can search my clipboard history" (on).
- **Prompt** written for Trove: what's in it (Apple Notes, GoodNotes, screenshots, handwriting read
  with mistakes, folders, tags, clipboard), and how to look things up cheaply.
- **Check:** open Activity and costs from Settings and close it; ask about a big whiteboard and watch
  for "Looked at square B2"; set Concise and Pictures 2; ask "what link did I copy about …".

## Round before: Trove's look for Ask, the box, AI access, and smoothness (user: "make everything properly centred", "colours should fit the app, no AI logo", "laggy", "screenshots aren't saved to clipboard", "AI can't read GoodNotes whiteboards", "option to disable AI access per note", "buttons greyed out", "Apple Notes in the import area with the box opening", "menu bar icon is a generic box", "total cost lower than the console", "medium effort for Haiku", "Settings buttons move around", "scan all past handwriting with progress and stop, and a live toggle")
Not yet run on a device.
- **Dates**: an imported file now keeps the date it was made (older of creation and last change),
  so asking about a past day finds it. Items imported before this carry their import day (the AI is
  told so). Re-importing doesn't move existing ones.
- **Ask** (`AskView`): no orb or sparkles. Trove's box (`TroveMark`) whose lid lifts as you type;
  while it works the lid is open and what it searches or opens rises out of it. Trove's orange
  (`Brand`, from the icon) for the send button, question bubbles and chips; a faint warm light at the
  top; composer items all 34 pt so a one-line question is centred. Nothing animates on its own
  (the 30 fps orb and shimmer were costly); answers' Markdown is parsed once.
- **What the AI can see** (`aiHidden`, PROTOCOL.md §8): an eye on every item (beside the folder line,
  and Hide from AI / Let AI see this in its menu), and Settings → AI → What your AI can see: Allow
  everything / Hide everything. Default: everything visible. Hidden items don't exist for Ask's tools
  and are read with Vision on the device instead.
- **Ask's tools** (`AskTools`): `index` (every title, ~15 tokens each, 300 a page) so it knows what
  exists, and `view`: pages of a GoodNotes notebook or whiteboard, sketch, PDF or picture sent as
  JPEGs 1280 px on the long side (~1,500 tokens a page; a PDF page would cost its picture and its
  text), at most 4 at a time, only when `read` found little text. Drawn by `Handwriting.pageImages`.
- **Reading handwriting**: "Read new handwriting as it arrives" (live) now takes only what's added
  or written on since it was turned on (`live.since`); everything older waits for **Read all past
  handwriting** (Settings → AI), which shows a progress bar, pages and cost so far, and Stop.
- **Effort** (the user's choice, after asking whether it matters): low for reading handwriting and
  keywords (simple jobs where thinking is most of the cost), medium for Ask (it plans several steps).
  It was briefly medium everywhere for Haiku.
- **Costs lower than the console**: prices were right (cache reads on Opus 5.5 and Fable 5.1 are
  now priced lower, as they are). Likely gaps: spending before metering began, devices still on an
  older Trove, other apps on the same key, and requests given up after 2 minutes (still billed): the
  timeout is now 10 minutes. Activity and costs says when counting began and that the console counts
  UTC days.
- **Import**: the box opens, each thing that arrives drops into it, a progress bar runs under it, and
  the lid shuts with a burst when it's done. **Apple Notes** has its own card there (Import from
  Apple Notes, plus "Keep checking for new notes"); Settings' Import now uses it too.
- **Menu bar** (Mac): Trove's box as a template image (`TroveMark.menuBarImage`), not
  `shippingbox`. Onboarding shows it too.
- **Greyed-out buttons** (Mac): AppKit draws an inactive window's toolbar greyed; after a sheet, the
  Settings window or a sketch or file window closed, the library window was sometimes left in front
  but not key. `WindowFocus` makes the frontmost Trove window key again after any of those (not after
  the clipboard palette, which hands the keyboard back to the app you paste into).
- **Settings rows that moved**: the "Organising…" row came and went with background work (now always
  there); buttons that turned into spinners shrank (`BusyLabel` keeps their size); Copy/Copied, Check
  Now, Import now and Restart keep their place while their text changes.
- **Lag**: `reload()` worked out the link graph and the sidebar counts on the main thread every time
  anything changed (enrichment and handwriting reading change things often): now off it.
  Connections on an item (Mentioned in, Maybe related) read every other item's text on every redraw:
  now in the background when the item or library changes. Untitled notes split their whole text to
  find the first line for the title: now just the first line.
- **Screenshots to clipboard**: the code path looks right and I couldn't find the fault without a
  device. Settings → Screenshots now says what happened to the last one ("went to Notes and
  Clipboard", or the exact error), and only screenshots taken after it's ticked come in.
- **Check:** Ask anything and watch the box; Import from Apple Notes; take a screenshot with
  Clipboard ticked and read the line under the grid; Read all past handwriting then Stop; close a
  sheet and see that the toolbar stays dark.

## Round before: AI costs and activity, Ask over everything, and fixes (user: "it used 7p on a couple of simple questions", "it can only see 12 files", "show how many tokens and the cost", "view all conversations", "see exactly what AI is doing in the background", plus screenshots per device, password options, Apple Notes, Accessibility, relay conflict, greyed Settings button)
Not yet built on CI when written; not yet run on a device.
- **Where the money went:** almost certainly the background reading of handwriting (every sketch
  page, GoodNotes page, inked or scanned PDF and photo, each a ~1,600-token image, read at medium
  effort with its thinking billed as output), not the questions. Now: pages are read at **low
  effort**; background reading has a **monthly limit** (Settings → AI, default **$1**, 0 = none,
  across every device; at the limit Vision takes over until next month).
- **Every request is metered** (`AIUsage`, `aiusage.<device>.<day>` records, PROTOCOL.md §8): tokens
  in/out/cached, cost from Claude's list prices (Haiku 5.5 $0.10/$0.50 per M; Sonnet 5.5 $2/$10;
  Opus 5.5 $4/$20; other providers only when they report a cost), purpose (Ask, Reading handwriting,
  Note actions, Test) and what it was about. **Settings → AI → Activity and costs** lists every
  request from every device, with totals per period and per kind of work.
- **Ask** (`Views/AskView.swift`): a centred chat with a glowing orb, each step shown live ("Searched
  “icarus”: 3 found", "Opened “Icarus costume”") with the running tokens and cost, follow-up
  questions, saved chats (**Chats** button; `aiChat` records, synced), Fast/Smarter/Best menu, and a
  usage pill (tap: this session → today → this week → this month). It now answers with **tools over
  the whole library** (`AskTools`: overview, search with filters, browse, read up to 6 items) instead
  of being handed the top 12 hits, so it can reach any item but only opens what it needs (Claude
  tool use with prompt caching; OpenAI-style function calling for the others).
- **Sync conflict** ("relay push …: conflict … a different segment with this start already exists"):
  an upload that went through before the device recorded it was sealed again with new bytes and
  refused for ever. The relay's 409 now includes `last`; the apps and the website count those ops
  as sent and upload the rest. Relay and website redeployed (version b7255461).
- **Apple Notes** ("Couldn't read what Apple Notes sent back"): osascript wrote non-UTF-8 for an app
  opened from Finder, so accents and emoji broke the JSON. The script now returns ASCII-only JSON,
  osascript runs with a UTF-8 locale, a bad note is skipped, and the message says what came back.
- **Apple Notes, second fix** ("Apple Notes sent nothing back"): the Mac app had no
  `com.apple.security.automation.apple-events` entitlement, which the hardened runtime needs to
  control other apps (osascript's Apple Events count as Trove's); macOS refused them without asking.
  Added (project.yml), and the script now writes the notes to a UTF-8 temp file instead of printing
  them. Built at cb20097. **Check:** after updating, Import now should bring up macOS's "Trove wants
  to control Notes" prompt.
- **Accessibility** still saying not allowed: macOS often tells an app only after it restarts.
  Settings → Clipboard has **Restart Trove**, also accepts the event-posting permission, and warns
  when Trove runs from Downloads (App Translocation), where the permission never reaches it.
- **Settings button greyed out** (Mac): `SettingsLink` in the toolbar; now a plain button with
  `openSettings`.
- **Screenshots per device** (Settings → Integrations → Screenshots; `settings.screenshots`): each
  device's row has Notes (library) and Clipboard (clipboard history) checkboxes, settable from any
  device; each device imports its own. The old switch becomes this device's Notes.
- **Passwords and codes** (Settings → Clipboard): Don't keep them / Keep for 2 minutes, this device
  only (as before) / Keep like any other copy (`saveSensitive`, shared).
- **Check:** Ask "what's in my Handwritten folder?" and watch the steps and cost; open Activity and
  costs; Apple Notes → Import now; Restart Trove after allowing Accessibility; take a screenshot
  with Clipboard ticked for that device.

## Round before: Open replaces Quick Look and Draw on it (user: "replace Quick Look with Open … view-only by default, Edit turns editing on … Print … one button")
Builds on CI (7ba494d); not yet run on a device.
- **Open** (`FileViewer`, `Views/FileViewer.swift`): a file's row in the item view now shows only
  its name, size, **Open** and **New version** (in "⋯" when there's no room), on one line. Draw on
  it and Quick Look are gone from the row. Open shows the file full screen on iPhone/iPad (a cover)
  and in its own window on the Mac (`WindowGroup` id `file`, `FileTarget`). Tapping the inline
  preview (a PDF page away from highlights, links and fields; a picture; an inked file's page)
  opens it too, as do the item's toolbar (Open replaces Draw for files), its menu (Open, Print)
  and `model.draw(on:)`, which now opens files in the viewer.
- **View-only by default**: PDFs in `PDFReaderView(fullScreen:editable: false)`: scroll, zoom, find,
  select and copy; the form's fields are read-only and the selection bar offers only Copy. Pictures
  and GoodNotes notebooks are drawn with their ink as vector PDF pages in PDFKit's view (zoom).
  Other types: the inline preview with a Quick Look button (Quick Look stays as the fallback).
- **Edit** (⌘E) tints the bar and shows an "Editing" label; **Done** goes back to view-only, with
  everything saved. PDFs: **Pen** (the ink editor on the file, `InkEditorView(embedded: true)`:
  no Done of its own, saves when it closes) or **Highlight & fill**. Pictures and notebooks: the pen.
  **Markup** (iPhone/iPad, PDFs and pictures that are the item's main file) opens Quick Look's
  editor on a copy; the result is saved as a new version, the original kept under Versions.
- **Print** (viewer toolbar and the item's menu): PDFs "with my ink and highlights" (the
  export-with-annotations code) or "the original"; pictures and other printable files as they are.
  `UIPrintInteractionController` on iPhone/iPad, PDFKit's print operation on the Mac.
- **Check**: open a PDF (nothing changes on a tap or in the form), Edit → Pen → draw → Done, then
  print with and without ink; Markup a picture and find the original under Versions.

## Round before: your own AI, Apple Notes on any Mac, and sketching feedback (user: "laser should glow, line or dot; the second bar moves the sketch; snap inside the ruler/protractor; tape with a finger; two-row lasso menu; zoom pill in the corner; dragging things shouldn't pan; eraser and tape; the top bar's ends fixed; shapes should prioritise corners and regular shapes")
Builds on CI (e0d46ae; the shapes commit after it changes only TroveCore, the website and docs); not yet run on a device.
- **Apple Notes import** used to run only on the Mac that made the vault (`mirrorOwner`); this vault
  was made on the website, so it never ran. Now any Mac imports after each sync (at most every
  5 minutes, `AppModel.importAppleNotes(force:)`), reading notes in bulk with JavaScript for
  Automation through `osascript` off the main thread. Errors, results and **Import now** are in
  Settings → Integrations. **Check:** the first run asks for permission (System Settings → Privacy &
  Security → Automation → Trove → Notes).
- **Your own AI** (`settings.ai`, PROTOCOL.md §8, synced end-to-end encrypted): Settings → AI → Your
  AI: provider (Claude, OpenAI, Gemini, OpenRouter, any OpenAI-style URL), key, a model per tier
  (Fast/Smarter/Best, with Load models), Test, and "Read handwriting". Ask uses your AI first, then
  Apple Intelligence, then the relay, with a Fast/Smarter/Best picker and the answering model shown.
  Handwriting (sketch pages, GoodNotes notebooks, scanned or inked PDFs, photos; not screenshots) is
  read by your AI as soon as it arrives (not waiting for the charger), up to 10 items a round,
  falling back to Vision; a failure pauses AI reading for 15 minutes. **Check:** paste a key, Test,
  then Ask with each tier; draw a page and search for a word written on it.
- **Laser**: drawn like light (a faint wide haze, a soft coloured glow and a white-hot core along a
  smoothed line, with a round glow at the tip); the options row picks **Line** (fades over 1.1 s) or
  **Dot** (only a glowing dot where the pen is, fading in 0.35 s). Per device.
- **Options row** lies over the top of the canvas: showing or hiding it (tap the chosen tool again)
  no longer resizes the canvas, so the sketch doesn't move.
- **Ruler and protractor** are Trove's own on the iPad too (PencilKit's only followed a line
  started at its edge). The Pencil put down anywhere on the ruler draws along its nearer edge, live;
  inside the protractor, along its arc. Knobs turn them; a finger moves them (on the Mac, ⌥-drag,
  or any tool that isn't a pen).
- **Tape** opens or covers with a **finger** tap (the Pencil no longer does it; a Pencil tap on tape
  leaves nothing). On the iPhone with the lasso, a finger tap still picks the tape. The Mac clicks.
- **Lasso menu**: two compact rows (count, turn, flip, front/back, straighten, group, duplicate,
  deselect; then Copy, Image, Text, AI, Save, Cut, delete), above the zoom pill.
- **Zoom pill** sits in the real bottom-left corner.
- **A finger on the selection** (box, corners, knob, handles) or on a guide moves it instead of
  scrolling; anywhere else, ink included, a finger still scrolls (iPad with "Only draw with Apple
  Pencil"; on the iPhone a finger already works the tools).
- **Eraser** rubs out tape too (undone with the ink); **Protect tape** in its options keeps it (off by default).
- **Top bar**: undo/redo on the left and page, pages, settings, dark page, export and Done on the
  right stay put; only the tools between them scroll.
- **Shapes** (TroveCore `InkShapes` and ink.js, same fixture): corners first, so a loop whose
  corners are all sharp becomes a polygon even when an ellipse fits (bowed or wobbly sides, rounded
  corners); then the standard shape when near: square, rectangle level or upright, equilateral,
  isosceles or right-angled triangle, regular pentagon/hexagon standing level, circle; straight
  lines and polyline pieces within 8° of level or upright made exact. The loop is cut where it comes
  back to its start (an overshoot used to add a corner). In 300 random wobbly drawings each, circles,
  ellipses, squares, triangles, pentagons and hexagons all come out right; squares with sides bowed
  12 % are squares now (were circles). **Check:** draw a square, triangle and circle quickly with
  Shapes on, and hold the pen at the end of one.

## Round before: sharp at every zoom (user: "lots of stuff is very low quality, especially GoodNotes whiteboards; should be vectors at max quality, without using much power")
Builds on CI; not yet run on a device.
- **Why it was blurry**: file pages (GoodNotes whiteboards, PDFs, pictures) were drawn once as one
  picture at most 2400 px wide (4096 on the Mac, which did the same for paper pages too); a GoodNotes
  whiteboard thousands of points wide got well under a pixel per point. Sketch previews in the item
  view were 480 px whatever their size.
- **Now** (`InkBackdrop`, iPad/iPhone and Mac): the whole-page picture stays for overviews and while
  pinching, and ~0.16 s after a pinch or scroll settles what's on screen (plus 15 %) is drawn again
  from the vectors at the screen's real resolution, kept until the view moves past it or zooms in
  further. Power: one render per settle, nothing per frame. Ink was already vector (PencilKit on
  iPad, a screen-resolution cache on the Mac); GoodNotes' editable handwriting is ink.
- **GoodNotes notebooks in the item view and the reader** draw from their vectors in 512 px tiles
  (`InkTiledPage`, Core Animation's tiled layer): only tiles on screen, off the main thread, kept
  until the size changes. The reader's pinch scales what's drawn and redraws once at the end
  (it used to redraw the whole page, capped at 58 M pixels, on every frame).
- **Previews** (sketch pages and inked PDFs in the item view) are drawn as wide as they show at the
  screen's scale (in 160 px steps, up to 4096); card thumbnails are 800 px (were 480).
- **Check**: open a GoodNotes whiteboard, zoom right in on its background; it should sharpen a
  moment after you stop.

## Round before: sketching feedback (blank grey sketches, squeeze palette that turns, preset sizes and colours, tape, laser)
Builds on CI; not yet run on a device.
- **Sketches all grey, bits showing only when zoomed far out**: the real cause. PencilKit's canvas
  was made opaque grey (for the shade round the pages), so it painted its tiles grey over the paper
  underneath; while zoomed far out the tiles came late and the page flashed through. The canvas is
  clear again and the grey is the paper view's background (`PencilCanvas.makeUIView`). **Check:**
  open several sketches; pages and ink show at once.
- **Squeeze palette**: every tool on the outer arc and all the tool's preset colours on a smaller
  inner arc (clear of the undo row); drag along either arc to turn it (`InkArcDial`, snaps to an
  item, fades at the ends, opens turned to what's chosen). The tools' arc kept its size.
- **Preset sizes** (three per tool, every device, `settings.ink` `sizes.<tool>`): tap one to use it;
  tap it again (or hold any) for a bar in steps of 0.05 mm (1 pt = 25.4/72 mm; text in pt), with
  − / + for single steps, then **Set**. The options row shows the size in mm.
- **Preset colours** (per group: pens/text/shapes/laser, highlighter, tape; `colors.<group>`): tap
  the colour in use again (or hold any) to change or delete it; **+** opens a picker (a grid of
  colours, any colour from the system picker, or a hex code) and adds it. Your older "your colours"
  start in the pens' row; recent colours no longer crowd the row.
- **Options row**: every tool's name is the same width, then a divider, so the options always start
  in one place.
- **Tape like GoodNotes**: laid along the pen's line and turned with it (level or upright within 3°),
  as wide as the tape's size (preset sizes too), torn ends; a tap makes it see-through (30 %), the
  next tap covers again (this device only, as before). The website draws turned tape already.
- **Laser** glows: wide soft halo, brighter band, white-hot core (`InkRenderer.drawLaser`).
- **Ask the user**: how the turning arcs feel with the Pencil; whether tape should also follow a
  curved line (it's straight, like GoodNotes').

## Round before: iPad feedback (sync 413, duplicate screenshots, share sheet, ⌘C, blank sketch at 10 %, Pen options, squeeze palette)
Builds on CI; not yet run on a device.
- **"relay push …: http(413, segment too large)"**: a real sync bug. After a restart the app rebuilt
  each unpushed segment from its first op through *every* later op, so one grew past the relay's
  1 MiB limit and was refused on every sync (those edits never went out). Now each runs to the next
  unpushed segment and at most 512 KiB (`SyncEngine.rebuildOutbox`, `OutboxTests` reproduces it).
  **Check:** the cloud icon's error goes away after updating and opening Trove once.
- **Duplicate screenshots** (iPhone and iPad both imported each one via iCloud Photos): the id comes
  from when it was taken and its bytes (`Library.addScreenshot`), so the second device finds it there;
  copies already saved twice with the same time and the very same file are removed once per launch
  (`removeDuplicateScreenshots`). Same picture at another time, or another at the same time, stays.
- **Screenshots straight into Trove**: Mac (new: Settings → Other apps → Import new screenshots) via
  Spotlight's live query for screen captures, within seconds, stored as JPEG; iPhone/iPad as soon as
  Photos has it while Trove is open, else when Trove comes to the front (iOS can't watch Photos in
  the background). Each import syncs at once. Screenshots only.
- **Share sheet "can't reach Trove's shared storage"**: the install lost its App Group (Sideloadly).
  Code can't restore it, so now: Trove → Settings → About → **Copy share sheet code**, then in the
  share sheet tap **Paste code** once; saves go straight to the relay inbox from then on (needs the
  relay). The code holds the public key, relay address and inbox token only.
- **⌘C copies the selected item** (picture as picture, link, note text, file; several picked items
  together): Mac when no text field has the keyboard; iPad/iPhone with a keyboard. Also "Copy" in
  every item's menu.
- **Sketch opens at 10 % showing nothing until a pinch**: the fit now waits for a real size (280 pt),
  fits again when the height settles (unless zoomed by hand), and nudges the zoom after fitting so
  PencilKit and the paper draw. That wasn't the cause (see the latest round: the canvas was opaque).
- **Pen options** popover sized to show everything; **the options row** is one height for every tool.
- **Squeeze palette**: curved round the Pencil's tip (tools outer arc, colours inner arc, undo /
  sizes / redo in the middle); picking keeps it open; squeeze again or tap elsewhere closes it.
  **Ask the user** how it feels and what to add (favourites?).

## Round before: notes (daily note, templates, checklists) and PDFs like a PDF app (user: "do all that and the pdf viewer")
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
**Up next: Sketch 2** (2026-11-03): `docs/plans/sketch-2-plan.md`, reviewed in `docs/plans/sketch-2-review.md`,
written from the brief in `docs/plans/sketch-2-prompt.md`. It covers:
- no lag panning or zooming, and nothing going soft;
- a sleek toolbar where nothing is hidden;
- your own 100 % zoom;
- Math Assist and AI writing as light-blue handwriting strokes you can erase;
- a floating Ask box;
- the AI reading handwriting (five root causes found);
- an "AI is looking here" outline;
- choosing where AI output goes.

Nothing is built yet. It waits for the user's answers to the plan's §5 questions.

**Newest plan: `docs/MASTER_PLAN.md`** (2026-11-02, the user: "improve everything … massively increase
performance and battery life … must not miss a thing"). It has research into Paste, GoodNotes/Notability,
Obsidian and Apple Notes, a performance and battery architecture (P1 change feed: stop rebuilding the whole
library on every change; P8 Mac clipboard watcher; P10 batched segment fetch; P11 iCloud without directory
walks…), the TextKit 2 editor, Obsidian-style navigation and Views, Paste-style clipboard, notebooks, capture,
AI, sync/security, CI performance tests, decisions for the user (§13) and an order (§14). Decisions are in its §13 (2026-11-03): GoodNotes first, A Glass, PencilKit, on-device
maths and handwriting (Math Assist must be light on battery and cope with messy writing, G7), export to
`.goodnotes` for notebooks, whiteboards and every drawing (G13). Order in §14: speed core, then notebooks,
then GoodNotes export, then past GoodNotes. **Ask the user for** a blank GoodNotes notebook and whiteboard
exported in GoodNotes format (seeds for G13).

**The earlier plan is `docs/ROADMAP.md`** (mostly landed) (sketching vs GoodNotes, search, performance, AI, bridges to
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
- **Develop, performance and testing (2026-11-03), waiting on you:**
  1. Run `docs/testing/SMOKE.md` after the next install and add rows to `docs/testing/RESULTS.md` (or tell me the results).
  2. Settings → Battery → Lag and frames: keep **Watch for lag** on for a day, run **Measure frames** while
     scrolling, panning and writing, then **Export diagnostics** (or "Save a copy to the vault") and send it.
     This gives the device numbers `docs/PERF_AUDIT.md` §2 marks pending, and your devices' OS versions.
  3. On the Intel Mac, run the Terminal commands in PERF_AUDIT §6 while something lags; paste the output.
  4. For Develop's AI marking check: mark 20–30 of your own attempts by hand, point by point (typed and
     handwritten, easy and hard, right and wrong). They stay in your vault (not the repo).
  5. Import a TSV from Trove into Anki Desktop and AnkiMobile once Develop's export is in the apps (TEST-CARD-010).
  6. **Before any public launch:** legal advice on the paper catalogue, and ask the exam boards (AQA, Pearson,
     OCR, WJEC/Eduqas, CCEA); BPhO and UKMT papers only as your own uploads (DEVELOP_PLAN Appendix E).
- **The way back to before the Develop work** (2026-11-03): `main` as it was is saved on the branch
  `archive/main-before-develop` (b5c07b9). To go back: `git checkout -b old archive/main-before-develop`.
  Never delete or force-push it.
  - No `pre-develop` tag: the user doesn't want one (the branch is enough).
- **Your own AI (Claude):** create an API key at https://console.anthropic.com/settings/keys, add
  credit (about $5) and set a monthly spend limit there, then paste the key into Trove → Settings →
  AI → Your AI (never into a chat). It syncs to your other devices end-to-end encrypted.
- **Apple Notes import (Mac):** allow Trove to control Notes when asked (System Settings → Privacy &
  Security → Automation → Trove → Notes), then Settings → Integrations → Import now.
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
- **Relay AI model:** `CLAUDE_MODEL` defaults to `claude-haiku-5-5` (`server/src/ai.ts` `DEFAULT_MODEL`); the user wants costs at pennies.
- **Web app keys:** the web app stores derived keys in the browser. That's the one exception to "secrets only in the Keychain". If the user would rather not, remove the `assets` block from `server/wrangler.jsonc`.
- **Bundle ids:** `com.mrlancus.trove(.share/.widgets/.safari)`. App Group: `group.com.mrlancus.trove`.
