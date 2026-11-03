# Develop (DEV)

## planned: the practice loop in the apps
Not built yet (DEVELOP_PLAN §D phase 2). When built, the tests must cover: start a session; solve with
no hints, with hints, and incorrectly; revisit a failed problem; the same skill through a different
problem; delayed scheduling; history kept; uncertain marks go to review; practise with AI switched
off from start to finish (questions, show the mark scheme, self-mark, evidence recorded, no AI call in
the activity log); the source line hidden until asked for, then right; AI marking includes the
matched mark scheme and says so when there isn't one.


## Built: Develop's first slice in TroveCore (2026-11-03)
No app screens yet; these run on Linux and in CI. Values are DEVELOP_PLAN Appendix B's worked examples.
TEST-DEV-004, 005, 006, 009 and 011 are filed in their areas as TEST-GRAPH-010, 011, 012, TEST-CUR-001 and TEST-CARD-010.

### TEST-DEV-001: The mastery model's worked examples come out exactly
- **Feature**: Mastery.evaluate
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core (Swift), web (JS)
- **Preconditions**: `Fixtures/mastery-cases.json` (6 cases).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`; `cd web && npm test`.
- **Expected**: one unaided standard success: ability 0.4000, mastery 0.5987, stability 3.1262, next practice in 5 days; after the approach hint: ability 0.0000, mastery 0.5000, next in 2 days; 100 easy problems: not assessed (all trivial); three hard problems from two+ sources: ability 1.4042, mastery 0.8029, proficient; a later AI-marked 25 %: ability 0.2225, mastery 0.5554; unmarked or uncertain: no evidence. Swift and JS identical.
- **Failure looks like**: any value off in the 4th decimal; Swift and JS disagreeing.
- **Automated by**: `DevelopTests/theWorkedExamplesComeOutExactly`; `web/test/develop.test.mjs` "the worked examples come out exactly as in Swift".

### TEST-DEV-002: One success is never mastery; failure routes to reassessment and prerequisites
- **Feature**: proficiency rule
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: one hard success: not proficient, and the sentence says how many more are needed; a failure after the full solution: due the next day; two failures a day or more after the last success: prerequisites flagged.
- **Failure looks like**: proficient after one success.
- **Automated by**: `DevelopTests/oneSuccessIsNeverMasteryAndWhySaysWhy`.

### TEST-DEV-003: Develop ids are stable across devices
- **Feature**: ids
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core, web
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`; `npm test`.
- **Expected**: the same name gives the same concept id; symmetric edges have one id either way; ids match between Swift and JS.
- **Failure looks like**: two ids for one concept.
- **Automated by**: `DevelopTests/idsAreStableAndSlugsFold`; web "ids and slugs match TroveCore".

### TEST-DEV-007: Practice picks: seeded, fresh, filtered, weighted to what's needed
- **Feature**: Practice.pick
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: 40 generated problems over two skills.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: the same seed gives the same questions; a different seed different ones; a problem done in the last 3 days isn't offered; marks and skill filters respected; the never-practised skill comes up in over half of 200 single picks.
- **Failure looks like**: repeats, ignored filters, the same picks for every seed.
- **Automated by**: `DevelopTests/practicePicksAreSeededFreshAndFiltered`.

### TEST-DEV-008: Hard means hard to solve, and AI routing never picks a dearer model
- **Feature**: Difficulty, DevelopAI.route
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: GCSE is never hard (even 12 marks); A-level only with a national average under 35 % or Trove's own estimate ≥ 1.0 from 5+ attempts; competition hard; routing: Haiku 5.5 low, medium only for hard or a re-check of an uncertain mark.
- **Failure looks like**: marks or length making a question hard; any route not Haiku.
- **Automated by**: `DevelopTests/hardMeansHardToSolveNotLongOrManyMarks`.

### TEST-DEV-010: A paper splits into questions with marks and diagrams, and matches its mark scheme
- **Feature**: PaperSplitter
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: a paper written for the test in AQA's layout (no board text).
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: keys 1, 1.1, 1.2, 2.1 with marks –, 1, 3, 2 and parents; 1.2's region runs to the page's end so its figure comes with it; scheme entries 1.1, 1.2, 2.1 found by key.
- **Failure looks like**: merged or missing questions, marks on the wrong part.
- **Automated by**: `DevelopTests/aPaperSplitsIntoQuestionsWithMarksAndMatchesItsScheme`.

### TEST-DEV-012: The thin slice end to end with no AI
- **Feature**: photo → concepts → problem → attempt → mastery → card → Anki
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: none.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: the photo's text suggests Momentum and Conservation of momentum; the catalogue question is picked; a self-marked 2/3 gives mastery σ(0.8 × (2/3 − 0.5)); the gap and the card link back both ways; the TSV holds the card's GUID; nothing shows as a library item.
- **Failure looks like**: any link one-way; Develop records showing as notes.
- **Automated by**: `DevelopTests/photoToConceptsToPracticeToMasteryToAnki`.
