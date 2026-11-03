# Performance (PERF)

Every workflow in `docs/PERF_AUDIT.md` §2 has a test here against the "no lag" budgets. Numbers are
labelled **measured** (source, date) or **target** (not yet verified). A missed budget is a bug,
not a pass. How to read numbers: on your devices, Settings → Battery → Lag and frames → Export
diagnostics (`hangs`, `frameSessions`, `navigations`); on the Intel Mac, the commands in PERF_AUDIT
§6; on CI, `perf.json` and the summaries on the `ci-logs-tests` branch; on Linux, `TROVE_BENCH=1
swift test -c release -Xswiftc -enable-testing --filter Benchmarks`.

### TEST-PERF-001: Search per keystroke on the budget vault
- **Feature**: search
- **Priority**: critical
- **Coverage**: auto-tested (measured, not gated)
- **Platforms**: core (all)
- **Preconditions**: trove-gen `full`, seed 42.
- **Steps**:
  1. Run the Linux benchmark above.
- **Expected**: `searchKeyP90` < 5 ms (target).
- **Failure looks like**: measured 2026-11-03 at bb65fc5 (Linux VM, release): p50 21.8 ms, p90 65.0 ms, max 158.8 ms. **Fails the budget**: PERF_AUDIT B3.
- **Automated by**: `Benchmarks/coreHotPaths`.

### TEST-PERF-002: One notebook page's ink
- **Feature**: page index
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: trove-gen `full`.
- **Steps**:
  1. Run the Linux benchmark.
- **Expected**: `notebookPageIndexed` < 16.7 ms (one frame). Measured 2026-11-03: 0.5 ms (was 113.0 ms by the old path).
- **Failure looks like**: tens of milliseconds.
- **Automated by**: `Benchmarks/coreHotPaths`, `TroveTests/PerformanceTests/testOnePageReadsOnlyItsStrokes` (count).

### TEST-PERF-003: Cold and warm launch
- **Feature**: launch
- **Priority**: critical
- **Coverage**: implemented (CI launch test written; not yet run)
- **Platforms**: iPhone, iPad, Mac
- **Preconditions**: your vault; Trove not running.
- **Steps**:
  1. Launch Trove from the Home Screen; count until the library can be scrolled.
  2. Leave for 5 minutes, come back (warm).
- **Expected**: target < 400 ms to a usable list (MASTER_PLAN); no hang over 250 ms.
- **Failure looks like**: a spinner, an empty list that fills in late.
- **Automated by**: `TroveUITests/testLaunchTime` (simulator, trend only); device: manual.

### TEST-PERF-004: Scrolling the library
- **Feature**: lists
- **Priority**: critical
- **Coverage**: implemented
- **Platforms**: iPhone, iPad, Mac
- **Preconditions**: your vault (or `-TroveTestVault full`).
- **Steps**:
  1. Measure frames for 10 minutes; fling the library top to bottom five times; stop; export.
- **Expected**: hitches 0 in "Library" (target); worst frame < 33 ms.
- **Failure looks like**: hitches when thumbnails appear.
- **Automated by**: `TroveUITests/testLibraryScrollsAndShows` (simulator, works-check only); device: manual.

### TEST-PERF-005: Opening items, notebooks, pages and documents
- **Feature**: navigation
- **Priority**: critical
- **Coverage**: implemented
- **Platforms**: all apps
- **Preconditions**: Watch for lag on.
- **Steps**:
  1. Open 10 items, 3 notebooks, 3 PDFs; page through 20 notebook pages.
  2. Export diagnostics.
- **Expected**: `navigations` p90 < 200 ms per workflow; no hangs over 100 ms (targets).
- **Failure looks like**: blank flashes, hangs in "Notebook", "PDF", "Item".
- **Automated by**: manual.

### TEST-PERF-006: 30 minutes of continuous writing
- **Feature**: ink, battery
- **Priority**: high
- **Coverage**: auto-tested (push batching simulation)
- **Platforms**: iPad
- **Preconditions**: charged above 50 %, not charging.
- **Steps**:
  1. Note the battery %; write for 30 minutes; note Settings → Battery → This sketch counters and the %.
- **Expected**: pushes ~10, ink reloads ~0; drain within 2 % of writing in Notes with the Pencil (target).
- **Failure looks like**: pushes in the hundreds, a warm iPad.
- **Automated by**: `PowerPolicyTests/aThreeHourWritingSession` (simulation); device: manual.

### TEST-PERF-007: Idle for an hour
- **Feature**: wakeups
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: Mac
- **Preconditions**: Trove open in the background.
- **Steps**:
  1. Run the `powermetrics` command in PERF_AUDIT §6 for 60 s.
- **Expected**: Trove < 1 wakeup per second (target); no watchdog wakeups (it's off in the background).
- **Failure looks like**: several wakeups a second.
- **Automated by**: manual.

### TEST-PERF-008: Memory over a 3-hour session
- **Feature**: leaks
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPad, Mac
- **Preconditions**: none.
- **Steps**:
  1. Use Trove for 3 hours (notebooks, PDFs, library); every hour run `footprint Trove` (Mac) or note Settings → General → iPad Storage isn't memory, so on iPad export diagnostics (MetricKit memory) next day.
- **Expected**: memory flat within ~20 % after the first hour (target < 250 MB at 50k items on iPhone).
- **Failure looks like**: steady growth.
- **Automated by**: manual.
