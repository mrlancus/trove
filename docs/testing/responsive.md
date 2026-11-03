# Cross-device and responsive (RESP)

Each test checks for clipping, reachable controls, readable text and correct reflow. Simulator
screenshots for these come from the UI tests (`ci-logs-tests` branch, `shots/`) and feed `docs/UI_AUDIT.md`.

### TEST-RESP-001: iPhone portrait and landscape
- **Feature**: layout
- **Priority**: critical
- **Coverage**: implemented (screenshots in CI)
- **Platforms**: iPhone
- **Preconditions**: your vault.
- **Steps**:
  1. Visit Library, an item, Clipboard, Search in portrait; rotate to landscape on each.
- **Expected**: nothing clipped; tab bar reachable; text not cut; the keyboard never hides the field you type in.
- **Failure looks like**: overlapping toolbars, unreachable buttons.
- **Automated by**: `TroveUITests/testRotateAndShow` (screenshots); judging: manual.

### TEST-RESP-002: iPad Split View and Stage Manager sizes
- **Feature**: layout
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPad
- **Preconditions**: another app for Split View.
- **Steps**:
  1. Open Trove at 1/3, 1/2 and 2/3 width, and in a Stage Manager window you resize.
  2. In each, open a notebook and a PDF.
- **Expected**: the sidebar collapses at narrow widths; the notebook re-fits; tools stay reachable.
- **Failure looks like**: the canvas at 10 %, the toolbar off-screen.
- **Automated by**: manual.

### TEST-RESP-003: Rotate or resize mid-task
- **Feature**: state across layout changes
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPad, Mac
- **Preconditions**: none.
- **Steps**:
  1. While typing in a note, rotate; while a lasso menu is open, rotate; while reading a PDF on page 30, resize the Mac window.
- **Expected**: text, selection, menu and page kept.
- **Failure looks like**: the cursor lost, the PDF back on page 1, a menu stranded.
- **Automated by**: manual.

### TEST-RESP-004: Mac window sizes and an external display
- **Feature**: Mac layout
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: Mac
- **Preconditions**: none.
- **Steps**:
  1. Resize to the minimum (900 × 560), a medium window and full screen; drag to the external display.
- **Expected**: no clipped toolbars; sidebar, list and item all usable.
- **Failure looks like**: overlapping columns, blurry content on the other display.
- **Automated by**: manual.

### TEST-RESP-005: Website at 360, 768, 1280 and 1920 px
- **Feature**: web layout
- **Priority**: high
- **Coverage**: auto-tested (phone width in notes e2e)
- **Platforms**: web
- **Preconditions**: the website.
- **Steps**:
  1. Resize the browser to each width; open the library, a note and a PDF.
- **Expected**: no horizontal scroll; controls reachable.
- **Failure looks like**: overflow, overlapped controls.
- **Automated by**: website `notes.e2e.mjs` (desktop + phone width); other widths: manual.

### TEST-RESP-006: The largest Dynamic Type
- **Feature**: readability
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPhone, iPad
- **Preconditions**: Settings → Accessibility → Larger Text at the largest.
- **Steps**:
  1. Visit Library, an item, Settings, Study.
- **Expected**: text grows, rows wrap, nothing truncated past use.
- **Failure looks like**: fixed tiny text, labels cut to "…".
- **Automated by**: manual.
