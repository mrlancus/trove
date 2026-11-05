# Trove for learners: the plan

_Written 2026-11-04 from `learn-pivot-prompt.md`, after reading the code at `main` 4eb66b8. Reviewed in
`learn-pivot-review.md`. Where this plan and the code disagree, the code wins and this plan gets fixed._

**In one line:** Trove becomes the place where you learn something: practise it, get help when you're
stuck, see that you're getting better. Notes, sketches and the clipboard stay, as the tools you learn
with. The AI coding and Obsidian graph parts are hidden. They aren't deleted.

Reading guide:
- §1 is the research, with sources.
- §2–§8 are the plan.
- §9 is the order of work.
- §10 lists the decisions that are yours.

---

## 1. What the research says

### 1.1 How people learn, and what that means for the app
- **Two techniques reliably work**: practice testing (retrieval) and spreading practice out over time.
  - The 2013 review of ten study techniques rated only these two "high utility".
  - Rereading, highlighting, summarising and keyword mnemonics were rated "low", yet they are what most
    students do ([APS summary of Dunlosky et al. 2013](https://www.psychologicalscience.org/news/releases/which-study-strategies-make-the-grade.html);
    [table](https://texasldcenter.org/?p=346)).
  - **For Trove:** the main action everywhere is "test yourself", not "read your notes again". Spacing is
    already built: FSRS for cards, and decision 9's retention for skills.
- **Interleaving** (mixing similar kinds of problem) helps, but how much depends on the material.
  - Overall g = 0.42 and maths g = 0.34. It helps most when the categories are easy to confuse.
  - For lists of words, blocking won (g = −0.39)
    ([Brunmair & Richter 2019](https://pubmed.ncbi.nlm.nih.gov/31556629/)).
  - **For Trove:** mix topics that are similar in problem sets and mocks (`Practice.pick` already can), but
    keep vocabulary cards in blocks.
- **Worked examples help beginners**, and faded steps help most.
  - A 2023 meta-analysis found a medium effect on maths for worked examples.
  - Adding self-explanation prompts to them did *worse*
    ([Barbieri et al. 2023](https://link.springer.com/content/pdf/10.1007/s10648-023-09745-1.pdf)).
  - **For Trove:** the hint ladder (nudge → principle → approach → next step → full solution) is the right
    shape. Don't add "explain why" prompts everywhere. Offer them after a correct answer, not before.
- **AI that gives answers harms learning; AI that gives hints doesn't.**
  - In a field experiment with about 1,000 high-school maths students, plain GPT-4 lifted practice scores
    48% but lowered exam scores by 17%.
  - A tutor that had the solution and the common mistakes, and gave hints step by step, removed most of the
    harm ([Bastani et al., PNAS 2025](https://ideas.repec.org/a/nas/journl/v122y2025pe2422633122.html)).
  - **For Trove:** the tutor already gets the question and the mark scheme first (decision 20: it speaks only
    when you tap). Make "no full solution until you've tried" a rule of the tutor prompt, and record when a
    full solution was shown (marking counts it).
- **Procrastination is students' biggest barrier.**
  - A 2026 study of 65,950 US students found 72% had procrastination problems, and it ranked as the top
    academic barrier.
  - The advice: break work into small chunks, and avoid shaming
    ([THE](https://timeshighereducation.com/news/procrastination-biggest-issue-harming-students-performance)).
  - **For Trove:** the Up next card always offers something small ("3 questions, about 10 minutes"). Missed
    days are never scolded.
- **Streaks work, and they can backfire.**
  - People protect streaks even when the streak is artificial ([JCR 2024 via phys.org](https://phys.org/news/2024-03-streaks.pdf)).
  - Losing one can end the habit, and people make worse choices to keep one.
  - **For Trove:** keep "days in a row" as a quiet number. No loss warnings, rest days that don't break it,
    no notifications (there's no push anyway). Decision 6 (no XP) stands.

### 1.2 What learners use, and why they leave
Most comparison pages are written by competitors, so this section uses only what several of them agree on.
- **Anki** is the strongest at memorising, and people quit it in the first week.
  - The reasons: making cards takes too long, it looks hard, and it costs £25 on iPhone.
  - FSRS beats Anki's old SM-2 scheduler for nearly every user in the open benchmark
    ([Anki docs](https://docs.ankiweb.net/faqs/what-spaced-repetition-algorithm.md)). Trove already uses FSRS-5.
- **Quizlet** is easy, but people leave because features went behind the paywall (spaced repetition is in
  Plus).
- **Knowt** is chosen as "free Quizlet", partly because it imports Quizlet sets
  ([overview](https://mystudylife.com/best-study-apps-for-students-2026/)).
- **AI-made cards** get a growing number of accuracy complaints. Users want to see where a card came from.
- **NotebookLM** makes flashcards and quizzes from your own sources, traceable to them, and suggests what to
  learn next ([Google](https://blog.google/technology/google-labs/notebooklm-student-features/)). It's for
  understanding, not for memorising over months.
- **GoodNotes** has Study Sets (flashcards with spaced repetition) and "Quiz me" from your notes.
- **Notability** records lectures with a transcript linked to the ink: tap a word and the recording jumps
  there. Its AI summaries and quizzes are paid.
- **Self-learners** have many "AI makes you a roadmap for any topic" apps (MapMyLearn, roadmap.sh's app,
  SkillForged). Self-paced courses are finished less than 15% of the time
  ([listing](https://www.trendhunter.com/trends/mapmylearn)). Plans need checkpoints and evidence, not just
  a list of topics.

**Where Trove can win** (what none of them does in one place):
1. **Real exam questions from the boards**, practised in handwriting, with the real mark scheme. The catalogue
   already covers AQA, OCR, Pearson, Eduqas, WJEC and Cambridge.
2. **A tutor that reads your handwriting and holds back the answer.**
3. **Mastery you can explain** from your own attempts (decision 9), not a streak or XP.
4. **Your notes, PDFs and lectures turned into practice, on the device, private.** End-to-end encrypted, no
   account, no ads.
5. **Free core**: practice, FSRS and marking without AI cost nothing. People leave Quizlet and Anki over
   price.

### 1.3 Apple's frameworks
- **Foundation Models**:
  - About 3B parameters, with a **4,096-token context** (input and output together) on iOS/iPadOS 26.
  - Guided generation (`@Generable`) returns typed Swift values.
  - Needs an Apple Intelligence device: here that is **only the iPad**. The user's Mac is Intel and has none.
  - Sources: [guide](https://www.atelier-socle.com/en/articles/foundation-models-api-guide),
    [InfoQ](https://infoq.com/news/2026/03/apple-foundation-models-context).
  - **For Trove:** too small to write exam questions in a paper's style (§C2.3).
    - That needs several real questions and their mark schemes as examples, plus your material.
    - It's also weak at accurate maths and science.
    - So questions are written by **Haiku 5.5** (your choice, 2026-11-04). The on-device model does only
      small free jobs on the iPad, such as suggesting which topic a question belongs to.
- **SpeechAnalyzer / SpeechTranscriber** (iOS/macOS 26) are made for long, distant audio such as
  lectures, run on the device, and support about 10 languages at launch
  ([WWDC25 session](https://nonstrict.eu/wwdcindex/wwdc2025/277/)).
  - `App/Sources/Enrichment/Transcriber.swift` uses the older `SFSpeechRecognizer`, with a TODO to prefer
    SpeechAnalyzer.
- **Vision** (handwriting OCR), **NaturalLanguage** (embeddings for "maybe related"), **PencilKit** and
  **Translation** are already used, or are available.

### 1.4 Under-18 users
The UK Age Appropriate Design Code applies to any app *likely* to be used by under-18s
([summary](https://trustarc.com/resource/uk-age-appropriate-design-code/)):
- High-privacy defaults.
- **Location off by default.**
- Profiling off by default.
- No nudging toward less private settings.
- No analytics collected by default.

Trove is already close: there are no ads, diagnostics are local only (decision 15), and study with friends is
invite-only. One default breaks it (§7).

---

## 2. What exists (checked in the code)
- **Navigation**:
  - `AppModel.Selection` has `home, smart, collection, source, folder, unfiled, graph, importer, clipboard,
    develop` (`App/Sources/Model/AppModel.swift:17-27`).
  - The sidebar's first section is Home, Clipboard, Develop, Connections, Import (`MainView.swift:357-368`).
  - iPhone tabs are Home, Library, Clipboard, Practise, Search (`PhoneViews.swift:24-55`).
- **Develop records** (`DevelopRecords.swift`, PROTOCOL §13):
  - `concept` (concept or skill).
  - `edge`, with nine types.
  - `problem`, where `ProblemLevel` already has `university` and `other`.
  - `attempt`.
  - `course` (`Papers.swift:422`: `id = course.<slug(spec)>`, fields `spec, name, active`).
  - Goals and campaigns (`Campaign.swift`, `GoalChat.swift`).
  - `Difficulty.levelBase` gives `.other` a prior of 0 (`Mastery.swift:179`).
- **Cards**: FSRS-5 cards from a note's `flashcards` field (`Model/Study.swift`), studied in `StudyView`.
  Anki export (TSV and `.apkg`).
- **Graph**:
  - `Links.graph` builds links and backlinks in `AppModel.reload` (`AppModel.swift:460`). Backlinks need it.
  - The Connections screen is `GraphView.swift`. It's reached from the sidebar, the command palette
    (`CommandPalette.swift:32`) and the iPhone list (`PhoneViews.swift:82`).
  - The small graph on an item is `GraphCanvas(focus:compact:)` (`ItemExtras.swift:290`).
  - Website: `graph.js`, and the clipboard Map from `core/clipmap.js`.
- **Obsidian**:
  - `mirrorIfOwner` (`AppModel.swift:1266`) runs on the Mac after syncs. It **exports notes as Markdown to
    `<vault>/Notes`** and, if `obsidianFolder` is set, **syncs both ways with that Obsidian folder**.
  - The setting is in `SettingsView.swift:556-579`.
  - Import's "Notion & Obsidian exports" (`ImportView.swift:23`) is a one-off import.
- **GitHub bridge**:
  - The relay (`server/src/bridges.ts`) runs an enabled `github` bridge every 6 h (`EVERY`, line 20), and
    RSS every 2 h.
  - Bridges have an `enabled` flag, which the apps and the website can already change
    (`updateBridge(id, enabled:)`).
  - UI: `BridgesView.swift` and `web/public/bridges.js`.
- **trove-mcp**: a separate Node program (`mcp/`). Nothing in the apps or the website mentions it. CI runs
  its tests (`.github/workflows/tests.yml:63,122`). It only runs if the user starts it on a computer.

---

## 3. Part A: hide the AI coding and Obsidian graph features

### A1. One switchboard
- Add `App/Sources/Platform/Features.swift`: `enum Features { static let graph = false; static let
  obsidian = false; static let githubBridge = false }`.
- Add the same to `web/public/features.js`.
- Constants, not settings: nothing to sync, nothing to migrate.
- Switching a feature back on is one line plus a build.
- Every entry point and every background start checks its flag.
- **Tests can turn everything back on** (review R4):
  - The apps: the `-TroveFeatures all` launch argument, read once at start.
  - The website: a `trove.features` override in `localStorage`.
  - The existing tests for hidden features keep running with the flag on (for example
    `organize.e2e.mjs:118`, the item's graph). New tests check the features are gone with it off.

### A2. What each flag turns off
| Flag | UI hidden | Background stopped | Kept |
|---|---|---|---|
| `graph` | Connections in the sidebar, the command palette and the iPhone list; the small graph on items; the Notes/Clipboard graph switch; the website's graph and clipboard Map | Nothing runs by itself: the graph is built only while it's on screen | `Links.graph` (backlinks, `[[links]]`, unlinked mentions), "maybe related", `DevelopGraph` (Develop's edges, decision 11) |
| `obsidian` | Settings → "Sync with an Obsidian vault" | The Obsidian folder sync in `mirrorIfOwner` | `obsidianFolder` in the config (unused while hidden); the Notion & Obsidian import |
| `githubBridge` | The GitHub part of Bridges (apps + website) | The relay's 6-hourly run: on first launch with the flag off, the app sets any `github` bridge to `enabled: false` through the existing API, and keeps their ids in the synced setting `features.pausedBridges`. Turning the flag back on re-enables exactly those, unless you've changed them since (review R9) | The relay code and its tests (CLAUDE.md: the relay is done) |
| trove-mcp | Nothing in the apps, the website or the README names it (review R7). `mcp/README.md` gets a "paused" line at the top | Nothing runs unless the user starts it. Its CI tests keep running, so the code doesn't rot | `mcp/`, the `agent` device kind |

**Cost of keeping it**: CI minutes (free, the repo is public) and keeping `Links.graph` working, which
backlinks need anyway. Nothing ships that runs.

### A3. The Mac's Markdown copy: off by default, with a setting (your choice, 2026-11-04)
- **What it is**: `ObsidianMirrorService.export`, called from `mirrorIfOwner`.
  - The Mac that made the vault writes every note as a plain `.md` file into `Trove/Notes/` in iCloud Drive
    after syncs.
  - It's one-way: Trove never reads those files back.
- **Why it changes**: it's written even when the vault is end-to-end encrypted (`AppModel.swift:1268` checks
  only `mirrorOwner`), so it leaves your notes as plain text in iCloud Drive.
- **The change**:
  - A new device setting, "Keep a readable copy of my notes in iCloud Drive", **off by default**.
  - The Settings line says plainly that the copy isn't encrypted.
  - `mirrorIfOwner` exports only when the setting is on.
  - Files already in `Trove/Notes/` aren't deleted by themselves. Settings offers "Delete the copy", which
    asks first.

---

## 4. Part B: learning comes first

### B1. Navigation
- **iPad and Mac sidebar**:
  - **Home**.
  - **Learn** (renamed from "Develop", your choice, 2026-11-04): Up next, Courses, Your work, Goals, Cards.
  - **Notes & Sketches**: Library, Today's note, folders, smart collections.
  - **Clipboard**.
  - **Import**.
  - Connections is gone (A2).
- **iPhone tabs**: Home, **Learn**, Library, Clipboard, Search.
  - The Clipboard keeps its own tab (your choice, 2026-11-04).
  - Learn replaces "Practise" and moves to second place.
  - The tab-switch logic in `PhoneViews.swift:68` follows the new order.
- **Cards** become part of Learn:
  - Studying everything due already exists, as a sheet: command palette "Study flashcards", Mac ⇧⌘Y,
    `StudyView(noteId: nil)` (review R6).
  - What's new is a Cards screen in Learn that lists decks and their due counts, and opens that same
    `StudyView`.
  - Due cards appear in Up next with questions.

### B2. Home
Order, top to bottom:
1. Greeting and the next exam or goal date ("Physics paper 1 in 23 days").
2. **Up next**: one small session ("3 questions on momentum, ~10 min"), plus due cards.
3. The three numbers: this week, days in a row (quiet), recent average.
4. Continue: the last practice sketch or topic.
5. Jump back in: notes, sketches and clips, smaller.
6. Pinned.

New note, New sketch and Import stay as small buttons.

### B3. First launch
- After the vault is made, ask **"What are you learning?"** with three answers:
  1. **An exam course**: the catalogue picker that already exists.
  2. **Something of my own**: §5.
  3. **Just take me to my notes**: skip.
- The answer sets Home's Up next. Nothing is locked behind it.

### B4. Finish what's half built (from NOTES "Not done / next")
- Topics from the course's spec instead of the paper.
- Thumbnails of the working in Your work.
- The rest of the app on `Theme`.

---

## 5. Part C: learn anything

Develop's records are already general. `ProblemLevel.other`, concepts, skills, edges and attempts don't
depend on exam boards. What's missing is a way to make a course and questions without a board.

### C1. Your own courses
- A `course` record with `spec: "own.<uuid>"` and a new field, `source: "own"`.
- **Topics are `concept` records** of type `skill`, joined by `partOf` edges to a concept for the course.
  - There's no topics array on the course. That avoids the array LWW limit (DEVELOP_PLAN §A1) and the
    duplicate the draft had (review R8).
- **Campaigns** (review R2):
  - Today they take problems by catalogue prefix (`Campaign.swift:78`).
  - For an own course, they take the problems whose `skills` are `partOf` that course. This is a
    `CampaignPlanner` change, with tests.
- **The course screen** (review R2):
  - Today `CourseView` spins until `loadSpec` returns a spec (`CoursesView.swift:284-290`).
  - It gets an own-course layout (topics, Add questions, Add notes), and a "not in the catalogue" state
    instead of the spinner.
  - Older builds show the spinner for own courses, so update every device in the same week.
- **Making one**:
  - Type a name and topics.
  - Or let the goal chat (`GoalChat`) suggest topics from what you say ("learn Japanese for a trip in
    March").
  - Or pick an uploaded syllabus or contents page and split it into topics on the device.
- PROTOCOL §13 gets the new fields. Swift, JS and fixtures change in the same commit (CLAUDE.md).

### C2. Where questions come from
1. **Board papers**: as now.
2. **Your uploads**: as now (split; one question per page when there's no text).
3. **New questions in the style of your real papers** (your choice, 2026-11-04: "always use examples from
   existing pdfs uploaded and make questions in that style not random generated ones … not the same but
   similar style … realistic mark schemes").
   - **Model**: Haiku 5.5, only when you tap. Costs are in §C4.
     - It runs through **your own key** (Settings → AI, `AppModel+OwnAI.swift`), straight from the device,
       under your own limits.
     - The relay's AI is only a fallback, and it isn't switched on today. The relay's secrets are
       `AI_MONTHLY_LIMIT` and `BRIDGE_KEY`, with no `ANTHROPIC_API_KEY` (checked 2026-11-04).
   - **Real questions first.** Practising the catalogue's real past questions costs nothing. Trove writes
     new ones only where they run short: spec points with few or no past questions, or a topic whose real
     questions you've all done. And it **looks in the shared bank first** (§C7).
   - **Effort: write at low, check at low, rewrite at medium only on failure** (your call, 2026-11-05: "half
     a penny … does add up").
     - The 2026-11-05 tests (`learn-pivot-effort-tests.md`: 7 boards and subjects, real PDFs) found no wrong
       facts or numbers at either level. Low had design flaws in 4 of 7 (a contradiction, a given-away
       answer, the wrong scope, a stale copied guidance line). Medium was better or equal in all 7.
     - Most of low's flaws are caught by the code checks (§C9) and the targeted check call. A question that
       fails is rewritten **once at medium**.
     - The test set decides: if more than half of the low questions need the medium rewrite, writing at
       medium from the start is cheaper, so switch.
     - For generation, this replaces decision 7's "medium for hard questions by a fixed rule". Marking keeps
       decision 7's one medium re-check of uncertain marks.
   - **Structured output**: the model returns JSON (question parts, marks, AO codes, answers, marking points,
     guidance lines with their worked values, tags). That's what the code checks run on.
   - **Always from real examples.**
     - Each request carries 3–5 real questions on the same topic, with their real mark schemes, from the
       downloaded board papers and your uploads. Same course first, then the same board and level.
     - **The specification statements for the topic** (§C6), so each new question tests a named spec point.
       That also shows which spec points have no past questions yet, the best ones to make questions for.
     - Plus your own material for the topic (notes, transcript), if there is any.
     - No examples, no generation: the course asks you to download or upload a paper first.
   - **Close copies are the goal** (your call, 2026-11-05: "gcses and most of a level shld basically be the
     same question just slightly different"):
     - The same set-up, command words ("calculate", "explain", "evaluate"), mark values and part structure.
     - New numbers, objects and details, so the answer is new.
     - Guidance lines are **rewritten for the new numbers**, never copied (both GCSE Maths test runs left a
       stale value behind by copying).
     - Only a question whose wording matches a real one exactly, or near-exactly, is refused (a word-overlap
       check on the device). Copyright is your call, logged in §10 Q10.
     - Diagrams described in words, or drawn as a simple sketch on the page.
   - **Mark schemes in the board's own format**:
     - M1/A1 method and accuracy marks for maths.
     - Marking points with alternatives ("allow …", "ignore …") for science.
     - Levels with indicative content for long answers.
     - The scheme's total must equal the question's marks.
   - **Checked before you see it** (§C9):
     - First, the free checks in code.
     - Then a separate low-effort Haiku call that never sees the mark scheme. It solves each part from
       scratch, and answers targeted questions: does the set-up contradict itself? Does any part reveal
       another part's answer? Is the scope what was asked for?
     - A question that fails is rewritten once at medium. If it fails again, it's dropped.
   - **Labelled honestly**:
     - "Trove-made, in the style of AQA 7408 Paper 1".
     - `origin: ai`, with `madeFrom` edges to the examples and the material it used.
     - You can see those examples. "This is wrong" removes the question and is remembered.
   - **Where it's kept**:
     - Made from board papers: in your vault, **and offered to the shared bank** (§C7).
     - Made from your own notes, uploads or lectures: your vault only, never shared, because those could
       contain anything.
   - **Difficulty**: the examples' level prior (`Difficulty.levelBase`), until your own attempts give an
     estimate.
4. **Typed by you**: a question, its answer or mark points, and a topic.
5. **Cards**: as now, and they can be made from a question you got wrong ("Make a card", already in §E of
   DEVELOP_PLAN).

### C3. Kinds of practice that aren't exam questions
Start with what marking already supports (`Marking`: self, AI with or without a scheme). Then add:
- **Recall in your own words**: "Explain X". Self-marked against key points, or by AI when tapped.
- **Do it and rate it**, for skills you practise away from the app (a scale on the piano, a speaking drill):
  a timer and a 1–4 self-rating. It counts as self-marked evidence. Mastery treats it like any self-marked
  attempt.
- **Speaking** (languages): record yourself; SpeechTranscriber writes it down; you check it against the
  answer. Later: AI feedback when tapped.

Each kind is a `problem` with a new `format` field: `written` (the default), `recall`, `rated` or `spoken`.
- It's not called `kind`, because items already use a `kind` field and records have a kind of their own
  (review R5).
- `Problem` has no such field today (`DevelopRecords.swift:115`), so older builds treat the problem as
  written.

### C4. What Haiku 5.5 costs for this
**Prices**: $0.10 per million input tokens and $0.50 per million output tokens (for prompts up to 100K
tokens). Cached input is cheaper still.

**One set of 5 questions** (estimates, to be measured once built):
| Call | Input | Output | Cost |
|---|---|---|---|
| Write: system prompt ~1.5k, 3–5 examples with schemes ~6k, your material ~2k | ~10k | ~4.5k (questions, schemes, thinking at low effort) | ~$0.003 |
| Check: the 5 questions ~3k, instructions ~1k | ~4k | ~5k (solving each) | ~$0.003 |
| **Total** | ~14k | ~9.5k | **~$0.006, about ½p** |

- **Per question**: about 0.1p.
- **Heavy use**: 20 questions a day for a month is 600 questions, about **50p a month**. At three times the
  estimate it's still under £2.
- **Caching**: a topic's examples are the same every time. Repeat requests read them from the cache, which
  the relay counts at a tenth. Output dominates the cost anyway.

By kind of question (sets of 5, estimates):
| Kind | Cost per set | Wait |
|---|---|---|
| Simple (1–3 marks: state, define, recall) | ~0.1p | a few seconds |
| Typical structured (4–6 marks) | ~½p | ~10–20 s |
| Hard multi-step (9+ marks, competition) | ~1p | ~30–60 s |

The next set is written in the background while you work on the current one, so there's rarely a wait.

**Limits**:
- **Your own key** (the main path) has only your limits: Settings → AI, and the spend limit in your
  Anthropic console. The relay's allowance doesn't apply to it.
- **The relay's allowance** (the fallback) is now **10,000,000 metered tokens per vault per month** (your
  choice, 2026-11-04).
  - It's set as the Worker secret `AI_MONTHLY_LIMIT`, with no code deployed. The code default
    `DEFAULT_MONTHLY_TOKENS` (`server/src/ai.ts:19`) stays at 1M.
  - Input and output count the same; cache reads count a tenth (`meteredTokens`, line 73).
  - With Haiku 5.5 the whole allowance costs at most about $5 a month.
  - It's counted in tokens, not money, so a hard set uses about five times what a simple one does.

### C5. A plan that gets finished
Campaigns already plan towards a goal. For self-learners add:
- **Checkpoints**: a short mixed quiz every few sessions. Its result re-plans.
- **Small sessions**: every plan step is at most 20 minutes.

### C6. Download the full specification with each course (your request, 2026-11-04)
"when we download entire specs and stuff we should also download like the full specification of it cus it
says all possible questions and it gives ideas for possible questions to make and makes everything easier"

- **Today the catalogue has no specification documents.**
  - `Catalogue.DocType` has a `spec` case (`Papers.swift:34`), but the 2026-11-04 catalogue lists none.
  - What it does list: 15,806 question papers, 15,186 mark schemes, 9,676 examiner reports and 1,470 data
    sheets.
  - The finders in `scripts/catalogue/` collect only past-paper documents.
- **The fix**:
  1. **Catalogue**: each finder also records the course's specification PDF, from the qualification page the
     catalogue already links (`url` in `catalogue/specs/*.json`).
     - It also records the specimen/sample assessment materials where the board publishes them.
     - Each is a `spec` doc. The weekly rebuild checks the links.
  2. **Download**: choosing a course downloads its specification first, before any paper. It's kept and
     synced like a downloaded paper (decision 3: a `paper.<doc id>` item, and the per-course switch).
  3. **On the device, read it into spec statements**:
     - Topic → subtopic → statement ("4.1.2 Momentum: use p = mv; apply conservation…"), each a `spec`
       record with `inSpec` edges.
     - This is the NOTES item "topics from the course's spec (on the device) instead of the paper". Decision
       12 holds: nothing is shipped, everything is read from your own download.
  4. **Use them everywhere**:
     - **Topics in Your work** come from the spec.
     - **Coverage**: practised, not yet practised, and no past questions at all.
     - **Generation** (§C2.3): each new question targets a spec statement.
     - **The tutor** gets the statement with the question.
     - **Campaigns** plan by spec point.
- **Own courses** (§C1): an uploaded syllabus or contents page is read the same way.
- **Copyright**: specifications are public documents on the boards' sites. They're downloaded from the board
  by each device, as papers are (DEVELOP_PLAN Appendix E), and never shipped or shared.

### C7. The shared question bank (your idea, 2026-11-05)
"anytime it generates a good question, it shld send it to cloudflare r2 so it can be used for other users so
we eventually make our own backlog and it becomes virtually free"

- **What goes in**: only AI-made questions written from board papers, with their mark schemes.
  - Never questions made from a student's own notes, uploads or lectures.
  - Nothing that identifies the student: no vault id or device id.
- **Tags on every question**, so Trove can search the bank before deciding what to write next:
  - board, course (spec id) and paper;
  - spec point;
  - question type and command words;
  - marks and AO split;
  - format (calculation, explain, data, essay, levels);
  - difficulty prior;
  - the brief version (§C9) and the model and effort that wrote it.
- **Reading**:
  - The app downloads the bank's file for each course it has, `bank/<spec>.json` plus parts if large, from
    R2 through the relay. It gets the whole course, never one topic at a time, so the relay can't see what a
    student is revising.
  - It's cached, and refreshed at most once a day, as the catalogue is (decision 19).
  - The question picker uses unseen bank questions before writing new ones.
- **Writing**, which is private to your users (2026-11-05):
  - `POST` needs a device token of a vault on your relay. Vaults need the 8-digit code (§7 E2), so only
    people you've let in can upload.
  - The relay accepts only well-formed questions: the JSON schema, every tag present, marks that add up,
    the size under a limit.
  - At most N uploads per vault per day (start with 50).
  - Questions arrive as **pending**.
- **Pending → good**: a pending question is served to other students marked "new". It becomes **good**
  after it's been attempted by 3 different vaults with no "This is wrong".
- **Flags**: "This is wrong" from 2 different vaults takes a question out of the bank, whatever its state.
- **The relay change**:
  - New routes for the bank file (read) and the pending queue (write), an R2 prefix `bank/`, and per-vault
    counters in the Durable Object.
  - PROTOCOL.md, relay tests, Swift, JS and fixtures change in the same commit (CLAUDE.md). Older apps
    ignore it.
- **Cost**: a question is a few KB, so R2's free allowance holds hundreds of thousands. Reads are served
  from R2 with no egress fee.
- **Under-18s**: what's shared is exam content, not personal data. The Settings line says plainly what's
  shared ("questions Trove writes from board papers, without your name or account") and gives a switch to
  stop contributing (on by default).

### C8. Overnight batches on the relay (half price)
- **How the batch service works**:
  - Requests go to Anthropic in bundles (up to 100,000 requests or 256 MB per batch) and run when there's
    spare capacity.
  - Most finish within an hour, and every one within 24 hours.
  - Everything costs **50% less**, including cached input.
  - Results come back by request id, in any order.
- **Why the relay runs it**: the apps can't check back while closed (no push on a free Apple ID), but the
  relay can poll on a timer (a Durable Object alarm).
- **The job**, once a night:
  1. Find spec points in the bank that are short of questions, for courses your users have.
  2. Send one batch at low effort, with the same brief, examples and checks as on the device.
  3. Collect the results, run the checks, and add the passes as pending.
  4. Rewrite the failures once at medium in the next night's batch.
- **Examples**: the relay can't read anyone's vault, and the papers aren't stored on the relay. So the
  batch fetches the real question pages from the board's public link in the catalogue, at batch time, the
  way each device does. They're used only as examples and never stored.
- **Off until you turn it on**: it needs an `ANTHROPIC_API_KEY` secret on the relay (your money; today
  there is none). A nightly cap, for example 200 questions, keeps it inside `AI_MONTHLY_LIMIT`.
- On-demand "Make questions now" stays on the normal, full-price route through your own key.

### C9. The brief, the code checks and the test set (2026-11-05)
- **The brief is a file in the repo**, `docs/plans/question-brief-v1.md`, with a version number. Every
  question records the version that wrote it. A change gets a new version and a test-set run.
- **Free code checks**, on the device and on the relay:
  - the parts and marks are what was asked for, and the scheme's marks add up;
  - every number in the answers and guidance recalculates (simple arithmetic and formulas, run by code);
  - no later part prints an earlier part's answer, unless that part is a "Show that";
  - no sentence matches a real question's wording exactly or near-exactly;
  - every tag is present.
- **The test set**: the 7 tests from 2026-11-05 to start with (AQA A-level Physics, AQA GCSE Biology, OCR
  A-level Maths, Pearson GCSE Maths, AQA A-level Chemistry, AQA GCSE History, Cambridge IGCSE Physics),
  growing to about 20.
  - Each test lists the real paper and pages from the catalogue. The papers are fetched by a script, never
    committed, like `RealPaperSplitTests`.
  - It's scored with the rubric in `learn-pivot-effort-tests.md`.
  - A run reports scores, time, tokens and how many questions needed the medium rewrite.
  - It's run by hand, with your key, when the brief, model or effort changes. It's not part of CI, because
    it costs money.

---

## 6. Part D: notes and the clipboard as learning tools
- **Notes per topic**: a topic shows its notes (items with an `about` edge to the topic's concept, which
  Develop already suggests) and "New note for this topic".
- **Practise this** on any note, PDF or sketch (it exists: decision 8) makes questions from it (§C2.3).
- **Lectures**:
  - Ink synced to audio **already exists**: `InkAudioController` (`App/Sources/Drawing/InkAudio.swift`,
    MASTER_PLAN G4).
    - It records while you write, plays back with the strokes of that moment marked, and plays from a
      lassoed stroke (review R1).
  - What's new:
    1. **A transcript**: SpeechAnalyzer behind `#available(iOS 26, macOS 26, *)`, also checking its speech
       asset at runtime.
       - Otherwise `Transcriber.swift`'s `SFSpeechRecognizer` path, split into pieces of about a minute,
         because it can stop early on long files.
       - Unverified on the Intel Mac.
    2. **"Make questions from this lecture"** (§C2.3), from the transcript and the page's handwriting.
- **Clipboard**: unchanged and still synced. One addition: "Save to a course" on a clip, which makes a note
  in that course's topic.

---

## 7. Part E: privacy and under-18 defaults
- **Location recording is on by default.**
  - In the apps: `ClipboardStore.recordPlaces = true` (`ClipboardStore.swift:43`).
  - On the website, a missing setting reads as on: `appSetting(name, standard = true)`
    (`core/vault.js:1193`).
  - So every copy and paste keeps the device's location. Under the Age Appropriate Design Code, location
    must be off by default.
- **Fix** (review R3):
  - Change both defaults to off.
  - A new vault writes `recordPlaces: false` explicitly, so older builds agree.
  - Existing vaults keep their setting. Yours can be turned off in Settings.
  - The toggle says what it records.
- Study with friends stays invite-only, as designed in its prompt.
- Nothing else changes: no analytics, no ads, no profiling outside the device.

### E2. New vaults on the relay need an 8-digit code (your choice, 2026-11-04)
- **Today** the relay accepts a new vault from anyone: `ALLOW_NEW_VAULTS: "true"` in `server/wrangler.jsonc`,
  checked in `server/src/index.ts:32` (PROTOCOL §2, `POST /vaults`).
  - NOTES says to set it to `"false"` once your vault exists, which hasn't been done.
  - Anyone who finds the URL can make vaults, which use your relay's storage, and its AI if a key is ever
    added there.
- **The change** is a relay change, so PROTOCOL.md and the relay tests change in the same commit (CLAUDE.md).
  - **The code is a Worker secret**, `VAULT_CREATE_CODE`, that you set yourself. It's never in the repo, a
    chat or a log.
    - Dashboard: Workers → trove-relay → Settings → Variables and Secrets → Add → Secret.
    - Or: `npx wrangler secret put VAULT_CREATE_CODE` in `server/`.
  - **`POST /vaults` needs it** in a header, `x-trove-create-code`. Without it, or with a wrong code, the
    answer is `403`.
  - The comparison is constant-time (both sides hashed, then compared).
  - **Guessing is limited**:
    - An 8-digit code has 100 million possibilities, so tries are limited to 5 wrong codes per IP an hour.
    - And 50 wrong codes an hour across the whole relay, after which creation pauses for an hour.
    - Kept in a small Durable Object.
  - **Order of checks**: `ALLOW_NEW_VAULTS: "false"` still turns creation off completely. If the secret
    isn't set, the relay behaves as today, so nothing breaks before you set it.
  - **Clients**: the website's and the apps' "create a vault on the relay" screens get a code field. It's
    only asked for when the relay says it's needed: the `403` carries `"code": "create_code_required"`.
  - **Existing vaults and adding devices** are unaffected. Setup codes already protect joining.

---

## 8. The website
- It syncs the new fields (own courses, problem kinds) so it never breaks them.
- It hides the same features (`features.js`).
- No new website UI for Learn in this plan (the apps first).

---

## 9. Order of work

Each step ends with tests in `docs/testing/` in the same commit, and NOTES.md updated.

| Step | What | Size | Done when |
|---|---|---|---|
| 0 | **Wait for the other session**, then: a NOTES pointer and your §10 decisions; the README's first paragraph and list order, `CLAUDE.md`'s first line and `docs/RESEARCH.md`'s pitch lead with learning (review R7) | S | NOTES says nobody is in progress; docs agree |
| 1 | **Hide** (§3): `Features` with test overrides, every entry point, the GitHub and Telegram bridges paused, the website; the Markdown copy off by default (§3 A3) | S | UI tests show no Connections, no Obsidian setting and no GitHub bridge with the flags off; a Mac unit test shows `mirrorIfOwner` leaves the Obsidian folder alone (review R10); existing graph tests pass with `-TroveFeatures all` / `trove.features` |
| 2 | **Privacy default** (§7) | XS | A new vault has `recordPlaces: false` written; the Swift and JS defaults are off |
| 2b | **Relay: an 8-digit code to create a vault** (§7 E2), with PROTOCOL.md, relay tests, website + app field; you set the secret | S | Relay tests: no code, a wrong code and the 6th try are refused, the right code works, no secret behaves as today; deployed only when you say "publish" |
| 2c | **The specification with each course** (§5 C6): catalogue finders, download, spec statements | M | Every catalogue course with a public spec has a `spec` doc; spec-statement tests on real specs (fetched by a script, never committed, like `RealPaperSplitTests`) |
| 3 | **Navigation, Home, first launch** (§4 B1–B3), and the name (§10 Q1) | M | iPhone and iPad UI tests; TEST-HOME updated |
| 3b | **Study rules from the research** (§1.1): Up next always offers a small session (about 3 questions, ~10 min); "days in a row" stays a quiet number, with rest days that don't break it and no loss warnings or scolding; similar topics mixed in sets and mocks (`Practice.pick`) but vocabulary cards kept in blocks; "explain why" offered after a correct answer, not before; the tutor holds back the full solution until you've tried, and marking records when it was shown | M | Practice.pick interleaving tests; streak tests (a rest day keeps it); UI tests for Up next; tutor prompt test with a fake model |
| 4 | **Half-built Develop items** (§4 B4) | M | NOTES "Not done" items closed |
| 5 | **Own courses** (§5 C1) with PROTOCOL §13, Swift, JS, fixtures; campaigns and the course screen | M | `CourseTests` and campaign tests for own courses; interop fixture; no spinner for a course outside the catalogue |
| 6 | **Questions in the style of real papers** (§5 C2.3–C2.4, §C9): brief v1, structured output, code checks, check call, medium rewrite, tutor rule (§1.1) | L | Code-check tests on fixtures (passing and failing questions); generation tests with a fake model; the test set run once with your key, results logged |
| 6b | **The shared bank** (§C7): relay routes + PROTOCOL.md + tests; app reads the course file and searches it first; uploads, pending → good, flags | M | Relay tests: upload needs a vault device token, malformed and over-limit uploads refused, 2 flags remove, 3 clean attempts promote; app picks an unseen bank question before writing |
| 6c | **Overnight batches** (§C8), off until the relay has a key | M | Relay tests with a fake Anthropic batch API: submit, poll, collect, check, add as pending, cap respected |
| 7 | **Cards in Learn** (§4 B1) | S | Due cards in Up next |
| 8 | **Notes and the clipboard as learning tools** (§6): notes per topic and "New note for this topic"; Practise this on any note, PDF or sketch makes questions from it; lecture transcripts and "Make questions from this lecture" on the existing ink audio; "Save to a course" on a clip | M | A topic shows its notes; a note becomes questions with sources; a 30-minute recording transcribes on the iPad and its questions cite the transcript; a clip saved to a course appears under the topic |
| 9 | **Other kinds of practice and checkpoints** (§5 C3, C5) | M | Mastery tests for do-and-rate |
| 10 | Then the existing plans: cohort comparison, study with friends | — | — |

---

## 10. Decisions that are yours

**Decided (2026-11-04):**
- Q1: the section is **Learn**, and the app stays **Trove** (it can be renamed later, display name only).
- Q2: keep RSS feeds and add addresses, and hide the Telegram bot. That adds a `telegramBridge` flag to §3,
  which pauses existing Telegram bridges the way `githubBridge` pauses GitHub ones.
- Q3: the Markdown copy is off by default, with a setting (§3 A3).
- Q4: Haiku 5.5 writes the questions, when you tap, in the style of real papers (§C2.3).
- Q5: the Clipboard keeps its own iPhone tab.

- Q6: the relay's AI allowance is **10M tokens a month**. It's set as the Worker secret `AI_MONTHLY_LIMIT`
  on 2026-11-04, with no code deployed. Your own key has your own limits.
- Q7 (revised 2026-11-05 after the tests): **write at low, check at low, rewrite at medium only on failure**;
  switch to medium-first if more than half need the rewrite (§C2.3).
- Q8: **new vaults on the relay need an 8-digit code** (§7 E2). You set it yourself as a Cloudflare secret.

- Q9: **close copies of real questions are the goal** for GCSE and most of A-level: the same question, slightly
  different (§C2.3).
- Q10: **copyright is your call** (2026-11-05: "they cannot do anything if its not exactly the same"). Only
  exact or near-exact wording is refused. Decision 12's "get legal advice before a public launch" is
  superseded by this for the bank.
- Q11: **the shared bank** (§C7), with uploads private to your users' vaults.
- Q12: **overnight batches on the relay** (§C8), switched on when you add `ANTHROPIC_API_KEY` to the relay.

**Still open:** nothing.

**The original options, for the record:**
1. **The name of the section.** Options:
   - **Learn**: plain, fits "anyone learning anything". My pick.
   - **Study**: fits students, less so a guitarist.
   - **Practise**: the iPhone tab already uses it, but it's narrower: reading and listening aren't practice.
   - **Develop**: keep.

   The app can stay **Trove**: "a trove of what you've learned". If you want a new app name later, change
   the **display name only**:
   - New bundle ids would need five new App IDs (app, share, widgets, Safari, keyboard) out of the free
     Apple ID's 10 per week.
   - They'd also mean a fresh install that loses the Keychain and app group data (review R11).
2. **The rest of "etc."**: the Telegram bot, add addresses (Shortcuts) and RSS feeds. Hide them too, or keep
   them? My pick: keep RSS and add addresses (lecture feeds, Shortcuts), hide Telegram.
3. **The Markdown copy of your notes** in `<vault>/Notes` (Mac): keep it as a plain-file backup, or stop it
   with the Obsidian sync? My pick: keep it (it's what "your notes are plain files" means).
4. **Paid AI for question generation off the iPad** (the relay's allowance is your money): allowed when
   tapped, or iPad only?
5. **The iPhone tab bar**: Home, Learn, Notes, Search, with the Clipboard moved under Notes. Or keep the
   Clipboard as a fifth tab?
