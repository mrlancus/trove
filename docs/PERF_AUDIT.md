# Performance, battery, AI cost and UI: the audit

_Started 2026-11-03 (Part 2 of `docs/prompts/develop-perf-testing.md`). Kept current: every number
says how it was measured and at which commit. Words: **measured** (a number from a run, with its
source), **target** (a budget, not yet verified), **pending** (needs your device; the steps are given)._

Devices this has to be good on (from the prompt): **iPhone 14** (A15, 60 Hz, the slowest, so it sets
the bar), **iPad Air** (M-series, 60 Hz, Pencil, Apple Intelligence), **Intel MacBook Pro** (the
universal build; the Mac's worst case). None has a 120 Hz screen, so 16.7 ms per frame is the budget
your devices check; 8.3 ms still applies to code paths for ProMotion users.

What you've noticed (2026-11-03): scrolling laggy in many places, panning canvases/notebooks/PDFs
not smooth, opening items/notebooks/pages/documents slow to show content, more lag elsewhere.

---

## 1. What MASTER_PLAN already did, what was measured, what's still a guess

| Item | What was done | Measured? |
|---|---|---|
| P1 change feed | Search index and item list update only changed records | Unit-tested (`ChangeFeedTests`); **no time measured** in the app |
| P6 Spotlight memo | Indexes only what changed | Not measured |
| P7 thumbnails | Disk cache of small JPEGs | Not measured |
| P8 Mac clipboard watcher | 0.3/1/2 s adaptive, 25 % tolerance, sleeps with the screen | Not measured (wakeups need `powermetrics`, §7) |
| P9 sockets | 50 s pings, 5–10 min safety poll, pause on sleep | Not measured |
| P10 `segments/batch` | One request for up to 200 segments | Relay tests; request count per sync not measured in the app |
| P11 iCloud listing reuse | Reuses a device folder's listing while unchanged | Unit-tested; not timed |
| Battery round (PushCoalescer etc.) | 3-hour simulated session: 67 pushes vs 200 | **Measured** (simulation, `PowerPolicyTests`) |
| N1 TextKit 2 editor | Restyles only the edited paragraph | Not measured |
| Ink tiles, backdrop re-render | Renders once per settle | Not measured |
| Website benchmarks | `web/test/bench.mjs` with a 20 % gate | **Measured** in CI (website only) |
| TroveCore benchmarks | `Benchmarks.swift` (printed, not gated) | **Measured** on Linux, now on trove-gen's budget vault (§2) |

Everything app-side was a guess until this round: nothing in the apps had run under a measurement.

## 2. Workflows: budget, numbers, status

Budgets (hard limits, from the prompt): frame < 16.7 ms on your devices (8.3 ms on 120 Hz); tap to
feedback < 50 ms, to result < 100 ms; no main-thread hang over 100 ms; navigation: first content
within one frame cached, < 200 ms cold; search < 5 ms p90 per keystroke on 50k items + 50k clips;
typing in a 50k-word note: each keystroke's main-thread work within one frame.

Method L = TroveCore benchmark on Linux (cloud VM, x86-64, `swift test -c release`, `TROVE_BENCH=1`,
trove-gen `Size.full`: 50k items, 50k clips, 500 pages × 200 strokes, 10k-stroke whiteboard, 200
PDFs, a 500-page PDF; median of runs). Linux numbers aren't device numbers, but the same method
before and after shows whether a change helped, and an A15 core is in the same class as this VM's.

| Workflow | Platform | Budget | Baseline | Now | Status | Method, commit |
|---|---|---|---|---|---|---|
| Search, per keystroke (items) | core, all | 5 ms p90 | p50 34.1, p90 102.0, max 279.7 ms | p50 10.5, p90 **28.1**, max 67.4 ms | ❌ over budget (B3) | L, L1 commit (was 21.8/65.0/158.8 at bb65fc5) |
| Open one notebook page's ink (500-page notebook) | core, all | < 200 ms cold, 1 frame cached | 113.0 ms | **0.5 ms** | ✅ (core path) | L, notebookPage vs notebookPageIndexed |
| Open a notebook in the editor (decode every stroke) | iPad, iPhone, Mac | no hang > 100 ms | ~300 ms of decoding on the main thread (decodeAllStrokes 293.8 ms, L) | off the main thread (B4) | implemented, pending device | L + code, this commit |
| Materialise the vault (cold start without checkpoint) | all | launch < 400 ms (MASTER_PLAN) | recordStoreApply 4,951 ms for 243k ops | — | ❌ (only without a checkpoint; apps load SQLite + checkpoint) | L |
| Build the search index from scratch | all | background only | 7,526 ms | — | ⚠ must never be on the main thread (check B5) | L |
| Eraser hit test, one page | iPad | 1 frame | 9.9 ms for 100 points | — | ✅ | L |
| Partial erase | iPad | 1 frame | 1.3 ms | — | ✅ | L |
| Launch, cold and warm | all | < 400 ms to usable list | — | — | pending: CI launch test + your device (§6) | — |
| Library scroll | all | 0 hitches | — | — | pending: frames session (§6) | — |
| Item view open | all | < 200 ms cold | — | — | pending: Settings → Battery "Open Item" | — |
| Note typing (50k words) | all | 1 frame per keystroke | — | — | pending | — |
| Notebook pan/zoom/draw | iPad | 0 hitches, PencilKit-level latency | — | — | pending: frames session while writing | — |
| PDF open (500 pages) and scroll | all | < 200 ms first page | — | — | pending | — |
| File viewer | all | < 200 ms | — | — | pending | — |
| Clipboard palette open + type (Mac) | Mac | 1 frame, search < 5 ms | — | — | pending | — |
| Ask (UI only) | all | no hang | — | — | pending | — |
| Study | all | 1 frame | — | — | pending | — |
| Settings | all | 1 frame | — | — | pending | — |
| Sync of 50 segments | all | 1–2 requests | — | — | pending: CI count test | — |
| Import 1,000 files | all | progress, no hang | — | — | pending | — |
| Website: search per keystroke | web | 5 ms p90 | `bench.mjs` (CI gate) | — | measured in CI | `web/test/bench-baseline.json` |

"Pending" rows: the means to measure them landed in this round (§5). Collect them with §6.

## 3. Bottlenecks found

**B1. Benchmarks measured an unrealistic vault.** 30 words repeated everywhere; every note matched
every word. trove-gen now writes Zipf-distributed text over 20,000 words (`TroveGen.vocabulary`), so
common words match many notes and most match few, as in real writing. Evidence: the old search
numbers were 37 ms/keystroke on a vault where every query matched ~100 % of notes.

**B2. Opening one page read the whole notebook.** `Library.strokes(on:layer:pageKey:)`
(`Drawing/InkPages.swift`) built every stroke of the item and filtered by page, so reading
handwriting page by page through a 500-page notebook was quadratic. Fix: `RecordStore.inkByPage`
(an index by item, layer, page key), kept through moves, deletes, rebuilds and checkpoints, checked
against a scan by a randomized test (`InkPageIndexTests`). 113.0 → 0.5 ms (L). Also found:
`inkByItem` never forgot a stroke moved to another item (fixed in Swift and JS, with tests). Risk:
low (an index, same results). Verified: L benchmark + tests.

**B3. Search per keystroke is 13× over budget.** Typing two letters ("pl") stands for the 64
commonest words starting with them; with 50k notes that's ~42k candidates. `TermIndex.search`
checked each candidate against every query word (including the word the candidates came from) and
against all 64 prefix words, then again while scoring, with String-keyed dictionaries
(`Search/TermIndex.swift`). Fixed now: skip the lead word's check, look up from the smaller side
(doc terms or prefix list, same order so scores sum identically), skip filters when there are none:
p90 102 → 65 ms (L, bb65fc5). Then L1: documents numbered, postings carry term frequencies, the lead
word scored by walking its postings, a top-k heap: p90 65 → 28.1 ms, identical results and scores
(`SearchEngineEquivalenceTests` checks 300 random queries against scoring every doc the old way).
**Still over.** Tried and reverted: prefixes only from the third letter gave p90 26.3 ms (from 28.1),
too little for making two letters find nothing. What's left is words in most notes: in trove-gen's
Zipf text the commonest content words sit in 40–80 % of 50k notes, so a keystroke scores ~40k
candidates. Real notes are likely kinder (the commonest words are stopwords, already dropped), so
this vault is a worst case; your diagnostics export will tell. Next options, each a large change:
(1) score at most the 2,000 candidates with the highest lead-term frequency first and stop when no
later one can enter the top 100 (MaxScore-style bound; same results); (2) search on a background
actor and drop stale keystrokes, so typing never waits (P4: the budget is about blocking typing).

**B4. Opening a notebook decoded every stroke on the main thread.** `InkEditorModel` is
`@MainActor`; its ink reload (`Drawing/InkEditorModel.swift`, "Reload ink") turned every stroke into
an `InkLine` (decoding its points) on the main thread: ~300 ms for a 500-page notebook (L,
`decodeAllStrokes`), more on an iPhone, and again after every sync that pulled ink. Fix: the
decoding runs in a detached task at user-initiated priority, reusing unchanged lines as before; the
main thread only swaps the result in. **Large change note** (threading of a subsystem): what changes:
where `InkLine`s are built; risk: a sync landing while the detached task runs is applied by the next
reload (the same as before, since the old code also awaited the library between reading and
showing); rollback: revert the commit (one hunk). Verified so far: builds on CI; the hang it removes
should vanish from Settings → Battery → Lag ("Notebook"). Then: the page on screen is read from the
page index and shown first, before the rest of the notebook is decoded (`reloadInk`, first load only).

**B5. Suspects not yet measured** (reading the code finds suspects; only a measurement makes one a
bottleneck): `AppModel.reload()` builds full `Item` arrays for lists; `Links.graph` is O(all items)
on each run (off the main thread); SwiftUI lists over `[Item]` with full records (P2 rows not done);
`ClipsView` search key string built from every ephemeral clip; the Mac canvas's screen-resolution
cache; `InkBackdrop` re-render on settle; PDFKit thumbnails.

## 4. AI: cost audit and strategy

Every call site is listed in `docs/DEVELOP_PLAN.md` §A5 (trigger, route, model, effort, output
limit, caching). Findings:
- **Caching exists** on Ask (`AIResearch.swift:641`, automatic) and the notebook chat
  (`StudyChat.swift:288–290`, explicit breakpoint on the notebook plus automatic). It's **missing**
  on the relay (`server/src/ai.ts`), `AIProvider.complete` (actions, page reading, keywords) and the
  website. Haiku 5.5 caches from 512 tokens (Anthropic docs, read 2026-11-03); the relay's system
  prompt is shorter than that alone, so caching only pays where instructions + stable context pass
  512 tokens (handwriting page reading's instructions with the schema, keywords' instructions).
- **The relay counts cache reads as full tokens** against the monthly allowance (`ai.ts`
  `structured`), though they're billed at 0.1×.
- **No call runs without a user action or a setting the user turned on** (background reading and
  keywords are opt-in with a monthly money limit). Good; keep it.
- Instrumentation: `AIUsage` already records input, output and cached tokens, model, cost and
  purpose per request. Missing: a per-feature, per-month table and a cache hit rate in the AI
  activity window, and failed/retried calls.

Strategy (expected saving, trade-off, how measured):
| Technique | Saving | Trade-off | Measure |
|---|---|---|---|
| Cache breakpoints on stable instructions (`AIProvider.complete` for page reading, keywords, Develop marking) | **checked, not worth it now:** each of these prompts' stable part is under Haiku 5.5's 512-token minimum (page reading's instructions ~150 tokens, Develop marking's ~200, after a picture that changes each time), so the API wouldn't cache it. Revisit if the instructions grow. | — | `cache_read_input_tokens` in `aiusage` |
| Relay: count cache reads at 0.1 | allowance lasts ~1.5× longer for Develop (DEVELOP_PLAN B3.6) | relay change (L2) | relay test on `usage` |
| Routing table in one place (`DevelopAI.route`, existing tiers) | stops accidental Sonnet/Opus | none | activity window by model |
| Tight `max_tokens` + structured output for classification (keywords already; page reading 6,000 is generous) | fewer cut-offs, less output | must leave room for low-effort thinking | `stop_reason` counts |
| Batches for overnight jobs (Read all past handwriting, keywords) | 50 % off | results within 24 h, relay or app must poll; large change (L3) | cost per 1,000 items |
| Dedupe by content hash (keywords do already; page reading per stroke signature does) | — | — | already in place |
| On the device first (Vision, NaturalLanguage, Foundation Models on the iPad, Math Assist) | 100 % for those tasks | quality | eval set |

Quality guard: before changing a prompt or route, run the eval set (`DevelopEval`, DEVELOP_PLAN B3.5)
and compare agreement and cost.

## 5. Means to measure (step 0), landed this round

- **trove-gen** (`Packages/TroveCore/Sources/TroveCore/Gen/TroveGen.swift`): seeded vaults (`full`,
  `small`, `tiny`), raw ops for benchmarks, `writeFolderVault` for an unencrypted folder vault any
  device opens. Tests: `TroveGenTests`.
- **Diagnostics in the apps** (`App/Sources/Services/Diagnostics.swift`): a main-thread watchdog
  (100 ms pings while Trove is in front; hangs ≥ 100 ms with the workflow on screen), a frames and
  hitch counter (display link, only during a 10-minute session you start), "Screen" signposts and
  time-to-content per workflow (`.perfWorkflow`, `Diagnostics.ready`). Settings → Battery → "Lag and
  frames" shows them and **Export diagnostics** writes one JSON file (device, OS, hangs, frames,
  navigation times, the latest MetricKit payloads). Stored locally only, with an optional "Save a
  copy to the vault" (decision 15).
