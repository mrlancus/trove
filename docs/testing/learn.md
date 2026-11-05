# Trove for learners (LEARN)

The change of direction in `docs/plans/learn-pivot-plan.md`: Learn first, hidden features, privacy defaults,
the vault code, specifications, own courses, questions in the style of real papers, the shared bank. Tests are
added with each step of plan §9.

### TEST-LEARN-001: Connections is gone, and comes back for tests
- **Feature**: Features.graph (plan §3 A1)
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: iPhone, iPad, Mac, website
- **Preconditions**: a vault with two notes, one linking the other with `[[…]]`.
- **Steps**:
  1. Look at the sidebar (iPad, Mac, website) or the Library list (iPhone).
  2. Open the linking note.
  3. Open the Clipboard (website: look for List / Map).
  4. Command palette (⌘K): type "graph".
- **Expected**: no Connections row; the note shows its link and backlink but no small graph; no Map on the
  clipboard; no "Show connections graph" command. Launched with `-TroveFeatures all` (website:
  `localStorage["trove.features"] = "all"`), all of them are back and work.
- **Failure looks like**: a Connections row, a graph canvas on an item, a Map button.
- **Automated by**: `TroveUITests/testConnectionsIsHidden`, `testConnectionsWithFeaturesOn`;
  web `organize.e2e.mjs` "hidden features are gone by default" (flags off) and "imports are filed…" (flags on).

### TEST-LEARN-002: No Obsidian sync, and the Markdown copy is off unless chosen (Mac)
- **Feature**: Features.obsidian, readable copy (plan §3 A3)
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: Mac
- **Preconditions**: the Mac that made the vault (the mirror owner).
- **Steps**:
  1. Settings → Other apps.
  2. Sync a few times; look in iCloud Drive → Trove → Notes.
  3. Turn on "Keep a readable copy of my notes in iCloud Drive"; sync; look again.
  4. Turn it off; tap Delete the copy… and confirm.
- **Expected**: no "Sync with an Obsidian vault"; no new `.md` files until step 3; the line says the copy
  isn't encrypted; step 4 removes `Trove/Notes` and nothing in Trove changes.
- **Failure looks like**: `.md` files written with the setting off; the Obsidian folder touched.
- **Automated by**: `FeaturesTests` (Mac unit tests: `mirrorPlan`, older configs decode).

### TEST-LEARN-003: GitHub and Telegram bridges are hidden and paused
- **Feature**: Features.githubBridge, Features.telegramBridge (plan §3 A2, review R9)
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all (needs the relay)
- **Preconditions**: a vault on the relay with a GitHub bridge and a feed, added with an older build or the
  website with `trove.features = "all"`.
- **Steps**:
  1. Install this build; open it and wait half a minute.
  2. Settings → Bridges.
  3. On the website (flags on), open Bridges.
- **Expected**: step 2 shows add addresses and feeds only; step 3 shows the GitHub bridge Off; the feed is still
  on. A build with the flag back on switches the GitHub bridge on again, but not one you'd switched off yourself.
- **Failure looks like**: the GitHub bridge still running every 6 hours (its "Checked" time keeps moving).
- **Automated by**: `BridgePauseTests` (TroveCore), web `organize.e2e.mjs` "hidden features…".

### TEST-LEARN-004: Location is off by default in a new vault
- **Feature**: privacy default (plan §7, review R3)
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Steps**:
  1. Make a new vault (app or website).
  2. Settings → Clipboard: look at "Record where you copy and paste".
  3. Copy something on each device; open the clip's details.
- **Expected**: off on every device, including an older build joined to the vault; no place on the clip. The
  line says what turning it on records.
- **Failure looks like**: a place on a clip nobody chose to record.
- **Automated by**: `PrivacyDefaultTests`, web `core.test.mjs` (clips), `relay.e2e.mjs` (a new vault writes it).

