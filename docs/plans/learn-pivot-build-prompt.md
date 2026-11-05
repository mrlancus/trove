# Build Trove for learners: the prompt for a new session

Saved 2026-11-05. Paste this into a new session: **"Read `docs/plans/learn-pivot-build-prompt.md` and do it."**

---

You're building everything in `docs/plans/learn-pivot-plan.md`. The plan is the source of truth. This page
says how to work.

## 1. Read first, in this order
1. `CLAUDE.md` and `NOTES.md`.
2. `docs/plans/learn-pivot-plan.md`: the whole plan. §9 is the order of work and §10 the decisions,
   all taken.
3. `docs/plans/learn-pivot-review.md`: what was checked and fixed. Don't reintroduce those mistakes.
4. `docs/plans/question-brief-v1.md` and `docs/plans/learn-pivot-effort-tests.md`: the question brief and
   the test baseline.
5. As each step needs them: `docs/DEVELOP_PLAN.md`, `docs/PROTOCOL.md` (§2, §4, §10, §13),
   `docs/ARCHITECTURE.md`, `docs/CATALOGUE.md`.

## 2. Check before you start
- **Another session may be working on the code.** Look at NOTES.md "In progress" and the latest commits on
  `main`.
  - If another session is listed, or `main` moved in the last hour, write your name and the step in "In
    progress" and push that first.
  - Then pull before every commit, and keep commits small, so the two of you don't collide.
- **Already done**: the relay's monthly AI allowance is 10M tokens. It's the Worker secret
  `AI_MONTHLY_LIMIT`, set 2026-11-05. Don't put it in `wrangler.jsonc`, because a var and a secret with the
  same name clash.
- The plan was written at `main` 4eb66b8. Where the code has moved on, the code wins: fix the plan in the
  same commit, and say so in NOTES.

## 3. Ground rules
- **Don't ask for permission.** The decisions are made (plan §10). Log every new choice you make for the user
  in NOTES.md's decisions list, with how to undo it.
  - Ask only about things that are the user's by CLAUDE.md: a name, anything that costs money, the design
    direction. And only if the plan doesn't already answer it.
- **Commit after each working step and push to `main`.** Keep NOTES.md current: what's done, what's next, and
  the user's manual steps. A fresh session must be able to "read NOTES.md and continue".
- **Tests ship with the code, in the same commit**:
  - TroveCore: `swift test`, on Linux with `/opt/swift` if it's installed.
  - Web: `npm test` and the e2e.
  - Relay: its own tests.
  - Device test cases in `docs/testing/` (TEST-… ids, as the existing files do).
  - **Never skip, delete or weaken a test to get green.** Tests for hidden features keep running with the
    flags switched on (plan §3 A1).
- **The apps are never compiled here.** They're built on GitHub Actions (NOTES.md: `apps.yml`, then
  `app-tests.yml`, logs on the `ci-logs` and `ci-logs-tests` branches). After each app change, push, wait
  for the build, read the errors and fix them until it's green.
- **Swift 6 strict concurrency; iOS 18 and macOS 15 targets.** Foundation Models, SpeechAnalyzer and Liquid
  Glass go behind `#available(iOS 26, macOS 26, *)`. TroveCore stays free of UIKit, AppKit and SwiftUI.
- **The relay** (`server/`) changes only where the plan says:
  - the 8-digit vault code (§7 E2);
  - the shared bank (§C7);
  - overnight batches (§C8).

  PROTOCOL.md and the relay tests change in the same commit. Older apps must ignore anything new.
- **Never deploy the relay or the website** (`npx wrangler deploy`) unless the user says "publish". Building
  and testing locally with `wrangler dev` is fine.
- **Secrets**:
  - Never in the repo, a log or a chat.
  - The user sets `VAULT_CREATE_CODE` themselves. Tell them how: Cloudflare dashboard → Workers →
    trove-relay → Settings → Variables and Secrets, or `npx wrangler secret put VAULT_CREATE_CODE`.
  - Batches need an `ANTHROPIC_API_KEY` secret on the relay. That's the user's money, so build batches
    switched off until it exists, and list it as a manual step.
- **Hide, don't delete** (plan §3): no code is removed, and nothing hidden runs in the background.
- **Apps first, Apple frameworks first.** The website only syncs the new formats and hides the same features
  (plan §8).
- **Copyright**: the boards' papers and specifications are never committed or shipped. Tests that need them
  fetch them with a script, as `RealPaperSplitTests` does.