- **App test targets** (Mac unit/performance, iPhone and iPad UI tests) and the CI job that runs
  them: §9 below once they've built.

## 6. How to collect the pending numbers (your devices)

On the iPhone 14 and the iPad:
1. Install the newest build (SideStore or Sideloadly).
2. Use Trove normally for a day with Settings → Battery → Lag and frames → **Watch for lag** on.
3. For scrolling and panning: tap **Measure frames for 10 minutes**, then scroll the library, open
   a big notebook and pan and write, open a big PDF and scroll. Stop.
4. **Export diagnostics**, then share the file with me (or **Save a copy to the vault** and say so).

On the Intel Mac (Terminal, while reproducing a problem; paste the output back):
```bash
# Which Trove process
pgrep -x Trove
# 10 s of main-thread samples while it lags
sample Trove 10 -file ~/Desktop/trove-sample.txt
# Memory now
footprint Trove
# Trove's signposts and hangs as they happen (Ctrl-C to stop)
log stream --predicate 'subsystem == "com.mrlancus.trove"' --style compact
# Wakeups and energy for 60 s (needs your password)
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 12 | grep -E "Trove|Name"
# If it beachballs: a full stack report (needs your password)
sudo spindump Trove 10 -file ~/Desktop/trove-spindump.txt
```
Activity Monitor → Energy tab: note Trove's "Energy Impact" and "Avg Energy Impact" after an hour.