### TEST-LEARN-005: Creating a vault on the relay needs its code
- **Feature**: VAULT_CREATE_CODE (plan §7 E2)
- **Priority**: critical
- **Coverage**: auto-tested (relay, clients' error handling); on the deployed relay: not tested
- **Platforms**: website, iPhone, iPad, Mac
- **Preconditions**: the relay deployed with the secret set.
- **Steps**:
  1. Website → Create my vault, no code.
  2. Type a wrong code; then the right one.
  3. In an app with a vault not on the relay: Settings → Connect relay (or Turn on the relay).
  4. Try five wrong codes, then the right one.
- **Expected**: step 1 shows the code field and says why; a wrong code says so; the right one creates the
  vault; step 3 behaves the same; after five wrong codes the right one is refused for an hour ("Too many
  wrong codes"). Joining an existing vault with a setup code never asks for it.
- **Failure looks like**: a vault made without the code; the code asked for when joining.
- **Automated by**: `server/test/gate.test.ts`, `VaultCodeTests`, web `core.test.mjs`.

### TEST-LEARN-006: A course comes with its specification
- **Feature**: specifications (plan §C6)
- **Priority**: high
- **Coverage**: auto-tested (catalogue, reader on written lines); real specs by script; the app: not tested
- **Platforms**: iPhone, iPad, Mac
- **Steps**:
  1. Learn → Add a course → AQA A-level Physics (7408), on Wi-Fi.
  2. Open the course; look at Specification.
  3. Open "3.4 Mechanics and materials".
  4. On another device, open the same course.
- **Expected**: the specification downloads by itself and shows its topics (3.1 … 3.12); 3.4 opens to its
  statements with their text (3.4.1.6 Momentum …); the other device gets the file from your trove, not the
  board, and shows the same. AQA GCSE Maths shows its codes (N1, A1 …) under their sections.
- **Failure looks like**: front matter ("Why choose AQA") as a topic; a topic with no statements; a spinner.
- **Automated by**: `SpecReaderTests`, `CatalogueTests` (spec first in `downloadPlan`), `RealSpecTests` with
  `scripts/catalogue/spec-sample.py`, `optionPapersPairWithTheirOwnOptionsScheme`.

### TEST-LEARN-007: Learn comes first
- **Feature**: navigation, Home, first launch (plan §4 B1–B3)
- **Priority**: critical
- **Coverage**: auto-tested (UI tests: order, Home); first launch: not tested
- **Platforms**: iPhone, iPad, Mac
- **Steps**:
  1. Make a new vault.
  2. Answer "What are you learning?" with An exam course; pick one.
  3. Look at Home; tap Start in Up next.
  4. iPhone: look at the tab bar. iPad/Mac: the sidebar.
- **Expected**: step 2 opens the course picker and then Learn; Home shows the next goal (if any), Up next with
  "3 questions on …, ~10 min" and due cards, three numbers, Continue, then Jump back in and Pinned, with New
  note / New sketch / Import small at the bottom; Start opens a 3-question session in Learn; tabs are Home ·
  Learn · Library · Clipboard · Search; the sidebar has Learn right under Home.
- **Failure looks like**: Home leading with notes; Start opening nothing on iPhone.
- **Automated by**: `TroveUITests.testLearnComesSecond`, `testLibraryScrollsAndShows` (opens on Home).

### TEST-LEARN-008: Study rules from the research
- **Feature**: small sessions, quiet streaks, mixing, explain why, the tutor holding back (plan §1.1, step 3b)
- **Priority**: high
- **Coverage**: auto-tested (core rules); on a device: not tested
- **Platforms**: all
- **Steps**:
  1. Practise on two days with a day off between; look at "days in a row".
  2. Start Up next with two topics practised before.
  3. Get a question right; then get one wrong.
  4. With nothing written, ask for hints until the last one.
  5. Tap Mark it before writing anything.
- **Expected**: the rest day keeps the count (two missed days end it), with no warning anywhere; the set mixes
  the topics, never the same twice in a row; "Got it right. In a sentence, why does it work?" shows after the
  right answer only; the last hint is the next step, not the full solution, and asks you to write a first
  line; the attempt records that the scheme was shown before trying (`shownAt`, `shownBeforeTrying`).
- **Failure looks like**: a streak lost to one day off, "you'll lose your streak", the full solution with no
  working.
- **Automated by**: `PracticeStatsTests/aRestDayKeepsTheStreak`, `practicePicksAreSeededFreshAndFiltered`
  (mixing), `DevelopHintTests` (incl. a fake model).
