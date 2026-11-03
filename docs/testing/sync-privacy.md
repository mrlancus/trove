# Sync and privacy (SYNC)

Ops and segments over iCloud Drive and the relay, TRV1 encryption, checkpoints, conflict copies,
the relay seeing only ciphertext, app lock, extensions holding only the public key. PROTOCOL.md §1–§4.

### TEST-SYNC-001: Mac, iPhone and iPad converge
- **Feature**: sync
- **Priority**: critical
- **Coverage**: auto-tested (three engines through a folder; relay integration)
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: all three on the vault, online.
- **Steps**:
  1. On each device make a note titled with the device's name.
  2. Wait a minute; pull to refresh.
- **Expected**: all three notes on all three devices, within a minute (seconds with the live socket).
- **Failure looks like**: a note missing on one device; the cloud icon showing an error.
- **Automated by**: `SyncTests/threeDevicesConvergeThroughAFolder`, `RelayIntegrationTests`; devices: manual.

### TEST-SYNC-002: The same field edited on two devices
- **Feature**: per-field last writer wins
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: one item on two offline devices.
- **Steps**:
  1. Device 1 renames it `One` at 10:00; device 2 renames it `Two` at 10:01.
  2. Bring both online.
- **Expected**: both show `Two`; nothing else about the item changes.
- **Failure looks like**: devices disagreeing, other fields reset.
- **Automated by**: `SyncTests/lastWriterWinsPerFieldInAnyOrder`.

### TEST-SYNC-003: Overlapping text edits become a conflict copy, never a loss
- **Feature**: conflicts
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: a note with one line `hello` on two offline devices.
- **Steps**:
  1. Change it to `hello mac` and `hello phone`.
  2. Bring both online; open Needs Attention.
- **Expected**: one text kept, the other offered as a conflict copy you can pick.
- **Failure looks like**: one edit silently gone.
- **Automated by**: `SyncTests/concurrentTextEditsMergeOrBecomeConflicts`, `LibraryTests/conflictsAreSurfacedAndResolvable`.

### TEST-SYNC-004: Offline for a day, then back
- **Feature**: offline queue
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: iPhone, iPad
- **Preconditions**: none.
- **Steps**:
  1. Airplane Mode; make five notes and draw a page; quit and reopen Trove.
  2. Go online.
- **Expected**: everything was there offline and reaches the other devices once online.
- **Failure looks like**: work lost on reopen; a "segment too large" or conflict error that never clears.
- **Automated by**: `SyncTests/snapshotRestoresStateAndUnpushedWork`, `OutboxTests/restartedOutboxKeepsSegmentsSmall`, `aConflictingSegmentIsNotRetriedForEver`.

### TEST-SYNC-005: The relay sees only ciphertext
- **Feature**: E2E
- **Priority**: critical
- **Coverage**: auto-tested (encryption); a captured request per route: not tested
- **Platforms**: relay
- **Preconditions**: a local relay (`npx wrangler dev --local --config wrangler.test.jsonc`) and the website.
- **Steps**:
  1. Make a note `secret-walrus` on the website.
  2. Read the relay's stored segments, blobs and inbox (R2 and the Durable Object, or the request bodies in the browser's network log).
- **Expected**: no `secret-walrus` anywhere except in AI routes you call on purpose and Publish to link (PROTOCOL.md §4, §6).
- **Failure looks like**: the plaintext in any segment, blob or inbox body.
- **Automated by**: `CryptoTests/rejectsTamperingTruncationAndWrongKeys`, `SyncTests/blobsAreEncryptedAndDeduplicated`; the per-route capture: manual (to automate).

### TEST-SYNC-006: Deletes propagate, Restore propagates
- **Feature**: deletes
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: an item on two devices.
- **Steps**:
  1. Delete it on device 1; wait; check device 2. Restore it on device 2; check device 1.
- **Expected**: gone on both, then back on both.
- **Failure looks like**: it lingers or comes back by itself.
- **Automated by**: `SyncTests/deleteAndUndelete`.

### TEST-SYNC-007: Extensions only hold the public key
- **Feature**: key handling
- **Priority**: critical
- **Coverage**: auto-tested (inbox sealing)
- **Platforms**: iPhone, iPad, Chrome
- **Preconditions**: the share extension or the Chrome extension set up.
- **Steps**:
  1. Save something through the extension.
- **Expected**: it reaches the vault through the sealed inbox; the extension's settings contain the public key, relay and inbox token only.
- **Failure looks like**: a vault key in App Group storage or extension storage.
- **Automated by**: `CryptoTests/inboxEnvelopeRoundTrip`, `extensions/browser` crypto test.

### TEST-SYNC-008: A new device starts from a checkpoint
- **Feature**: checkpoints
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: a vault with a checkpoint (5,000+ ops).
- **Steps**:
  1. Pair a new device (or a new website login).
- **Expected**: it opens in seconds and shows the same library as the others.
- **Failure looks like**: replaying for minutes, missing items.
- **Automated by**: `CheckpointTests/websiteCheckpointLoadsAndLaterOpsApplyLikeAFullReplay`, `LocalDatabaseTests/aNewDeviceStartsFromACheckpointAndKeepsIt`; website `checkpoint.e2e.mjs`.

### TEST-SYNC-009: App lock
- **Feature**: Settings → Privacy → Lock Trove
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: iPhone, iPad, Mac
- **Preconditions**: lock on.
- **Steps**:
  1. Leave Trove; come back after the timeout.
- **Expected**: Face ID / password before anything shows; the app switcher picture is hidden.
- **Failure looks like**: content visible before unlocking.
- **Automated by**: manual.
