# Question-writing tests, 2026-11-05: the first baseline

Haiku 5.5 wrote new questions in the style of real papers, at low and at medium effort, as subagents inside a
Claude Code session. Each agent read the real question paper and mark scheme PDF pages itself. Every output
was then marked by hand against the rubric below. Plan: §C2.3, §C9. The brief used was the forerunner of
`question-brief-v1.md` (v1 adds the rules this run showed were missing).

**No board text is in this file.** The papers are fetched from the catalogue's links when the tests run.

## The tests
| # | Catalogue docs (question paper / mark scheme) | Pages (qp / ms) | Asked for |
|---|---|---|---|
| 1 | `aqa-7408-1-2025-06-qp` / `-ms` (AQA A-level Physics) | 12–13 / 18–20 | one 8–10 mark question like 06: momentum, impulse, projectiles |
| 2 | `aqa-8461-1-h-2025-06-qp` / `-ms` (AQA GCSE Biology, Higher) | 2–5 / 8–10 | one question like 01 on a different disease |
| 3 | `ocr-h240-1-2025-06-qp-pure-mathematics` / `ocr-h240-1-2025-06-ms` (OCR A-level Maths) | 6 / 20–21 | one 9-mark question like 7: parametric tangents |
| 4 | `pearson-1ma1-1h-h-2025-06-qp` / `-ms` (Pearson GCSE Maths, Higher, non-calculator) | 3, 17 / 4, 6, 18 | two questions like 2 and 14: probability |
| 5 | `aqa-7405-1-2025-06-qp` / `-ms` (AQA A-level Chemistry) | 20–24 / 22–26 | one question like the electrode potentials one |
| 6 | `aqa-8145-1-2025-06-qp-paper-1-section-b-option-a-conflict-and-tension` / matching `ms` (AQA GCSE History) | 6–9 / 6–12 | two questions like 03 (account, 8) and 04 (essay, 16 + SPaG) |
| 7 | `cie-0625-41-2024-06-qp` / `-ms` (Cambridge IGCSE Physics) | 8–10 / 3–9 | one question like the lenses or waves one |

**Catalogue bug found**: AQA GCSE History lists five options of paper 1 with the same paper number, so pairing
a question paper with its mark scheme by paper number alone picks the wrong option. Pair them by the option in
the doc id.

## Rubric (each out of 5)
- Facts and numbers are correct (an error caps the score at 2).
- The same standard as the real paper.
- The board's own mark-scheme format.
- Guidance lines correct for the question's own numbers.
- The brief's rules followed: scope, no given-away answer, a consistent set-up.

## Results
| Test | Low | Medium |
|---|---|---|
| 1 A-level Physics | 3: the stem says the ball leaves horizontally, a later part says at 30° | 5 |
| 2 GCSE Biology | 4: a one-step percentage | 4: a two-step calculation |
| 3 A-level Maths | 5 | 5 |
| 4 GCSE Maths | 3: a guidance line copied from the real scheme names a colour that isn't in the bag | 4: a copied guidance value ("0.6") wrong for its numbers; good second question |
| 5 A-level Chemistry | 2: wrote one 2-mark part instead of a full question | 5 |
| 6 GCSE History | 5 | 5 |
| 7 IGCSE Physics | 3: the question states the object's position, then asks for it | 5 |
| **Total** | **25/35** | **33/35** |

- **No wrong fact or number in any of the 14.**
- **Time and tokens, averaged**: low 51 s and 72k tokens; medium 93 s and 84k. These figures include
  Claude Code's own tools and instructions, so only the difference (+12k, about +0.5p a question) means much.
- **Which code check would catch which flaw**:
  - test 5 low: the marks total;
  - test 4 (both): copied guidance;
  - tests 1 and 7 low: the check call, not code.
- **Earlier runs the same day** (one 12-mark momentum question, text examples, not real PDFs):
  - With a vague brief, low wrote easy one-dimensional questions twice. Medium and high wrote proper A-level
    ones.
  - With a specific brief, low reached A-level standard but printed an earlier part's answer.
  - So the brief mattered more than the effort level.

## Run notes
- Several agents broke the brief's "Read and Write only" rule by using `pdftotext`. Others made stray tool
  calls to Claude Code's session tools with empty or placeholder arguments. All were refused or did nothing,
  except one read-only environment listing.
- This won't happen in Trove: its question writer is a plain API call with no tools.
