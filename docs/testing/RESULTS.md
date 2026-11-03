# Test results (append-only)

One row per run. Never edit an old row; a re-run is a new row. Who: `Claude` (cloud session), `CI`
(GitHub Actions, with the run), or `you`.

| Date | Test | Build | Device and OS | Who | Result | Notes |
|---|---|---|---|---|---|---|
| 2026-11-03 | TroveCore suite (all `@Test`s, incl. every TroveCore test named in these files) | 678ea6c | Linux x86-64, Ubuntu 24.04, Swift 6.3.1 | Claude | pass | 211 tests |
| 2026-11-03 | TroveCore suite | f35b51d (local, before push) | Linux x86-64, Ubuntu 24.04, Swift 6.3.1 | Claude | pass | 219 tests (adds TroveGen, page index, ink-by-item) |
| 2026-11-03 | web unit + interop (`npm test`) | 7e79930 | Linux, Node | Claude | pass | 71 tests |
| 2026-11-03 | TEST-PERF-001 | bb65fc5 | Linux x86-64 VM, release | Claude | fail | p90 65.0 ms vs 5 ms budget (PERF_AUDIT B3); was 102.0 ms |
| 2026-11-03 | TEST-PERF-002 | bb65fc5 | Linux x86-64 VM, release | Claude | pass | 0.5 ms (was 113.0 ms) |
| 2026-11-03 | Apple apps build (TroveCore tests on macOS) | bb65fc5, run 132 | macOS 15 runner, Xcode 26.3 | CI | fail | a test expression too complex for Xcode's type checker; fixed in f35b51d |
| 2026-11-03 | website e2e `pdf.e2e.mjs` (TEST-PDF-002) | 3230952 and 7e79930, Tests runs 52–53 | ubuntu-latest, Chromium | CI | fail | flaky: Quote button not found within 30 s; failed on a NOTES-only commit too, passed at 678ea6c. Bug: NOTES.md "Known bugs" |
