# Capture (CAP)

Clipboard history (Mac palette ⌥Space, iPhone/iPad Clipboard screen and the Trove keyboard, website
view), links, images, screenshots, files, the share sheet, Safari. PROTOCOL.md §8.

### TEST-CAP-001: A copy on the Mac lands in clipboard history with its source
- **Feature**: Mac clipboard watcher
- **Priority**: critical
- **Coverage**: auto-tested (history logic: `ClipTests/historyDedupesPinsPrunesAndSaves`); watcher on a device: not tested
- **Platforms**: Mac
- **Preconditions**: Trove running on the Mac; Accessibility allowed (Settings → Clipboard says so).
- **Steps**:
  1. In TextEdit type `smoke-clip-1` and copy it (⌘C).
  2. In Safari, select a sentence on any page and copy it.
  3. Press ⌥Space.
- **Expected**: the palette opens over Safari within ~0.2 s; the top two rows are the sentence (source
  Safari, with the page title) and `smoke-clip-1` (source TextEdit).
- **Failure looks like**: nothing new in the list, the wrong source app, the palette not opening or
  opening behind Safari.
- **Automated by**: manual (needs the Mac); history logic `ClipTests/historyDedupesPinsPrunesAndSaves`.

### TEST-CAP-002: Paste from the palette into the front app
- **Feature**: palette paste
- **Priority**: critical
- **Coverage**: not tested
- **Platforms**: Mac
- **Preconditions**: TEST-CAP-001 done.
- **Steps**:
  1. Click into a new TextEdit document.
  2. Press ⌥Space, type `smoke`, press ⏎.
- **Expected**: `smoke-clip-1` is pasted into TextEdit; the palette closes; TextEdit keeps the keyboard.
- **Failure looks like**: nothing pasted, pasted into the wrong window, the palette staying open.
- **Automated by**: manual.

### TEST-CAP-003: The same text copied twice is one clip
- **Feature**: duplicates
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: Mac, iPhone, iPad, web
- **Preconditions**: none.
- **Steps**:
  1. Copy `dup-test` from TextEdit.
  2. Copy something else.
  3. Copy `dup-test` again.
- **Expected**: one `dup-test` clip, now at the top, its use count 2.
- **Failure looks like**: two `dup-test` rows.
- **Automated by**: `ClipTests/historyDedupesPinsPrunesAndSaves`.

### TEST-CAP-004: Clipboard history survives a restart and syncs
- **Feature**: clips are records
- **Priority**: critical
- **Coverage**: auto-tested (sync); restart on a device: not tested
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: Mac and iPhone on the same vault.
- **Steps**:
  1. Copy `restart-clip` on the Mac.
  2. Quit Trove (⌘Q) and open it again.
  3. Open the Clipboard tab on the iPhone and pull to refresh.
- **Expected**: `restart-clip` is in the Mac's history after the restart and on the iPhone within a minute.
- **Failure looks like**: the clip missing after restart, or never reaching the iPhone.
- **Automated by**: `ClipTests/clipsSyncBetweenDevices`; restart: manual.

### TEST-CAP-005: Passwords aren't kept (default)
- **Feature**: `SensitiveDetector`, Settings → Clipboard → passwords and codes
- **Priority**: critical
- **Coverage**: auto-tested (detection)
- **Platforms**: Mac
- **Preconditions**: the setting at its default ("Keep for 2 minutes, this device only").
- **Steps**:
  1. Copy a password from Passwords/1Password (or copy `Xk9#mQ2$vL7!pR4z` from TextEdit).
  2. Open the palette.
  3. Wait 2 minutes and open it again.
- **Expected**: the copy shows as sensitive (masked) at first, gone after 2 minutes, and never on another device.
- **Failure looks like**: the password in plain text, still there after 2 minutes, or on the iPhone.
- **Automated by**: `ClipTests/spotsSecrets`; lifetime and device: manual.

