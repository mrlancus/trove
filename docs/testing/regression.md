# Regression (REG)

Run before every release build.

### TEST-REG-001: A vault from an older build opens and migrates intact
- **Feature**: compatibility
- **Priority**: critical
- **Coverage**: auto-tested (journals written by the website and by Swift, legacy JSON snapshots); a fixture vault from today's build: not yet
- **Platforms**: core, all
- **Preconditions**: the fixtures in `Packages/TroveCore/Tests/TroveCoreTests/Fixtures`.
- **Steps**:
  1. `cd Packages/TroveCore && swift test`; `cd web && npm test`.
- **Expected**: all pass: journals, checkpoints and snapshots written by older code materialise to the expected records.
- **Failure looks like**: any interop test failing.
- **Automated by**: `WebInteropTests/materialisesJournalsWrittenByTheWebApp`, `LocalDatabaseTests/legacyJSONSnapshotsStillOpenAndMoveIntoTheDatabase`, `CheckpointTests/fullReplayMatchesTheWebsite`. To add: a small vault made by today's build (trove-gen `tiny` written by `writeFolderVault`) kept as a fixture.

### TEST-REG-002: An older build on another device still syncs
- **Feature**: unknown kinds and fields are kept
- **Priority**: critical
- **Coverage**: not tested
- **Platforms**: two devices
- **Preconditions**: one device on the previous build, one on the new.
- **Steps**:
  1. Make notes, clips and ink on both; on the new one use a new feature (e.g. Develop practice when it ships).
  2. Edit the same item's title on the old one.
- **Expected**: both converge; the new feature's data survives the old device's edits.
- **Failure looks like**: the new data lost after the old device writes.
- **Automated by**: manual.

### TEST-REG-003: Smoke run passes
- **Feature**: everything
- **Priority**: critical
- **Coverage**: not tested
- **Platforms**: your devices
- **Preconditions**: the release build installed.
- **Steps**:
  1. Run `SMOKE.md`.
- **Expected**: every smoke test passes or has a known bug.
- **Failure looks like**: any new failure.
- **Automated by**: manual.
