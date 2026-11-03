# Notes (NOTE)

The live Markdown editor (`LiveMarkdownEditor`, TextKit 2), wikilinks, templates, Today's note,
checklists, the slash menu, maths after `=`, Recently Deleted. PROTOCOL.md §12.

### TEST-NOTE-001: Create, edit and find a note
- **Feature**: notes
- **Priority**: critical
- **Coverage**: auto-tested (core); app UI: not tested
- **Platforms**: Mac, iPhone, iPad, web
- **Preconditions**: a vault.
- **Steps**:
  1. Add → New note. Type the title `Smoke note` and the body `quantum walrus 42`.
  2. Go back to the library.
  3. Search `walrus`.
- **Expected**: the note is in the library at once and is the top hit, with `walrus` marked in the snippet.
- **Failure looks like**: the note missing, the search not finding it, the body lost.
- **Automated by**: `LibraryTests/notesLinksDedupeAndSearch`; website `ui.e2e.mjs` "set up with a code, browse, capture, edit…".

### TEST-NOTE-002: Live formatting while typing
- **Feature**: N1
- **Priority**: high
- **Coverage**: auto-tested (styling rules: `MarkdownSyntaxTests`); typing feel: not tested
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: an empty note.
- **Steps**:
  1. Type `# Heading`, Return, `- one`, Return.
  2. Type `**bold**` and `[ ] task`.
  3. Undo three times, redo three times.
- **Expected**: the heading styles as you type; Return after `- one` starts `- `; bold styles; the
  checkbox renders; undo/redo step back and forward exactly.
- **Failure looks like**: dropped or doubled characters, the cursor jumping, undo eating more than one step.
- **Automated by**: `MarkdownSyntaxTests/headingsQuotesAndLists`, `inlineStyles`, `wikilinkAutocompleteAndListContinuation`; feel: manual.

### TEST-NOTE-003: `[[links]]` and backlinks, including a broken link
- **Feature**: wikilinks
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: notes `Alpha` and `Beta`.
- **Steps**:
  1. In Alpha type `see [[Beta]] and [[Gamma]]`.
  2. Open Beta.
  3. Open Alpha's Connections.
- **Expected**: Beta's Connections lists Alpha under "Mentioned in"; Alpha shows Beta as linked and
  Gamma as not existing yet (tapping it offers to make it).
- **Failure looks like**: no backlink, Gamma linking to something random.
- **Automated by**: `OrganizeTests/linksMatchTheSharedCases` (`Fixtures/links-cases.json`, also run by the website).

### TEST-NOTE-004: Today's note is the same note on every device
- **Feature**: daily note
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: two devices on the vault, no daily note yet today.
- **Steps**:
  1. Tap Today on the Mac, type `from mac`.
  2. Tap Today on the iPhone.
- **Expected**: one note `daily-yyyy-mm-dd` with `from mac`, not two notes.
- **Failure looks like**: two Today notes, or the template written twice.
- **Automated by**: `NotesTests/libraryDailyNoteTemplatesAndTicks`; website `notes.e2e.mjs`.

### TEST-NOTE-005: Delete, then restore from Recently Deleted
- **Feature**: N11
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: `Smoke note`.
- **Steps**:
  1. Delete it.
  2. File menu (or Settings → Vault) → Recently Deleted → Restore.
- **Expected**: the note is back with its body and links.
- **Failure looks like**: not listed, restored empty.
- **Automated by**: `TrashTests/deletedItemsComeBack`.

### TEST-NOTE-006: Edits made offline on two devices merge
- **Feature**: text merge
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: Mac + iPhone
- **Preconditions**: a note with three lines `a`, `b`, `c` on both devices.
- **Steps**:
  1. Turn off Wi-Fi on both.
  2. Mac: change line 1 to `a-mac`. iPhone: change line 3 to `c-phone`.
  3. Turn Wi-Fi back on; wait a minute.
- **Expected**: both show `a-mac`, `b`, `c-phone`.
- **Failure looks like**: one edit lost; a conflict for edits that didn't overlap.
- **Automated by**: `SyncTests/concurrentTextEditsMergeOrBecomeConflicts`; devices: manual.

### TEST-NOTE-007: Typing in a 50,000-word note keeps up
- **Feature**: large notes
- **Priority**: high
- **Coverage**: not tested (budget: each keystroke within one frame)
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: a note of 50,000 words (paste `TroveGen` text, or any long text).
- **Steps**:
  1. Settings → Battery → Measure frames for 10 minutes.
  2. Type 200 characters at the end and 200 in the middle as fast as you can.
  3. Stop and export diagnostics.
- **Expected**: no dropped characters; no hang over 100 ms in "Item"; hitches near 0.
- **Failure looks like**: letters arriving in bursts, hangs logged.
- **Automated by**: manual.

### TEST-NOTE-008: Maths after `=`
- **Feature**: N10
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: a note.
- **Steps**:
  1. Type `x = 3`, Return, `2x + 1 =` and press Return.
- **Expected**: `7` appears after the `=`.
- **Failure looks like**: nothing, a wrong number, the line mangled.
- **Automated by**: `MathAssistTests/testChecksSolvesAndVariables`, `testAnswersLinesEndingInEquals`.

### TEST-NOTE-009: Templates and placeholders
- **Feature**: N5
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: none.
- **Steps**:
  1. Add → New from template → Meeting.
- **Expected**: today's date filled in, headings from the template.
- **Failure looks like**: literal `{date}` left in.
- **Automated by**: `NotesTests/placeholdersAndNames`, `templatesAndTheDailyNote`.
