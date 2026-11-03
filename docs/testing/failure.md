# Failure and recovery (FAIL)

Each test states the expected recovery.

### TEST-FAIL-001: Force-quit while editing
- **Feature**: saving
- **Priority**: critical
- **Coverage**: auto-tested (local database saves deltas)
- **Platforms**: iPhone, iPad, Mac
- **Preconditions**: a note open.
- **Steps**:
  1. Type `before-quit`; within 2 s force-quit from the app switcher (Mac: Activity Monitor → Force Quit).
  2. Reopen.
- **Expected**: the note holds `before-quit` (at worst the last second missing); it syncs out.
- **Failure looks like**: the note empty or older; a vault that won't open.
- **Automated by**: `LocalDatabaseTests/savesOnlyWhatChangedAndReopens`; device: manual.

### TEST-FAIL-002: Network lost during a sync
- **Feature**: sync retry
- **Priority**: critical
- **Coverage**: auto-tested (backoff, outbox)
- **Platforms**: all
- **Preconditions**: 50 new items not yet synced.
- **Steps**:
  1. Start a sync, turn off Wi-Fi halfway; turn it on after a minute.
- **Expected**: the next sync sends the rest; nothing duplicated; the error clears.
- **Failure looks like**: duplicates, an error that stays.
- **Automated by**: `SyncBackoffTests/backsOffWhenQuietAndResetsOnChange`, `OutboxTests/aConflictingSegmentIsNotRetriedForEver`.

### TEST-FAIL-003: Corrupt documents
- **Feature**: robustness
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: a corrupt zip, PDF and `.goodnotes`.
- **Steps**:
  1. Import each and open each.
- **Expected**: each becomes a file item; opening says it can't be shown; no crash.
- **Failure looks like**: a crash or a hang.
- **Automated by**: `ImportTests/rejectsCorruptData`, `GoodNotesInkTests/notANotebook`.

### TEST-FAIL-004: Invalid AI JSON and timeouts
- **Feature**: AI robustness
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: none (tests use a fake provider).
- **Steps**:
  1. Run the AIProvider tests.
- **Expected**: a cut-off answer is split and retried; a bad answer gives a plain message; nothing is saved from it.
- **Failure looks like**: garbage saved into items.
- **Automated by**: `AIProviderTests/cutOffAnswersAreSplitNotFailed`, `claudeReadsAPageAndExplainsFailures`.

### TEST-FAIL-005: Edits aimed at deleted or unknown ids
- **Feature**: stray records
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: none.
- **Steps**:
  1. Run the Library tests.
- **Expected**: edits to an id that was never an item make no empty item.
- **Failure looks like**: empty "Untitled" items appearing.
- **Automated by**: `LibraryTests/editsToUnknownIdsNeverMakeEmptyItems`.

### TEST-FAIL-006: Numbers that aren't real don't stop the app
- **Feature**: ink safety
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: none.
- **Steps**:
  1. Run the ink safety tests.
- **Expected**: NaN, ±∞ and huge numbers in ink records are ignored, not crashes.
- **Failure looks like**: a crash opening a notebook synced from elsewhere.
- **Automated by**: `InkSafetyTests/numbersThatArentRealDontStopTheApp`, `lassoMovesThatArentRealAreNotStored`.

### TEST-FAIL-007: Storage full
- **Feature**: disk errors
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPhone
- **Preconditions**: a nearly full iPhone (or skip).
- **Steps**:
  1. Import a large video.
- **Expected**: a plain "not enough space" message; existing data untouched.
- **Failure looks like**: a half-saved item, a crash, a damaged local database.
- **Automated by**: manual.
