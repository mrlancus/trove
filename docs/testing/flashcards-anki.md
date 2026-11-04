# Flashcards and Anki (CARD)

What exists: FSRS-5 cards from a note's `flashcards` field (`Model/Study.swift`), card records
`card.<note>.<sha12(front)>`, the Study sheet. Anki export (TSV with guids) is part of Develop's
first slice: its tests are TEST-CARD-010 on, written with the code.

### TEST-CARD-001: Review cards and see the next due dates
- **Feature**: FSRS
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all apps
- **Preconditions**: a note with 3 flashcards (TEST-AI-004).
- **Steps**:
  1. Item menu → Study these cards.
  2. Grade the first Good, the second Again, the third Easy.
- **Expected**: the buttons show times before grading ("10 min", "3 d"…); Again comes back in ~10 minutes; Good and Easy disappear for days.
- **Failure looks like**: cards repeating at once, no times on the buttons.
- **Automated by**: `StudyTests/newCardsStartWhereFSRSSays`, `intervalsGrowWhenRememberedAndShrinkWhenForgotten`.

### TEST-CARD-002: Reviews sync, and a card keeps its history when the answer is edited
- **Feature**: card ids
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all apps
- **Preconditions**: TEST-CARD-001 done.
- **Steps**:
  1. On another device open Study.
  2. Edit the back of a card (not the front); study again.
- **Expected**: the other device knows what was reviewed; the edited card keeps its schedule.
- **Failure looks like**: the cards new again on the other device.
- **Automated by**: `StudyTests/queueAndReviewsSync`.

### TEST-CARD-003: At most 20 new cards a day
- **Feature**: queue
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all apps
- **Preconditions**: a note with 30 new cards.
- **Steps**:
  1. Study all new cards.
- **Expected**: 20 new cards today; the rest tomorrow.
- **Failure looks like**: all 30, or fewer than 20.
- **Automated by**: `StudyTests/queueAndReviewsSync`.

## Built: Anki export (TroveCore)

### TEST-CARD-010: Anki TSV keeps GUIDs so re-importing updates
- **Feature**: AnkiExport.tsv
- **Priority**: high
- **Coverage**: auto-tested (file format); opening in Anki: not tested
- **Platforms**: core; Anki Desktop, AnkiMobile (you)
- **Preconditions**: two cards, one with <, tabs and a newline.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
  2. (You) Import the file into Anki Desktop, edit a card's back in Trove, export and import again.
- **Expected**: headers `#separator:tab`, `#html:true`, `#guid column:1`, `#tags column:4`; HTML escaped, newlines as <br>; the same GUID after editing; in Anki the second import updates, not duplicates.
- **Failure looks like**: duplicates in Anki, broken fields.
- **Automated by**: `DevelopTests/ankiExportKeepsGuidsSoReimportUpdates`; Anki: manual.

### TEST-CARD-011: The .apkg opens in Anki and re-import updates
- **Feature**: AnkiPackage
- **Priority**: high
- **Coverage**: auto-tested (package structure); in Anki: not tested
- **Platforms**: core; Anki Desktop, AnkiMobile (you)
- **Preconditions**: flashcards in Trove.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter AnkiPackageTests`.
  2. (You) Develop → Export cards for Anki (.apkg) → open it in Anki Desktop and AnkiMobile.
  3. Edit a card's back in Trove, export again, import again.
- **Expected**: a schema-11 collection with the Trove (Front/Back) note type, the Trove deck and one note per card; in Anki the deck appears; the second import updates the cards instead of adding copies.
- **Failure looks like**: Anki refusing the file, duplicates after re-import.
- **Automated by**: `AnkiPackageTests/aPackageHoldsTheCardsWithStableGuidsAndOpens`; Anki: manual.
