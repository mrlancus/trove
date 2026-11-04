# Trove for learners: review of the plan

**What was reviewed:** `docs/plans/learn-pivot-plan.md`, first draft. It was checked against the brief
(`learn-pivot-prompt.md`) and the code at `main` 4eb66b8.

**Method:**
- Every claim about the code was opened at the file and line it cites.
- Every request in the brief was traced to plan items.
- Every research claim was checked against its source, and the weak ones were marked.
- Each data change was checked against what older builds do with it.

Every issue below has been fixed in the plan. The **Fix** line says how.

## Verdict

**Sound after fixes.**
- The direction matches the brief: learning first, notes and the clipboard second, AI coding and the graph
  hidden but kept.
- The research supports the core of what Develop already does: retrieval, spacing, a hint ladder, and a
  tutor that holds the answer back.
- The draft had two things wrong about what already exists:
  - Ink synced to audio is already built (R1).
  - Studying every due card already exists (R6).
- It also had four data or test changes that would have broken something (R2–R5).

## Must-fix (the draft would have broken something)

**R1. Ink synced to audio already exists.**
- `App/Sources/Drawing/InkAudio.swift` (`InkAudioController`, MASTER_PLAN G4) already does this: record while
  writing, play back with the strokes of that moment marked, lasso a stroke and play from it.
- The draft planned to build it again in §6 and sized lectures L.
- **Fix:** §6 reuses `InkAudioController`. What's new is only the transcript (SpeechAnalyzer, or the fallback)
  and "Make questions from this lecture". Step 8 is now M.

**R2. Own courses would break campaigns and spin forever on older builds.**
- `Campaign.Goal.sourcePrefixes` (`Campaign.swift:78`) takes a goal's problems by catalogue prefix
  `cat:<course>-`. An own course has no catalogue papers, so a goal on an own course would find no problems.
- `CourseView` (`CoursesView.swift:284-290`) shows a `ProgressView` until `loadSpec` returns a spec. For
  `own.<uuid>` it never does, so the screen spins forever. Older builds on your other devices would show that
  until they update.
- **Fix:**
  - §5 C1: campaigns take an own course's problems by topic membership (the problem's `skills` that are
    `partOf` the course). This is a `CampaignPlanner` change with tests.
  - `CourseView` gets an own-course screen, and a "not in the catalogue" state instead of the spinner.
  - The step says to update every device: they're all sideloaded and reinstalled weekly anyway.

**R3. Location recording defaults to on in the apps and the website, and "absent" means on.**
- `ClipboardStore.recordPlaces = true` (`ClipboardStore.swift:43`).
- The website's `vault.appSetting(name, standard = true)` (`core/vault.js:1193`) reads a missing
  `recordPlaces` as true.
- Changing only the default in new builds would leave older builds recording location in a vault where
  nobody chose it.
- **Fix:** §7 changes both defaults, **and** a new vault writes `recordPlaces: false` explicitly, so every
  build agrees. Existing vaults keep their setting. You can turn yours off in Settings.

**R4. Hiding the website graph breaks a test that must keep passing.**
- `web/test/organize.e2e.mjs:118` waits for `#local-graph canvas`.
- Skipping or deleting the check to make it pass is ruled out. The point of keeping the code is that it
  still works.
- **Fix:** §3 A1 makes the flags switchable in tests:
  - The website: a `trove.features` override in `localStorage`, set by the e2e.
  - The apps: a `-TroveFeatures all` launch argument, read once at start.

  The tests for hidden features keep running with the flag on. New tests check they're gone with it off.

**R5. A `kind` field on problems would be confusing and risky.**
- Items already use a `kind` field for "what an item is", and records have their own kind (`problem`).
- **Fix:** §5 C3 calls the field `format` (`written` by default, `recall`, `rated`, `spoken`). `Problem`
  (`DevelopRecords.swift:115`) has no such field today, so older builds ignore it and treat the problem as
  written.

## Should-fix (wrong or weaker than it could be)

**R6. Studying everything due already exists.**
- Command palette "Study flashcards" and Mac ⇧⌘Y open `StudyView(noteId: nil)`, which is every due card
  (`CommandPalette.swift:24`, `TroveApp.swift:53`).
- **Fix:** §4 B1's Cards screen lists decks and due counts, and opens the existing `StudyView`. Step 7 stays S.

**R7. The README doesn't mention trove-mcp.**
- The draft said to take it out of the README's feature list, but no line names it.
- What the README does do is lead with "save anything second brain". Develop is the sixth bullet.
- **Fix:**
  - §3 A2: nothing to remove for trove-mcp; `mcp/README.md` gets a "paused" line.
  - Step 0 rewrites the README's first paragraph and the order of its list, so learning comes first.
  - Also in step 0: `CLAUDE.md`'s first line, and `docs/RESEARCH.md`'s pitch.

