# Trove: Develop, no lag, cheap AI, and a full test plan

This is one prompt in three parts. No single session will finish it, so each part has a **stop
point**. A session does as much as it can, leaves the repo and NOTES.md so the next session can
continue, and ends with a short report of what it did and what's waiting on me.

## Before anything else: save the current `main`, then work on `main`

This prompt is my explicit permission to push to `main`, whatever branch the session was started on.

1. `git fetch origin` and check whether a branch named `archive/main-before-develop` already exists
   on `origin`. If it does, an earlier session has done this step: skip to the ground rules.
2. Otherwise save today's `main` exactly as it is on GitHub:
   ```bash
   git branch archive/main-before-develop origin/main
   git push origin archive/main-before-develop
   git tag -a pre-develop -m "main before the Develop, performance and testing work" origin/main
   git push origin pre-develop
   ```
3. If the session was started on another branch with commits of its own that aren't on `main`,
   merge them into `main` (no force-push), push, and say in NOTES.md that the branch is merged.
4. From then on, commit to `main` and push to `main`. Record the archive branch and tag in NOTES.md
   under "Manual steps" so I know how to get back to the old state.

**Never delete, move or force-push** `archive/main-before-develop` or the `pre-develop` tag, and never
force-push `main`. They are the way back if this work goes wrong.

## Ground rules (all parts)