## 7. Battery

Already event-driven or batched: pushes (PushCoalescer), pings, clipboard polling, Spotlight,
widgets, background reading. New this round: the watchdog wakes 10 times a second only while Trove
is in front and stops in the background; the frame counter runs only in a session you start. To
check: `powermetrics` (above) with Trove idle in the background should show no watchdog wakeups.

## 8. Remaining work, by impact against risk

1. B3 search: integer doc ids and top-k (L1, large, below).
2. Notebook editor: visible pages first, the rest lazily (after B4).
3. P2 compact list rows (MASTER_PLAN): lists hold rows, not full records.
4. Measure the pending rows (§2) on CI and your devices; fix what misses.
5. AI: caching in `AIProvider.complete`; relay cache-read weighting (L2).

Large changes (made or planned), each with its rollback:
- **L0 (made): B4**, stroke decoding off the main thread. Rollback: revert the commit.
- **L1 (made): search engine on numbered documents with top-k; the saved index format is unchanged.** Changes `TermIndex` and its JS twin
  `core/search.js` together, with `search-cases.json`; the saved index format bumps (rebuilt once on
  first launch). Rollback: revert; the old format is rebuilt from the vault.
- **L2 (made, not deployed): the relay counts cache reads at 0.1 and cache writes at 1.25 (`meteredTokens`); caching its own instructions waits until they pass Haiku 5.5's 512-token minimum.** Changes the relay
  (`ai.ts`) and PROTOCOL.md §4 "AI" wording, with relay tests. Rollback: revert and redeploy.
- **L3 (planned): Message Batches for overnight AI jobs.** The app submits and polls with your own
  key (no relay state needed). Rollback: a setting.

## 9. UI audit

`docs/UI_AUDIT.md` (from the UI-test screenshots once the test targets run on CI).