**R8. Topics were stored twice.**
- The draft's C1 had both a `topics` array on the course and `concept` records joined by `partOf` edges.
- **Fix:** edges only. That avoids the array limit (DEVELOP_PLAN §A1) and is what Develop's graph already
  uses.

**R9. Pausing GitHub bridges needed a place to remember them.**
- "Records that it did so" didn't say where. A device-local note would be lost on another device.
- **Fix:** §3 A2 keeps the ids in a synced setting `features.pausedBridges`. Turning the flag back on
  re-enables exactly those, and only if you haven't changed them since.

**R10. Step 1's "done when" couldn't be checked.**
- Diagnostics doesn't log the Obsidian sync.
- **Fix:** a Mac unit test that `mirrorIfOwner` leaves the Obsidian folder alone with the flag off, plus the
  UI tests.

**R11. A new app name would use half a week's App IDs.**
- `project.yml` has five installable bundle ids (app, share, widgets, Safari, keyboard).
- A free Apple ID gets 10 App IDs per 7 days, and changing the prefix needs five new ones. That also means a
  new install, and the Keychain and app group data don't carry over.
- **Fix:** §10 Q1 says a new name changes the **display name only**, never the bundle ids.

## Smaller points (fixed in place)
- **"Practise" was called British-only spelling.**
  - The whole app writes British English, so that isn't a mark against it.
  - Its real limit is that it's narrower than "Learn" (reading and listening aren't practice).
- **The lecture fallback.**
  - On iOS 18, `SFSpeechRecognizer` may stop early on long files.
  - §6 now says: split the audio into pieces of about a minute in the fallback, and check SpeechTranscriber's
    asset availability at runtime, not only `#available`.
  - On an Intel Mac this is unverified.
- **The on-device AI.** §5 C2 now reuses `App/Sources/Enrichment/OnDeviceAI.swift` instead of a new wrapper.
- **The iPhone tab bar** is a design choice the user may want to make. It's added as §10 Q5.
- **Home already exists** with a "next step" (TEST-HOME-001). B2 is a reorder plus the exam countdown, so
  step 3 stays M.

## Research checked
- **Strong:**
  - Dunlosky et al. 2013 (practice testing and distributed practice).
  - Brunmair & Richter 2019 (interleaving, with the word-list exception).
  - Bastani et al., PNAS 2025 (the figures were read from secondary summaries; the direction is clear).
  - Barbieri et al. 2023 (worked examples).
- **Moderate:**
  - The 2026 procrastination study (self-reported, large).
  - Streak research (one consumer-research paper; the rest is commentary).
- **Weak, used only where several sources agree:**
  - The app comparisons. Most are written by competitors.
  - The Foundation Models 4k context figure comes from third-party guides. Check it in Apple's docs, or with
    `contextSize` on iOS 26.4+, before sizing chunks.

## Brief traced to plan
| Brief | Plan |
|---|---|
| Learning first, any subject, eventually anyone | §4, §5, step order 3–9 |
| Hide AI coding (MCP, GitHub bridge, "etc.") with nothing running | §3, §10 Q2 |
| Hide the Obsidian graph | §3 (`graph`, `obsidian`), §10 Q3 |
| Keep the code | §3 A1 (flags), R4 (tests keep running) |
| Notes and the clipboard secondary but there | §4 B1, §6 |
| Name undecided | §10 Q1, R11 |
| Research | §1 |
| No code this round | Step 0; this round wrote three documents |

## Not in scope, worth knowing
- **AI for under-18s.** Before any public launch, check the AI provider's terms on minors, and the Children's
  Code's rules on profiling and transparency. For personal use, it's your own key and your own vault.
- **Copyright** (DEVELOP_PLAN Appendix E) applies to questions made from board papers. Questions made from
  your own notes are yours.

## After the user's answers (2026-11-04)
These are the user's decisions, not review fixes. They're now in the plan:
- **The section is Learn**, and the app stays Trove.
- **The iPhone Clipboard keeps its own tab.**
- **RSS feeds and add addresses stay**; the Telegram bot is hidden like the GitHub bridge.
- **The Markdown copy is off by default, with a setting** (plan §3 A3).
  - Checked: `mirrorIfOwner` (`AppModel.swift:1268`) exports whenever this is the mirror-owner Mac,
    encrypted vault or not.
- **Haiku 5.5 writes questions in the style of real papers**, with mark schemes in the board's format and a
  second pass that solves and checks each question (plan §C2.3).
  - Checked: the relay's allowance is 1M metered tokens a month, and cache reads count a tenth
    (`server/src/ai.ts:19,73`).
  - Costs (plan §C4) are estimates from the published Haiku 5.5 prices. Measure them on the first real sets.
