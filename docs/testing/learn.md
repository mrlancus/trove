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
