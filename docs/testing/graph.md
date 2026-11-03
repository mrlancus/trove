# The graph (GRAPH)

What exists: `[[wikilinks]]`, hand-made links (`links`), backlinks, "Maybe related", folders and
auto-filing, the connections graph view. Develop's concepts and typed edges (DEVELOP_PLAN §C2) get
their tests with the code (TEST-GRAPH-010 on).

### TEST-GRAPH-001: Both directions of a hand-made link
- **Feature**: links
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: items A and B.
- **Steps**:
  1. On A: Connections → Link to → B.
  2. Open B.
  3. Remove the link from B.
- **Expected**: B lists A; after removing, neither lists the other.
- **Failure looks like**: one-way links, a removed link coming back after sync.
- **Automated by**: `OrganizeTests/linksMatchTheSharedCases`.

### TEST-GRAPH-002: New items are filed into folders, and moving one sticks
- **Feature**: Organizer
- **Priority**: high
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: folders Recipes and Physics with a few items each.
- **Steps**:
  1. Save a recipe link.
  2. Move it to Physics by hand.
  3. Let enrichment run (a minute).
- **Expected**: it was filed into Recipes; after the move it stays in Physics.
- **Failure looks like**: auto-filing moving it back.
- **Automated by**: `OrganizeTests/enrichmentRefilesAutoFiledLinksOnly`, `newItemsAreFiledAndFoldersAreShared`.

### TEST-GRAPH-003: Links when the source is deleted and restored
- **Feature**: deletes
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: all
- **Preconditions**: A links to B by `[[B]]`.
- **Steps**:
  1. Delete B; open A.
  2. Restore B from Recently Deleted.
- **Expected**: while deleted, A shows `[[B]]` as not existing; after restore, the link works again.
- **Failure looks like**: A broken after restore.
- **Automated by**: manual.

### TEST-GRAPH-004: The graph view with many items
- **Feature**: GraphView
- **Priority**: high
- **Coverage**: not tested
- **Platforms**: Mac, iPad
- **Preconditions**: `-TroveTestVault small`.
- **Steps**:
  1. Open Connections (graph); pan and zoom.
- **Expected**: it draws in under a second and pans without stutter; no hang in "Graph".
- **Failure looks like**: a long freeze, hangs logged.
- **Automated by**: manual.

## Built: Develop's concepts and typed edges (TroveCore)

### TEST-GRAPH-010: Two devices make the same concept and link offline
- **Feature**: concept and edge ids
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: two engines on one folder vault.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: one concept and one edge after both sync, identical on both.
- **Failure looks like**: two concepts or two edges.
- **Automated by**: `DevelopTests/twoDevicesMakeTheSameConceptAndEdgeOffline`.

### TEST-GRAPH-011: Correcting a wrong AI link sticks
- **Feature**: rejected edges
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: an AI suggestion.
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: after I reject it, a new AI suggestion changes nothing; it's hidden from the index but kept; I can still accept it myself.
- **Failure looks like**: the link coming back.
- **Automated by**: `DevelopTests/aRejectedLinkStaysRejected`.

### TEST-GRAPH-012: Both directions, through a duplicate concept's merge
- **Feature**: EdgeIndex, ConceptMatch
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: core
- **Preconditions**: "Conservation of momentum" and "Momentum conservation".
- **Steps**:
  1. Packages/TroveCore: `swift test --filter DevelopTests`.
- **Expected**: they merge automatically (smallest id wins); photo → concept, problem → skill and card → source read both ways, and links to the loser show on the winner; undoing the merge restores both.
- **Failure looks like**: lost links after a merge.
- **Automated by**: `DevelopTests/everyLinkWorksBothWaysAndThroughMerges`, `theIndexFollowsTheChangeFeed`.