- **Other sessions may be editing the code.** Run `git pull --rebase` before you start and before
  every push. Keep an **In progress** section in NOTES.md (create it if it's missing): add a line for your session (date, branch,
  part, the files you're working in) and remove it when you stop. Stay out of files that another
  line claims. Make small commits and push to `main`. Keep NOTES.md current.
- **The code is the source of truth.** Read `CLAUDE.md` and `NOTES.md` in full, then the parts of
  `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md`, `docs/MASTER_PLAN.md` and `docs/RESEARCH.md` that apply
  to your part, then the code. Where the docs and the code disagree, believe the code, fix the doc in
  a separate commit, and say what you fixed.
- **Don't ask me for permission. Decide and keep going.** That includes large changes, protocol and
  relay changes, migrations, restyles and every open decision in this prompt. Where something is my
  kind of decision, pick the option you'd recommend, build it, and log it in NOTES.md under
  **Decisions taken for you** (what you chose, the alternatives, why, and how to undo it). I'll
  overrule anything I disagree with later. Only three things still need me: spending money (a paid
  plan or service), deleting or overwriting my vault's data, and things only my devices can do. For
  this work, this overrides CLAUDE.md's "ask the user before decisions that are theirs".
- **Earlier decisions stand unless this prompt overrides them.** MASTER_PLAN.md §13 holds decisions
  I've already made. Where this prompt conflicts with one of them, choose, and log the choice as
  above (the known conflicts are listed under "Facts" below).
- **Be critical.** Don't agree with an idea just because I wrote it.
- **Nothing that exists today is lost.** No feature may be removed to make room for something new.
- **Never claim anything works, or got faster, without evidence.** Use the evidence words below.
- **Research with the web, not memory.** For provider docs, Anki formats and exam-board terms, cite
  the URL and the date you read it.
- **What each part may change:**
  - **Part 1 (Develop)** starts with a plan. It writes `docs/DEVELOP_PLAN.md` and fixes wrong docs. It
    changes no code itself. Once the plan is pushed, take your recommendation for every item in
    section F and start building Develop's first slice (roadmap section D) without waiting for me.
  - **Part 2 (performance, battery, AI cost, UI)** changes code. Fixes go straight in, one cause per
    commit, large ones included. For a **large change** (anything that changes PROTOCOL.md, the
    relay, the on-disk or synced format, or the threading model of a subsystem, or that touches more
    than about 300 lines), write a short note in `docs/PERF_AUDIT.md` first saying what changes, why,
    the risk and how to roll it back, then make it. Relay and protocol changes still follow
    CLAUDE.md: PROTOCOL.md, the tests, Swift, JS and fixtures in the same commit, with older clients
    left working.
  - **Part 3 (testing)** writes `docs/testing/`. From the moment it exists, every change adds or
    updates its tests in the same commit.
- **Order:** Part 1 first, ending with section F. Then Part 2 step 0 and Part 3's first files, then
  Develop's first slice and the rest of Part 2, in whatever order unblocks the most. Never wait for
  my answers. Everything Develop adds must meet Part 2's budgets and get Part 3's tests.

### Evidence words (use exactly these)

Each feature and each test has one **coverage level**:

- `implemented`: the code exists and nothing has been run yet.
- `auto-tested`: an automated test covers it and passes on Linux, in CI or in Playwright (link to
  the test).
- `manually tested`: a person ran it on a simulator or the website.
- `device-verified`: I ran it on a physical device (the device and OS are logged in RESULTS.md).
- `not tested`

Each **run** of a test has a result: `pass`, `fail` or `blocked` (couldn't run; say why). A feature
whose latest run failed keeps its coverage level and links to its bug. **Never record a pass because
the code looks right.** Anything that needs a physical device is mine to run: Pencil, palm rejection,
real iCloud between my devices, installs, GoodNotes on the iPad, battery, the share sheet, keyboards,
microphone and camera permissions. Say so on each of those tests instead of implying you ran it.

### Facts (checked in the code on 2026-11-03; re-check, they may have moved)

- **Navigation:** the iPhone has three tabs (Library, Clipboard, Search, in `PhoneViews.swift`). The
  iPad and Mac use a sidebar (`NavigationSplitView` over `AppModel.Selection`). Study opens as a sheet
  from an item's menu (`StudyView`). There's no tab bar on the iPad or Mac to add a tab to.
- **Measuring:** signposts exist (`App/Sources/Services/Perf.swift`). MetricKit reports are saved and
  shared from Settings → Battery (`MetricsReporter.swift`). There's **no** hang detector, no frame or
  hitch counter, **no app test target** in `App/project.yml`, and no `trove-gen` big-vault generator.
  `apps.yml` runs TroveCore's tests and builds the apps; it runs no app tests. So MASTER_PLAN Q2 and Q3
  aren't built yet, and nothing in the app has a measured number.
- **AI:** there's no prompt caching anywhere (no `cache_control` in the relay or the app). The relay's
  default model is Haiku, and its default allowance is 1,000,000 tokens per vault per month
  (`server/src/ai.ts`). The AI activity window is `AIActivityView.swift`.
- **Installs:** releases publish a SideStore source as well as `Trove.ipa` for Sideloadly.
- **Conflicts with MASTER_PLAN §13:**
  - Decision 1 says "Design: A Glass" and decision 9 says handwriting and maths AI stay on the device
    (cloud only through lasso → Ask), while NOTES.md says the design direction is still my choice.
    Develop's AI marking of handwritten work conflicts with decision 9.
  - Decision 4 stores diagnostics **in the vault** (encrypted, in a hidden folder) so a cloud
    session can read them. Part 2 §1 below asks for local-only storage with an export button.

---

# Part 1: Develop. Analysis, architecture and roadmap (plan first, then build)

**Stop point:** `docs/DEVELOP_PLAN.md` pushed and its section F logged in NOTES.md. Then go straight on
to building, as the ground rules say.

## Build on what exists

Develop must **extend** these parts, not run alongside them. Check each one in the code and say what
it actually does today:

- **Data and sync.** Everything is a record built from ops (per-field LWW on an HLC, diff3 for note
  text, conflict copies). Ops are cut into encrypted segments, synced over iCloud Drive and the relay,
  and E2E encrypted (TRV1). The JS port in `web/public/core` is kept in step with TroveCore by shared
  fixtures.
- **Connections.** `[[wikilinks]]`, hand-made `links`, `Links.graph`, backlinks, folders and
  auto-filing (`Organizer`), collections, and the `kind` vs `category` split.
- **Study.** FSRS-5 cards (`Study.swift`, card records `card.<note>.<sha12(front)>`, PROTOCOL.md
  §12), `StudyView`.
- **AI.** Ask and Ask this notebook (`StudyChat.swift`, `AIRules`, `StudyContext`, page pictures
  with grid sections, `AskTools.Budget`). AI actions such as cards and explain. The relay AI proxy
  with its monthly token allowance per vault. Bring-your-own-key providers (`AIProvider.swift`, with
  Fast/Smarter/Best tiers). The AI activity and costs window. On-device Foundation Models, which only
  the iPad has.
- **Handwriting and maths.** Vision recognition (`HandwritingPages`, with line boxes), Math Assist
  (`TroveCore/Math`), PDF marks, GoodNotes import and export, and `KeywordCache`.

## The vision

**Capture anything. Connect everything. Understand more. Develop real abilities.**

Trove began as a permanent universal clipboard and a connected knowledge workspace. Keep that, and
add a serious learning and skill-development pillar called **Develop**. Trove shouldn't become a
notes app with AI bolted on, and it shouldn't become a revision app. What makes it different is that
capture, notes, handwriting, AI explanation, problem solving, spaced repetition, progress tracking
and preparation for specific goals all live in **one connected system**. Using Trove should never
feel like switching between apps.

The goal isn't to help people store more. It's to help them **become more capable**.

### Four pillars, one system

- **Capture**: clipboard, photos, files, links, the share sheet, Safari.
- **Knowledge**: notes, handwriting, notebooks, documents, concepts.
- **Understand**: AI explanation, research, fact-checking, connections.
- **Develop**: practice, assessment, spaced repetition, mastery, preparation campaigns.

Map these onto the navigation that exists (three iPhone tabs, the iPad and Mac sidebar; see Facts).
Say whether Develop is a sidebar entry, a fourth iPhone tab, a mode of existing screens, or a mix,
and why. None of the pillars should feel like a separate app.

### Develop must handle many kinds of skill

The pillar covers more than exam revision:

- **Academic**: GCSE, A-level, IB, university maths, physics, chemistry, biology and computer
  science.
- **Competitive**: BPhO, UKMT, olympiads and university entrance exams.
- **Professional and technical**: programming, electronics, CAD and accounting.
- **Practical and creative**: languages, drawing, writing and music theory.

Not every skill can be assessed with questions or flashcards. Physics needs modelling and unfamiliar
problems. Programming needs code, tests and debugging. Languages need comprehension, writing and
speaking. CAD needs real models. Music needs recognition, performance and composition. The framework
needs pluggable **assessment methods** chosen per skill. Design that interface now (one Swift
protocol and its evidence output) and build only the method the first slice needs.

### The worked example the design must support

I photograph my teacher's whiteboard in a physics lesson. Trove saves the photo, reads it, suggests
the concepts it covers and links it to them. My handwritten notes, textbook pages and PDFs on those
concepts are linked too. Practice problems are linked to the same concepts and skills, and my
attempts and mistakes are recorded. Trove spots the gaps, suggests targeted revision and flashcards,
and updates my demonstrated mastery.

I can navigate every link in both directions: problem → class notes, photo → concepts, concept →
all resources, mistake → the underlying gap, skill → every piece of evidence, flashcard → the source
that made it.

AI suggests and maintains the links, and I can correct them. I should never have to build the graph
by hand. **Corrections are evidence too**: a link I reject stays rejected and isn't suggested again.

### Provenance

Keep these kinds of content distinct: original user content, extracted text (OCR and handwriting),
AI interpretations, official curriculum information, supplementary explanations, and explanations I
wrote. An uncertain AI reading must never silently become a fact. Low-confidence handwriting is
flagged and doesn't create knowledge objects.

### Practice-based spaced repetition (the most important new idea)

Anki is excellent at spaced recall of facts, and I don't want to rebuild it. I want the same
principles applied to **skills**: resolving forces on an incline, conservation of momentum, choosing
the right physical model, setting up a differential equation. Each skill keeps a record of
demonstrated performance, and Trove schedules chances to practise it again based on an estimate of
**the probability that I can apply the skill after a given delay**.

The evidence can include correctness, independence, reasoning quality, hint level used, time taken,
problem difficulty, how similar the problem is to earlier ones, time since the last success, and
whether the context was unfamiliar. How evidence should count:

- A hard problem solved alone is strong evidence.
- A small hint counts, but less.
- Heavy guidance means the skill needs work.
- Understanding a solution after failing triggers a later reassessment.
- Repeated failure after a delay triggers a look at the prerequisite concepts.
- **One success never establishes mastery.** It takes several problems in different contexts.

No arbitrary multipliers dressed up as an algorithm. Every constant the model uses is named, has a
stated reason, and can be changed in one place.

### Flashcards and Anki

Cards **complement** practice. Trove should spot gaps that recall fixes best, such as forgotten
definitions, misremembered equations, the conditions for using a formula, or two concepts I keep
confusing. It then drafts cards from my actual performance, and I review, edit and approve them.
Cards can also come from notes, images, PDFs, explanations and attempts.

Integrate with Anki rather than replacing it: export `.apkg` (ideally), CSV/TSV as a fallback,
import existing decks, and keep the links back to Trove sources. No lock-in.

### Progression

Track four separate dimensions:

- **Mastery**: demonstrated ability, weighted towards independent work.
- **Retention**: whether I can still do it now.
- **Coverage**: how much of a curriculum or skill set has actually been assessed.
- **Consistency**: how regularly I practise.

Past achievements stay even when retention drops. Trove should always be able to explain why it
thinks I'm proficient, in one sentence that names the evidence. No XP farming: a hundred trivial
questions mustn't beat a few genuinely hard ones. If there's XP, it sits on top of the mastery model.
Skill trees, milestones, personal records and challenge problems are fine where they reflect real
ability.

### AI: tutor, examiner, coach, researcher

- **Tutor**: explains, and gives progressive hints: (1) a nudge, (2) the relevant principle, (3) an
  approach, (4) the next step, (5) a full solution. Hints aren't punished, but they reduce
  independence credit.
- **Examiner**: marks against explicit criteria. It judges the reasoning as well as the answer,
  names wrong assumptions and missing steps, says exactly why each mark was lost, distinguishes the
  official requirements from extras, admits uncertainty, and never declares me exam-ready without the
  evidence.
- **Coach**: finds weaknesses and recommends what to practise.
- **Researcher**: explores concepts, sources and connections.

**AI produces structured evidence. Deterministic, transparent rules in the app turn that evidence
into mastery, progression and scheduling.** Every assessment records the question, my work, the
criteria, the AI's evaluation, its confidence, any corrections and the resulting change. Uncertain
assessments are flagged for my review and aren't counted as reliable evidence.

### Curriculum

Support exact qualifications, boards and versions, for example AQA versus Edexcel A-level Physics,
OCR Chemistry, university modules and BPhO. Ground everything in sources ranked in this order:
official specification, past papers and mark schemes, examiner reports, trusted resources, and AI
supplements. **AI never invents syllabus requirements.** Content is tagged as required,
prerequisite, extension, outside the specification, or uncertain. Specifications reference shared
knowledge objects rather than copying them, and they're versioned so that old assessments stay
valid.

### Preparation campaigns

Example: BPhO Round 1 in nine days. Pick the goal and deadline → find the requirements → run a
diagnostic → find strengths and weaknesses → estimate the time available → build a plan → recommend
problems and resources → track → reassess → estimate readiness from evidence. The plan adapts and
doesn't drill what I've already shown I can do. The same framework works for non-academic goals and
projects.

## Take a position on these (at minimum)

1. **The graph's shape.** I suggested four object types: Knowledge, Sources, Activities and
   Evidence. Is that right, or is it better to have fewer new record kinds plus typed, directed
   edges? Existing items already are Sources, so don't duplicate them. Say how links are stored,
   kept bidirectional, merged under the existing op/LWW model, and indexed for fast traversal.
   Consider whether edges should be their own records with deterministic ids (as cards are) or
   fields on the records they join, and what each choice does to concurrent edits.
2. **Concept identity.** Who creates concepts, and how are duplicates detected and merged when two
   devices both create "conservation of momentum" offline? How do near-duplicates ("momentum
   conservation") get merged later, and what happens to links pointing at the loser? How does a
   curriculum's concept relate to mine? What happens to links, evidence and cards when a source is
   edited or deleted?
3. **The mastery model with one user's data.** FSRS fits its parameters from thousands of reviews;
   a skill might see five attempts. Compare a modified FSRS (memory state per skill, with evidence
   weighting), Bayesian Knowledge Tracing, Elo/IRT-style problem difficulty, and simple hybrids.
   Cover priors, cold start, how problem difficulty gets estimated, and how we'd notice the model is
   wrong. Say whether mastery is **stored** or **derived** from evidence records on each device (a
   derived value can't conflict in sync). Recommend one, explain the trade-offs, and give **three
   worked numeric examples** (inputs → exact outputs) that become Part 3's test values.
4. **Where practice problems come from.** The worked example needs problems linked to skills. List
   the options (my textbook and photos of it, past papers I import, problems I write, AI-generated
   problems) and, for each, who checks the answer is right, what it costs, and what it means for
   copyright. AI-written problems with wrong answers are worse than none.
5. **AI marking reliability.** How do we measure it? For example, use a small set of my own attempts
   marked by hand as a regression eval. What happens when the AI disagrees with a mark scheme? Can
   handwritten working be assessed reliably from Vision output, or does it need page pictures, and
   what does that cost? Square this with MASTER_PLAN §13 decision 9 (handwriting AI on the device).
6. **AI cost of the loop.** Estimate the tokens and money for one marked attempt, one hint ladder,
   one campaign plan and one concept-linking pass on a photo, for each tier. Then estimate a normal
   week of revision and compare it with the relay's default allowance (1M tokens a month) and with a
   bring-your-own-key bill. Say what runs on the device instead.
7. **Curriculum content and copyright.** Exam boards' specifications, past papers, mark schemes and
   examiner reports are copyrighted. Can Trove ship any of it, or do I import my own copies? What
   does that mean for "official" data? Research the actual terms of AQA, OCR, Edexcel, WJEC/Eduqas
   and BPhO, and quote them; don't assume.
8. **Anki feasibility.** Cover the `.apkg` and `.colpkg` formats (SQLite in a zip, schema versions,
   media), stable GUIDs so that re-export updates cards instead of duplicating them, Anki's built-in
   FSRS and review log, and whether review history can come back into Trove. Say how this sits with
   the FSRS-5 cards Trove already has, and whether writing SQLite in a zip is feasible from TroveCore
   on every platform (and in the web app, if it gets this).
9. **Privacy.** Storage and sync are E2E encrypted, but content sent to AI routes is plaintext to
   the relay and the provider (PROTOCOL.md §4). Say exactly what each Develop feature would send,
   what can stay on the device (Vision, NaturalLanguage, Foundation Models on the iPad only,
   TroveCore code), and what the UI must say. Make no E2E claim the architecture can't back up.
10. **Schema and migration.** Every new record kind or field goes into PROTOCOL.md with Swift, JS and
    fixtures in the same commit. Older clients and the website must ignore what they don't understand
    without corrupting it (say how: does an older client's LWW write drop unknown fields?). Existing
    vaults must keep working untouched.
11. **Fit to reality.** This is a one-person project. There's no Apple Silicon Mac, the apps are
    built on GitHub Actions and reinstalled every 7 days, and only the iPad has Apple Intelligence and
    a Pencil. Say which device Develop is designed around first. The apps come first and the website
    gets things only where they're cheap. Cut or postpone whatever doesn't fit, and say so.
12. **What to cut.** Name the parts of this vision you'd drop, postpone or simplify, and why.

## Deliverable: `docs/DEVELOP_PLAN.md`

Aim for something I can read in about 40 minutes, and put the detail in appendices. Use Mermaid for
diagrams. Each section ends with "Decisions taken for you", or with nothing if there are none.

- **A. What exists**, limited to what Develop builds on: the data model, sync, encryption, Study, the
  graph, handwriting, and AI (every call site, provider and route, with its trigger and tier), each
  with file references. Don't redescribe what `docs/ARCHITECTURE.md` already gets right; link to it.
  List where the docs are wrong, and fix them in a separate commit.
- **B. Critical analysis**: what exists, what extends, what needs redesigning, what's new, where
  features conflict, the main risks, what's over-complicated, and what to postpone. Include your
  answers to the 12 points above.
- **C. Architecture**: the core data model (concrete record kinds, fields and edge types, written
  as a PROTOCOL.md draft); the knowledge graph; sources and provenance; the curriculum engine;
  problems and activities; the assessment pipeline; the mastery engine (as a pure function in
  TroveCore); skill scheduling; flashcards and Anki; campaigns; UI and navigation; privacy and sync;
  AI routing and cost. Show how the parts interact, with one diagram for the whole flow and one for
  the photo-to-mastery example. Keep the modules as folders and types inside TroveCore unless there's
  a real reason for more. No speculative abstraction layers.
- **D. Roadmap**: phases ordered by dependency, each with its scope, size (S/M/L as in
  MASTER_PLAN.md), what it unlocks, how it's tested, and what "done" means. Start with a thin end-to-
  end slice using **one** real A-level Physics topic: capture → concepts → problem → attempt → mark →
  evidence → schedule → card → Anki export. Then widen it. Nothing may be hard-coded to physics or to
  school. Say which parts of the slice can be proved on Linux and CI, and which need my devices.
- **E. UX**: how Develop actually feels on iPhone, iPad (with Pencil) and Mac. Use a few key flows
  as text wireframes: what's on screen, what's one tap away, and what's hidden. Answer "what should I
  do next?" in one place. No dashboards of statistics, and no managing the graph by hand. Use the
  existing components in `App/Sources/Views` (`Style.swift`, `Glass`). Keep the wireframes
  independent of the visual direction.
- **F. Decisions taken for you**: one consolidated, numbered list with what you chose for each, the
  alternatives, and what it would take to change it later. You build on these choices straight away.
  Include at least: which A-level Physics specification to use for the slice; where practice
  problems come from; how I get specifications and past papers into Trove; whether Develop data
  syncs to the website; AI budget defaults; on-device versus cloud marking (decision 9); and whether
  XP exists at all.

## Principles (check the plan against these before you push)

1. Everything is connected.
2. No duplicated information.
3. Original sources stay reachable.
4. AI output is always distinguishable from originals.
5. Progress reflects ability, not activity.
6. Practice matters more than generating flashcards.
7. Anki is integrated, not replaced.
8. Many subjects and skills, not one qualification.
9. AI is strict, honest and transparent.
10. No manual organisation required.
11. Existing Trove keeps working.
12. Modular, but not over-engineered.

---

# Part 2: Performance, battery, AI cost and UI quality

These are core requirements, not polish. They apply to all of Trove: what exists now and
everything Develop adds.

**Stop point for a session:** the measurement work in step 0 is in, `docs/PERF_AUDIT.md` is current,
and every row you can measure is green.
Rows that need my device numbers are marked pending, with the exact steps for me to collect them.

## Start from MASTER_PLAN

`docs/MASTER_PLAN.md` §2 (targets, P1–P18) and Q1–Q5; `docs/ARCHITECTURE.md`. A lot of
performance work has already landed (the change feed, adaptive clipboard polling, sleep handling,
`segments/batch`, the Spotlight memo, the thumbnail cache, TextKit 2 editing). The first job is a
table of **what was done, what was actually measured, and what is still a guess**. Expect most of the
app-side rows to be guesses: nothing in the app has run under a measurement yet (see Facts).

## Step 0: the means to measure (before any fix)

Without these, a fix has no before and after number, so they come first:

1. **Q2 `trove-gen`**: a seeded generator for big vaults (50k items, 50k clips, a 500-page notebook,
   a 10k-stroke whiteboard, 200 PDFs, one 500-page PDF), usable from TroveCore tests, CI and a
   debug-only "Load test vault" in the apps.
2. **Q3 app test targets** in `App/project.yml`: a unit and performance target for the Mac, and
   UI-test targets for an iPhone and an iPad simulator, run by `apps.yml`.
3. **On-device diagnostics**: a main-thread hang detector, a frame and hitch counter (CADisplayLink),
   and signposts around every workflow in the table below, added to the existing `Perf` and
   `MetricsReporter`. Show them in the existing Settings → Battery screen, with one "Export
   diagnostics" action. Choose where they are stored (local only, or the vault as decision 4 says)
   and log the choice.

## Budgets that define "no lag"

Treat these as hard limits. Where MASTER_PLAN's targets are stricter, the stricter one wins.

| What | Budget |
|---|---|
| Every frame while scrolling, animating, zooming, panning or drawing | Under 8.3 ms on 120 Hz devices (ProMotion iPad and iPhone), under 16.7 ms on 60 Hz. Zero hitches on my devices (measured by the hitch counter). |
| Main-thread work for any tap, click or keystroke | Under 50 ms to visible feedback, under 100 ms to the finished result. Anything slower shows progress at once and never blocks input. |
| Pencil stroke to ink on screen | No worse than plain PencilKit on the same device: Trove does no work of its own on the touch-to-ink path. |
| Typing in a note of any size (test 50k words) | No dropped keystrokes. Each keystroke's main-thread work stays inside one frame. |
| Navigating to any screen, item, notebook page or PDF page | First content within one frame where it's cached and under 200 ms cold, with no blank flash. |
| Search, as you type, over a 50k-item and 50k-clip vault | Under 5 ms p90 per keystroke, and results never block typing. |
| Main-thread hangs | None over 100 ms during use. Cold launch and the first open of a large document have their own budgets above; none of those may exceed 250 ms of blocked input either. |

If a budget can't be met somewhere, say where, why, and what the best achievable number is. Don't
quietly relax the budget.

## Where I see lag (a starting point, not the scope)

<!-- Be as specific as you can: device and OS, screen, what you did, how big your vault is, how it
felt. For example: "iPad Air M2, iPadOS 26.1: open a 40-page GoodNotes import, flick through pages,
each page goes blank for ~0.5 s." "Mac, Intel i5: typing in a long note stutters after ~2000
words." "iPhone: scrolling the library hitches when thumbnails appear." -->

- 
- 
- 

My devices: <!-- e.g. iPhone 15 (iOS 26.x), iPad Air M2 (iPadOS 26.x), Intel MacBook Pro 2019 (macOS 15.x) -->

If either list above is still empty, don't stop: measure everything, assume my oldest device is the
slowest one that runs iOS 18, and remind me in your final message to fill the lists in.

## 1. How to measure, given my setup

I have **no Apple Silicon Mac**, so there's no local Xcode and no Instruments on my devices. Don't
write a plan that relies on them. Use what actually works:

- **TroveCore on Linux**: benchmarks with `swift test` against `trove-gen` vaults for sync apply,
  merge, search, the index and the graph, in the existing benchmark gate.
- **GitHub Actions on macOS**: XCTest performance tests (`XCTClockMetric`, `XCTCPUMetric`,
  `XCTMemoryMetric`, `XCTStorageMetric`, `XCTOSSignpostMetric`, `XCTApplicationLaunchMetric`) and
  simulator UI tests for scrolling, navigation, opening notebooks and PDFs, and typing. Hosted runners
  are shared virtual machines, so timings are noisy and simulator frame times say little about a
  device. Gate CI on two kinds of check:
  - **Counts, which are deterministic**: SwiftUI body evaluations per edit, records decoded, files
    read, requests per sync, work done on the main thread per keystroke. These fail the build on any
    increase that isn't explained in the commit.
  - **Times, as trends**: the median of several runs, failing only on a regression of more than 20 %
    against the stored baseline (as MASTER_PLAN Q3 says).
  Frame and hitch budgets are judged on my devices, not in the simulator.
- **On my devices**: the step 0 diagnostics plus MetricKit (hangs, CPU and disk-write exceptions,
  energy, launch times). Nothing leaves the device unless I share it.
- **My Intel Mac**: the universal build runs on it. Give me exact Terminal commands to run while I
  reproduce a problem, and tell me what to paste back: Activity Monitor's Energy tab, `sample`,
  `spindump`, `footprint`, `log stream` filtered to Trove's signposts, and `sudo powermetrics` for
  wakeups and energy. An Intel Mac is slower than my other devices, so its numbers are a worst case.
- **The website**: Playwright with Chrome tracing.

For each workflow, record: frame times and hitches, main-thread time, CPU, memory and its growth,
launch time (cold and warm), navigation, search and query latency, notebook and PDF open time, Pencil
latency where it can be measured, and network and sync activity (requests and wakeups).

## 2. What to investigate: every workflow, not only the reported ones

List every user-facing workflow on each platform: launch, library, search, item view, note editor,
notebooks and canvas, PDF reader, file viewer, clipboard palette, Ask, Study and Develop, Settings,
sync, and imports and exports. Measure each one against the budgets, using `trove-gen` vaults and the
oldest device I have. In `docs/PERF_AUDIT.md`, give each workflow a row with its measured number,
budget and status. Every workflow that misses its budget is a bug.

Trace each cost back to its source in the code. Look for: main-thread blocking and synchronous file
or database I/O; SwiftUI invalidation storms (too much `@Observable`/`@Published` fan-out, views
rebuilt for no reason, expensive `body`); layout and image decoding at full size; large in-memory
objects and leaks (PDFDocument, GoodNotes parsers, ink tiles); database queries and indexes; search
indexing; timers, polling and sockets; background work that doesn't stop; sync overhead; drawing
canvas input latency and tile rendering; PDF rendering; AI work in the background; and anything that
runs during scrolling. Check each platform separately (iPhone, iPad, Mac, web). Reading the code
finds suspects; only a measurement makes one a bottleneck.

Pencil and handwriting are the most sensitive area. Drawing must stay smooth in big notebooks and
dense canvases, with no loss of stroke accuracy or rendering quality.

## 3. Battery

Look for anything that keeps the device awake: polling, unbatched requests, rendering when nothing
changed, repeated file access, background indexing, background AI, timers without tolerance, and
sockets that never sleep. Work should be driven by events where possible, batched when that doesn't
make the UI feel slower, cancellable, and always lower priority than what I'm doing. Re-check
MASTER_PLAN's battery targets against real numbers.

## 4. AI: useful, never forced, and cheap

**AI is optional.** Saving, notes, search, organising, maths and browsing knowledge all work
without it. Don't start AI conversations unprompted, don't make summaries nobody asked for, and
don't keep showing suggestions. AI should be one tap away wherever it helps, aware of what I'm
looking at so I don't have to explain, and invisible otherwise. I control which AI features are on
and how much they can spend.

Do this in order:

1. **Audit** every AI call site in the apps, TroveCore, the relay, the website and the extension.
   For each one, record what triggers it, the model and tier, the size of the system prompt and
   context, the output limit, whether it uses caching, how often it runs, and whether it could run
   locally or not at all. Use the existing AI activity log for real numbers.
2. **Research** the current official provider docs: Anthropic prompt caching (breakpoints, TTLs,
   minimum lengths per model), structured outputs and tool schemas, the token-count endpoint, and the
   Message Batches API for non-urgent work. Then the equivalents for the other bring-your-own-key
   providers (OpenAI, Gemini, OpenRouter), since users choose those too. Note which techniques need a
   relay change (batches are asynchronous, so the relay would have to hold and poll them); those are
   large changes, so note them in the audit before you make them.
3. **Write the strategy** in `docs/PERF_AUDIT.md`. For each technique, give the expected saving,
   the trade-off, and how it will be measured. Techniques to consider:
   - Retrieve only what's relevant, and never send whole notebooks or chats.
   - Put stable instructions first and dynamic content last, so the cache gets reused.
   - Route each task to the cheapest model that's good enough, with the routing table kept in one
     place.
   - Use structured outputs with tight `max_tokens` for classification and extraction.
   - Deduplicate by content hash, and never re-process unchanged content.
   - Reuse OCR, embeddings and keywords.
   - Size and crop images (page grid sections already exist), without making handwriting, equations
     or diagrams unreadable.
   - Run batch or background jobs only on Wi-Fi or when charging, with cancellation.
   - Do things locally where code is more reliable: maths, metadata, duplicates, rule-based tagging,
     validation.
4. **Instrument** calls, input, output and cache tokens, cache hit rate, model, cost per operation,
   per feature and **per vault per month** (Trove has one user per vault), and failed or retried
   calls. Show it in the existing AI activity window rather than a new screen.
5. **Guard quality.** Before changing a prompt or routing, build a small eval set from real tasks
   (kept in the repo, with no private content), and compare cost and quality before and after. Don't
   save tokens in ways that make answers noticeably worse.

## 5. UI quality and responsive layout

I want a clean, modern, calm interface with a clear hierarchy. Important things should be easy to
find, and rarely used controls reachable without taking up permanent space. That means no clutter,
no toolbars full of buttons, no deep menus, no walls of statistics, no tiny text, no uneven spacing,
and no desktop layout squeezed onto a phone.

- **iPhone**: focused, one task at a time, with navigation reachable by a thumb.
- **iPad**: use the space well for handwriting, split views and multitasking. Pencil comes first.
- **Mac**: larger windows, keyboard shortcuts, precise pointer use.
- **Web**: adapts properly to any browser width (secondary; fix only where it's cheap).

Layouts must hold up in portrait and landscape, when the keyboard is open, through rotation,
split-screen resizing, desktop window resizing and short heights. Check readability: type sizes and
Dynamic Type, line length, contrast, spacing, 44 pt touch targets, and density. Every feature,
including Develop, uses the same design language, navigation patterns, typography, spacing and
feedback.

Process: take simulator screenshots from the step 0 UI-test targets (iPhone SE and Pro Max, iPad
mini and 13-inch, both orientations, one Split View size, and the Mac at three window sizes, at the
default and the largest Dynamic Type) plus Playwright for the web. Review them in `docs/UI_AUDIT.md`,
listing clutter, discoverability and layout faults with a screenshot for each. Then propose the
fixes, then make them. For the visual direction (three mockups, NOTES.md "Design mockups"), go with
MASTER_PLAN §13 decision 1 (A Glass, glass on floating controls only) and restyle the apps to it.
Keep the colours, type and spacing in shared tokens so I can switch to B or C later in one place.

## Deliverable: `docs/PERF_AUDIT.md`, kept up to date

1. What MASTER_PLAN already did, what was measured, and what's still a guess.
2. A row for every workflow and platform: its baseline, budget, current number and status, with
   the method and commit for each number. Numbers I need to collect on my devices are marked as
   pending, with the steps to collect them.
3. Each bottleneck found: its symptom, the cause traced to `file:line`, the evidence, the fix, its
   risk, and how the fix was or will be verified.
4. The AI cost audit and strategy from §4.
5. The UI audit summary (with a link to `docs/UI_AUDIT.md`).
6. The remaining work, ordered by impact against risk, with the large changes (made or planned)
   listed separately, each with its rollback.

## Fixing: controlled steps until every row is green

Work down the list until every workflow meets its budget, then keep going on whatever is still
measurably improvable. Make one cause per commit. For each step, give the before and after numbers
by the same method. Where only my device can measure it, land the fix with a CI count that proves the
work went down, mark the row `implemented` and pending, and tell me what to measure. Run the
regression checks that matter here: no wrong data, no sync divergence, no lost ink or annotations,
undo and redo intact, consistent state, no new leaks, and no battery cost moved somewhere else. Add a
performance test for every fixed workflow so it stays fixed as the app grows.

---

# Part 3: The testing document (mandatory deliverable)

Start this alongside Part 2 and keep it current as work lands. The project isn't finished until
the final report (§6) exists and every critical and high-priority issue is either fixed or written
down.

**Stop point for a session:** the README, the device smoke run (§1) and the critical and high tests
for every area that exists today are written. Medium and low tests can follow in later sessions.

- Write tests from what the code **actually does**, not from what the docs or plans say. A feature
  that's planned but not built gets a `planned` heading in its file and no tests. Its tests are
  written in the same commit as the feature. The Develop, curriculum and Anki lists in §4 say what
  those tests must cover when the time comes.
- Write tests a person will actually run. A hundred vague tests are worth less than twenty exact
  ones.

## 1. Layout

- `docs/testing/README.md`: how to use the checklist, the evidence words, the area codes, and the
  device matrix.
- `docs/testing/SMOKE.md`: **the device smoke run**, at most 25 critical tests that take me under
  30 minutes, to run after each reinstall (every 7 days). Each one points to its full test.
- One file per area, with its code for test IDs:

  | File | Code | File | Code |
  |---|---|---|---|
  | `capture.md` | CAP | `curriculum.md` | CUR |
  | `notes.md` | NOTE | `flashcards-anki.md` | CARD |
  | `notebooks.md` (incl. handwriting) | NB, HW | `sync-privacy.md` | SYNC |
  | `pdf-images.md` | PDF | `performance.md` | PERF |
  | `graph.md` | GRAPH | `responsive.md` | RESP |
  | `ai.md` | AI | `failure.md` | FAIL |
  | `develop.md` | DEV | `regression.md` | REG |

- `docs/testing/RESULTS.md`: an append-only log with one row per run: date, test ID, build (commit,
  plus the CI run for app builds), device and OS, who ran it, the result (`pass`, `fail`,
  `blocked`), and notes or a link to the bug. The checklists hold the tests and the log holds the
  results, so a test can be run many times.

## 2. The format every test uses

Test IDs are `TEST-<CODE>-NNN`. Never renumber them; retire a test instead. Each test has these
fields:

- **Feature**
- **Priority**: critical, high, medium or low.
- **Coverage**: one of the evidence words.
- **Platforms**: iPhone, iPad, Mac, web.
- **Preconditions**: exact setup, including the size of any test vault and where its data comes
  from (a `trove-gen` seed, a fixture in the repo, or something I provide).
- **Steps**: numbered, exact, one action each.
- **Expected**: observable results.
- **Failure looks like**: specific symptoms.
- **Automated by**: the test file and name, or `manual`. Don't name a test that doesn't exist yet.

Vague tests such as "test handwriting", "check sync" or "make sure AI works" aren't acceptable. This
is the level of detail I want:

> **TEST-HW-001: Handwriting survives navigating away**
> - **Priority**: critical
> - **Coverage**: not tested
> - **Platforms**: iPad
> - **Preconditions**: a notebook with at least one page.
> - **Steps**:
>   1. Open the notebook.
>   2. Add a page.
>   3. Write five lines with Apple Pencil.
>   4. Open a different notebook.
>   5. Close the app from the app switcher.
>   6. Reopen the app and the first notebook.
>   7. Go to the new page.
> - **Expected**: every stroke is in the same place, with the same thickness and colour. Nothing is
>   missing or duplicated. The page shows in under ~0.5 s.
> - **Failure looks like**: missing or moved strokes, a changed stroke look, duplicates, or a blank
>   page that fills in late.
> - **Automated by**: manual (needs Apple Pencil).

## 3. What you may run

You can run TroveCore and relay tests on Linux, the web e2e tests in Playwright, and builds, XCTest
and simulator UI tests on GitHub Actions. Log each of those runs in RESULTS.md as yourself, with the
CI run link. Everything that needs a physical device is mine (see the evidence words).

## 4. Coverage

Every heading below gets concrete tests, for the parts that exist. Include the failure and edge
cases for each area, not only the happy path.

- **Capture**:
  - Copy text from several apps.
  - Save links, images, screenshots and files.
  - Clipboard history survives a restart.
  - Duplicates.
  - Search and retrieval.
  - Large histories (generated 10k+ clips).
  - Unsupported file types.
  - Permission denied.
  - Pause.
  - Hidden while screen sharing.
  - Safari, the share sheet and the Trove keyboard.
- **Notes**:
  - Create, edit and delete; Recently Deleted and restore.
  - Live formatting.
  - `[[links]]`, broken links, many links, backlinks.
  - Search.
  - Large notes.
  - Offline edits.
  - Sync.
  - Recovery after an interrupted edit.
  - Templates and Today's note.
  - Slash menu.
  - Maths after `=`.
- **Notebooks and handwriting**:
  - Notebooks and pages.
  - Each pen type and thickness.
  - Erasers and scribble-to-erase.
  - Shapes.
  - Undo and redo.
  - Lasso: copy, paste, move.
  - Zoom and pan.
  - Endless canvas and large canvases.
  - Stroke-heavy pages.
  - Page navigation and outline.
  - Persistence.
  - Import, export and round-trips with GoodNotes.
  - Palm rejection.
  - Rotation mid-stroke.
  - Keyboard and toolbar.
  - Math Assist.
  - Audio synced to ink.
- **PDFs and images**:
  - Import.
  - Large PDFs (500+ pages).
  - Annotate and save.
  - Search text and handwritten annotations.
  - Rotate, zoom, navigate.
  - Export as annotations.
  - Corrupt or unsupported files.
  - Forms.
- **The graph** (what exists now: wikilinks, links, backlinks, folders; the Develop parts when built):
  - A photo linked to several concepts, and several sources linked to one concept.
  - Problem to skill, and mistake to gap.
  - Both directions of every link.
  - Edit and remove links.
  - Duplicate concepts.
  - Correcting a wrong AI link, and the correction sticking.
  - Links when the source changes or is deleted.
- **AI**:
  - Ask about one note and about several sources.
  - Explain.
  - Generate cards.
  - Find gaps.
  - Suggest links.
  - Mark a solution.
  - Each hint level.
  - Ambiguous input.
  - Low-confidence handwriting.
  - API errors, rate limits, timeouts and going offline mid-request.
  - Switching models.
  - The monthly allowance and usage limits.
  - Bring-your-own-key providers.
  - **No call is made** when a feature that shouldn't call AI is used (checked in the AI activity
    log).
- **Develop** (when built):
  - Start a session.
  - Solve with no hints, with hints, and incorrectly.
  - Revisit a failed problem.
  - The same skill through a different problem.
  - Delayed scheduling.
  - Mastery and retention changes, with the exact expected values from the worked examples in
    DEVELOP_PLAN.md.
  - History kept.
  - Farming trivial questions doesn't raise mastery.
  - Uncertain marks go to review.
- **Curriculum and campaigns** (when built):
  - Choose a board and specification version.
  - Concept mapping.
  - Required versus supplementary.
  - Import past papers.
  - Marking against a mark scheme.
  - Create a campaign, change its deadline, re-plan after a diagnostic, reassess.
  - Missing or uncertain curriculum data.
- **Flashcards and Anki** (the FSRS-5 cards exist now; Anki when built):
  - Cards from notes and from mistakes.
  - Edit and approve.
  - `.apkg` export opens in Anki Desktop and AnkiMobile.
  - Import decks.
  - CSV/TSV.
  - Formatting and media.
  - Links back to the source survive.
  - Re-export doesn't duplicate.
  - Unsupported note types.
- **Sync and privacy**:
  - Mac, iPhone and iPad all converge.
  - The same item edited on two devices.
  - Conflict copies.
  - Offline, then reconnect.
  - Sync interrupted partway.
  - Large files.
  - Deletes propagate.
  - iCloud-only and relay-only paths.
  - The relay sees only ciphertext on every route except the ones PROTOCOL.md says carry plaintext
    (such as the AI proxy). Check this with a captured request for each route.
  - Items processed by AI are labelled. Extensions hold only the public key.
  - App lock.

## 5. Performance, cross-device and regression

- **Performance**: cold and warm launch, switching screens, scrolling large collections, searching
  large libraries, opening big notebooks and PDFs, 30 minutes of continuous writing, dense canvases,
  leaving and returning to the app, background sync, offline use, idle for an hour, and a 3-hour
  session (watching memory growth). Each test gives the exact setup (a `trove-gen` seed and size),
  the actions, the metric, how to read it on that platform (the diagnostics export, Intel Mac
  commands, CI XCTest output), the target, and the baseline from `docs/PERF_AUDIT.md`. **Label every
  number as measured (with source and date) or target (not yet verified).** Don't invent results.
  Every workflow in `docs/PERF_AUDIT.md` gets at least one test that checks it against the "no lag"
  budgets: frame time, input-to-feedback time, hangs over 100 ms, and navigation time. Any missed
  budget is logged as a bug, not a pass.
- **Cross-device and responsive**:
  - iPhone in portrait and landscape.
  - iPad in portrait and landscape, Split View and Stage Manager sizes.
  - A Mac laptop at small, medium and full window sizes, and on an external display.
  - The web at 360, 768, 1280 and 1920 px.
  - Touch, mouse and trackpad, keyboard and Pencil.
  - Rotating or resizing mid-task while editing a note, writing, reading a PDF, practising, and with
    a menu or contextual toolbar open.

  Each test checks for clipping, reachable controls, readable text and correct reflow.
- **Failure**:
  - Force-quit while editing.
  - Network loss during sync.
  - Storage full.
  - Huge imports.
  - Corrupt documents.
  - Invalid AI JSON.
  - AI timeouts.
  - Duplicate background jobs.
  - Interrupted export.
  - Simultaneous edits.
  - Rapid screen switching.
  - Deleting something that other items reference.
  - Editing a source after AI has processed it.

  Each test states the expected recovery.
- **Regression** (run before every release build):
  - A vault made by the current `main` opens after each change, and existing data migrates intact.
    Keep a small vault made by today's build as a fixture in the repo, so CI can check this.
  - Existing notebooks, notes, clips, saved items, imports and exports, and AI features all still
    work.
  - Sync still works with an older build on another device.

## 6. The final report (when the implementation is called complete)

`docs/testing/REPORT.md` covers:

1. A link to the complete checklist.
2. The tests you executed, and how.
3. The tests still waiting on me.
4. The latest result of every executed test, from RESULTS.md.
5. Known bugs, with their priority.
6. Unresolved risks.
7. Performance measurements compared with the baselines.
8. The devices and OS versions tested.
9. Features that are implemented but not fully verified.
10. Recommended next steps.

Every feature appears with its coverage level.