### TEST-CAP-006: Pause stops recording
- **Feature**: clipboard pause (C5)
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: Mac
- **Preconditions**: none.
- **Steps**:
  1. Pause clipboard history (menu bar Trove → Pause).
  2. Copy `paused-clip`.
  3. Resume and copy `resumed-clip`.
- **Expected**: `resumed-clip` is recorded, `paused-clip` never is.
- **Failure looks like**: `paused-clip` in history.
- **Automated by**: manual.

### TEST-CAP-007: The palette is hidden from screen sharing
- **Feature**: C6
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: Mac
- **Preconditions**: a screen-recording app (QuickTime → New Screen Recording).
- **Steps**:
  1. Start a screen recording.
  2. Open the palette, then close it.
  3. Stop and watch the recording.
- **Expected**: the recording never shows the palette.
- **Failure looks like**: clips visible in the recording.
- **Automated by**: manual.

### TEST-CAP-008: Save a link and a file from the share sheet
- **Feature**: share extension (`TroveShare`)
- **Priority**: critical
- **Coverage**: not tested
- **Platforms**: iPhone, iPad
- **Preconditions**: Settings → About → "Share sheet and widgets" says Connected (or the share-sheet code pasted once).
- **Steps**:
  1. In Safari open https://example.com, Share → Save to Trove.
  2. In Files share any PDF → Save to Trove.
  3. Open Trove.
- **Expected**: both are in the library within a minute, the link with its title, the PDF previewable.
- **Failure looks like**: "Open Trove once", "can't reach Trove's shared storage", or items missing.
- **Automated by**: manual (needs the device and its signing).

### TEST-CAP-009: A screenshot goes into Trove
- **Feature**: screenshot import (Settings → Integrations → Screenshots)
- **Priority**: high
- **Coverage**: auto-tested (ids and dedupe: `ScreenshotTests`); import on a device: not tested
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: this device's Notes box ticked for screenshots.
- **Steps**:
  1. Take a screenshot.
  2. Open Trove (iPhone/iPad) or wait 10 s (Mac).
- **Expected**: one new item with the screenshot, its text searchable after a minute; the line under the grid says where it went.
- **Failure looks like**: nothing, or two copies from two devices.
- **Automated by**: `ScreenshotTests/twoDevicesSaveOneAndExactCopiesGo`; device: manual.

### TEST-CAP-010: 10,000+ clips stay quick to search
- **Feature**: clip search
- **Priority**: high
- **Coverage**: not tested (budget: < 5 ms p90 per keystroke)
- **Platforms**: Mac, iPhone
- **Preconditions**: debug build with `-TroveTestVault full` (50k clips), or your own history.
- **Steps**:
  1. Open the palette (Mac) or Clipboard (iPhone).
  2. Type `momentum` one letter at a time.
- **Expected**: the list follows each letter with no visible pause; Settings → Battery → Lag shows no hang in Clipboard.
- **Failure looks like**: letters appearing late, a hang logged in "Clipboard".
- **Automated by**: manual; TroveCore `Benchmarks` for item search (clips next).

### TEST-CAP-011: An unsupported file still imports as a file
- **Feature**: import routing
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: a `.xyz` file with random bytes.
- **Steps**:
  1. Import it (Import → Files…, or drop it on the website).
- **Expected**: an item of kind file named after it, downloadable, no error.
- **Failure looks like**: a crash, an error, or nothing.
- **Automated by**: `ImportTests/plainFilesAndJunk`.

### TEST-CAP-012: The Trove keyboard shows clips
- **Feature**: `TroveKeyboard`
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPhone
- **Preconditions**: keyboard added with Allow Full Access.
- **Steps**:
  1. In Notes, switch to the Trove keyboard.
  2. Tap the newest clip.
- **Expected**: the clip's text is inserted.
- **Failure looks like**: "Nothing here yet" while clips exist (App Group lost on sideload), nothing inserted.
- **Automated by**: manual.