## 4. The AI parts
- **Model**: Haiku 5.5, `claude-haiku-5-5`. Effort goes in `output_config.effort`:
  - **low** to write questions and to check them;
  - **medium** only for the one rewrite of a question that failed (plan §C2.3, decision Q7).

  Thinking is adaptive (Haiku 5.5's default). Never send `temperature`, `top_p`, `top_k` or `budget_tokens`.
- **Structured output** with `output_config.format` and a JSON schema, as in `question-brief-v1.md`. Parse it
  into `Codable` types in TroveCore.
- **Prompt caching**: the brief and a topic's examples are the stable prefix, so put `cache_control` on them.
  A Haiku 5.5 cached prefix needs at least 512 tokens.
- **Where calls go**:
  - On the device, through the user's own key (`AppModel+OwnAI.swift` / `AIClient`), every call logged
    in Activity.
  - The relay's AI is the fallback. It has no key today.
- **Batches** (plan §C8):
  - The Message Batches API: `POST /v1/messages/batches`, poll until `processing_status` is `ended`, then
    read the results by `custom_id`, in any order.
  - 50% off; most finish within an hour, all within 24 hours.
  - Relay only, on a Durable Object alarm, with a nightly cap.
- **The question writer has no tools.** It's one API call that returns JSON, plus one check call.
- **Check the API reference when you write this code.** The `claude-api` skill, or the docs it links, has
  the request shapes. Don't write them from memory.

## 5. Order of work (plan §9)
Do the steps in order. Each step is finished when its "Done when" column is true, CI is green, and NOTES.md
is updated.

| Step | What | Plan |
|---|---|---|
| 0 | NOTES pointer to the plan + the decisions; README, `CLAUDE.md` first line and `docs/RESEARCH.md` pitch lead with learning; "Develop" renamed to **Learn** in the UI | §9 step 0, §10 Q1 |
| 1 | Hide: `Features` (with test overrides), every entry point and background start, GitHub and Telegram bridges paused, the website; the Markdown copy off by default | §3 |
| 2 | Location recording off by default (`recordPlaces: false` written on new vaults) | §7 |
| 2b | The 8-digit code to create a vault (relay, PROTOCOL, tests, website + app field) | §7 E2 |
| 2c | The specification with each course: catalogue finders, download, spec statements. Also fix the catalogue bug in `learn-pivot-effort-tests.md`: history options paired by option | §C6 |
| 3 | Navigation (sidebar, iPhone tabs Home · Learn · Library · Clipboard · Search), Home, first launch | §4 B1–B3 |
| 4 | Half-built Develop items: spec topics, thumbnails of working, the rest on `Theme` | §4 B4 |
| 5 | Own courses, campaigns and course screen for them | §C1 |
| 6 | Questions in the style of real papers: brief v1, structured output, code checks, check call, medium rewrite, tutor rule; then the test set run and logged | §C2.3, §C9, §1.1 |
| 6b | The shared bank (relay routes, course files, uploads private to vault devices, pending → good, flags) | §C7 |
| 6c | Overnight batches on the relay, off until the key exists | §C8 |
| 7 | Cards in Learn | §4 B1 |
| 8 | Lecture transcripts and "Make questions from this lecture", on the existing ink audio | §6 |
| 9 | Other kinds of practice (`format` field) and checkpoints | §C3, §C5 |
| 10 | Then: national-cohort comparison, then study with friends (their prompt) | `docs/prompts/study-with-friends.md` |

**The test-set run in step 6**: use the user's key if they've given one. Otherwise, run it the way
`learn-pivot-effort-tests.md` did, with Haiku subagents reading the real PDFs, and say so in the log. Score it
with that file's rubric, then add the results as a new section there. If more than half of the low questions
needed the medium rewrite, switch writing to medium (decision Q7) and log it.

## 6. Done means
- Every step's "Done when" is true, and the Apple apps and the tests are green on CI.
- NOTES.md says:
  - what's built and how it was tested;
  - what to try on the iPad, iPhone and Mac;
  - the decisions you took;
  - the user's manual steps: set `VAULT_CREATE_CODE` (until it's set and deployed, the relay still accepts
    new vaults from anyone), add `ANTHROPIC_API_KEY` for batches, and say "publish" to deploy the relay and
    website.
- **Nothing deployed** until the user says "publish".

## 7. If you run out of time
Commit what works, at a point where tests pass. Write in NOTES.md "In progress" exactly where you stopped: the
step, what's done in it and what's next. The next session continues from there.
