# Trove architecture

```
┌──────────── Apple apps (App/, SwiftUI, one multiplatform target) ─────────────┐
│ Views ── AppModel (@MainActor @Observable) ── VaultStore (config, Keychain,   │
│                    │                           iCloud folder, relay creds)    │
│                    ├── EnrichmentService (Tier 0 → Apple Intelligence → cloud)│
│                    ├── SemanticIndex (NLEmbedding, local only)                │
│                    ├── LiveConnection (relay WebSocket)                       │
│                    └── Integrations: Obsidian mirror, Apple Notes (Mac),      │
│                        screenshots, background tasks (iOS)                    │
│ Extensions: Share sheet · Widgets + Control · Safari (= extensions/browser)   │
└────────────────────────────────┬──────────────────────────────────────────────┘
                                 │ uses
┌────────────────────────────────▼──────────────────────────────────────────────┐
│ TroveCore (Packages/TroveCore, pure Swift, tested on Linux + Apple)           │
│  Library (actor) ── SyncEngine (actor) ── RecordStore (deterministic merge)   │
│     │                 │   Journal → Segments (TRV1-encrypted)                │
│     │                 └─ Transports: FolderTransport (iCloud Drive vault)     │
│     │                                RelayTransport (Cloudflare)              │
│     ├─ SearchIndex (BM25 + prefix + filters) · SmartCollections               │
│     ├─ Enrich: URLCleaner, HTMLMetadata, SchemaOrg, BasicEnricher, AutoTagger │
│     └─ Import: Obsidian/Markdown, Kindle, bookmarks, CSV, Readwise, Notion,   │
│                Apple Notes HTML · InboxEnvelope/InboxSync · Pairing payloads  │
└────────────────────────────────┬──────────────────────────────────────────────┘
                                 │ same bytes (docs/PROTOCOL.md)
        iCloud Drive/Trove/ ─────┴───── Cloudflare relay (server/)
        .sync/<device>/*.trv            Worker + Durable Object per vault
        .blobs/aa/<id>.trv              R2 blobs + sealed inbox, WebDAV, email, AI
        Notes/*.md (Mac mirror)                      │
                                                       └─ serves web/public: the web app (JS port
                                                          of segments, merge, search; PROTOCOL.md §7)
```

## Web app (`web/`)
| Concern | File |
|---|---|
| TRV1, HKDF keys, SHA-256 | `web/public/core/{trv1,keys,bytes}.js` |
| Ops, HLC, RecordStore, Journal, segments (port of the Swift sync core) | `web/public/core/records.js`, `merge.js` |
| Item view, search, smart collections, URL cleaning | `web/public/core/items.js` |
| Folders and auto-filing (port of `Organizer.swift`) | `web/public/core/organize.js` |
| Wikilinks, backlinks, mentions, related (port of `Links.swift`) | `web/public/core/links.js` |
| File previews: GoodNotes, Word, Excel, PowerPoint, iWork, CSV | `web/public/core/files.js` |
| Ink editing: turn/flip, shape picker, handles, connectors, ruler/protractor, groups, elements library (port of `InkEditing.swift`, `InkStickers.swift`) | `web/public/core/inkedit.js`; editor `draw.js` + `drawedit.js` |
| Viewer (pdf.js in `vendor/pdfjs-4.10.38`), thumbnails / graph view | `web/public/viewer.js` / `web/public/graph.js` |
| Join, sync, edit, attachments | `web/public/core/vault.js` |
| Local copy in IndexedDB: append-only op chunks, sealed at rest, plus the checkpoint it starts from (PROTOCOL.md §7) | `web/public/core/localstore.js`, `db.js` |
| Checkpoints: materialised records a new device loads instead of every op (PROTOCOL.md §3) | `web/public/core/checkpoint.js` (Swift: `Checkpoint.swift`) |
| Offline + install: service worker, manifest, registration; lazily loaded modules | `web/public/sw.js`, `manifest.webmanifest`, `offline.js`, `lazy.js` |
| UI (vanilla modules, no build step) | `web/public/app.js`, `app.css`, `index.html` |
| Settings → Bridges, link previews for saved links | `web/public/bridges.js` |
| Tests: unit + Swift fixtures / relay e2e / real Chromium | `web/test/core.test.mjs`, `bridges.test.mjs`, `relay.e2e.mjs`, `ui.e2e.mjs`, `organize.e2e.mjs`, `draw.e2e.mjs`, `offline.e2e.mjs`, `bridges.e2e.mjs` |
| Benchmarks with a regression gate (CI: `.github/workflows/tests.yml`) | `web/test/bench.mjs`, `bench-baseline.json`; Swift: `TroveCoreTests/Benchmarks.swift` (`TROVE_BENCH=1`) |

## AI and looking back (ROADMAP §4, PROTOCOL.md §4 "AI" and §11)
| Concern | File |
|---|---|
| Relay: Claude enrich/ask/action (text and page pictures), monthly token allowance per vault, `ai/status` | `server/src/ai.ts`, `vault.ts` (`aiStatus`), tests `server/test/ai.test.ts` |
| Ask Trove retrieval (local search → best ~20 snippets) | `web/public/core/ask.js` |
| Weekly digest (id per ISO week), on this day, possible duplicates (port: `Digest.swift`, `Library+Digest.swift`) | `web/public/core/digest.js` (`Fixtures/digest-cases.json`, `web/test/make-digest-fixture.mjs`) |
| Suggest links (no AI) | `web/public/core/suggest.js` |
| Website AI function API (drawing hook: `pageAction`) / UI (Ask Trove, note AI menu, AI settings, Look back) | `web/public/aiactions.js` / `web/public/ai.js` |
| Apps: note AI (Apple Intelligence, else cloud), digest, overnight iPad worker | `App/Sources/Model/AppModel+AI.swift`, `Views/NoteAIMenu.swift`, `Enrichment/OnDeviceAI.swift`, `Services/BackgroundTasks.swift` |

## Bridges and Trove for Claude
| Concern | File |
|---|---|
| Bridges on the relay: webhook, RSS/Atom, GitHub, Telegram; status, rate limits (PROTOCOL.md §4 "Bridges") | `server/src/bridges.ts`, `feeds.ts` |
| Safe fetching (SSRF checks) and link previews | `server/src/preview.ts` |
| Folder/tag hints when importing bridge entries | `Library.importInbox` / `Vault.importEnvelope` (`Fixtures/inbox-bridges.json`) |
| Settings → Bridges in the apps | `App/Sources/Views/BridgesView.swift` (API in `RelayClient`) |
| `trove-mcp`: MCP over stdio, joins as an `agent` device | `mcp/bin/trove-mcp.js`, `mcp/src/server.js`, `mcp/src/store.js` |

## Data model
- Everything is a **record** (`kind`: `item` or `collection`), materialised from **ops** (PROTOCOL.md §3).
- Plain fields are last-writer-wins per field, ordered by a hybrid logical clock. Note bodies are a
  text field merged with diff3. When an edit can't be merged, it is kept as a conflict copy, which the
  app shows as "Needs Attention", so nothing is ever silently lost.
- `Item` (TroveCore/Model/Item.swift) is a typed view over a record. Field names are listed in `Field`.
- Items sit in at most one **folder** (`kind: "folder"` records with a `parent`, PROTOCOL.md §9);
  new items are filed by `Organizer`. **Collections** are separate hand-made lists an item can be in
  several of.
- **Connections** are `[[wikilinks]]` in text plus hand-made `links`; `Links.graph` builds the graph.
- **Versions**: note text history comes from the text ops; replaced files go into `fileVersions`.
- `kind` is what the item physically is (note, link, pdf…). `category` is what it's *about* (recipe,
  place, product…) and drives Smart Collections and card styles.

## Sync
- Each device appends ops to its **own** journal and cuts them into immutable, encrypted segments.
  Segments are written to every transport:
  - iCloud Drive folder: `.sync/<deviceId>/`. Only that device ever writes in its folder, so iCloud
    never has a conflict to resolve.
  - Relay: `PUT /segments/...` and a WebSocket "something new" ping.
- Pulling reads every other device's segments and applies them. Any order works: same ops, same state.
- A device with both transports **bridges**: it copies relay-only segments into iCloud and the reverse.
  This covers a device that can't use iCloud, such as an iPhone on a free Apple ID if the Phase 0
  test fails.
- Attachments are content-addressed (`HMAC(blobIdKey, bytes)`) and encrypted. They are cached locally
  and uploaded before the records that point at them.
- `SyncEngine.Snapshot` (local JSON) keeps every op plus unpushed work, so the app opens offline.
  *Later:* move to SQLite once vaults get big.

## Keys
- Vault key (symmetric) plus an X25519 keypair live in the main app's Keychain only.
- Extensions and browsers only ever get the **public** key and an inbox token. They can add to the
  inbox (sealed TRV1) but can't read anything.
- New devices get the keys from the pairing QR code. The recovery code is the same payload without the
  relay part.

## Enrichment tiers (RESEARCH.md §3)
| Tier | Where | What |
|---|---|---|
| 0 basic | every device | page fetch and schema.org, OCR (Vision), NSDataDetector, NLTagger, NLEmbedding semantic search |
| 1 onDevice | Apple Intelligence devices (the iPad) | Foundation Models: title, summary, tags, category, Ask Trove |
| 3 cloud | relay, opt-in | Claude (`CLAUDE_MODEL`), Workers AI Whisper/embeddings |

- **Results sync, indexes don't.** The iPad's summaries show up on every device. Each device builds its
  own search and semantic index from the content.
- **Tier ordering.** `Library.applyEnrichment` refuses to overwrite a higher tier with a lower one, and
  never replaces a title the user typed.

## Where things live in the app
| Concern | File |
|---|---|
| App entry, scenes, menu bar, hotkey | `App/Sources/App/TroveApp.swift` |
| UI state and actions | `App/Sources/Model/AppModel.swift` |
| Vault creation/joining, folder access, Keychain | `App/Sources/Services/VaultStore.swift` |
| Enrichment | `App/Sources/Enrichment/*` |
| Obsidian / Apple Notes / screenshots | `App/Sources/Integrations/*` |
| Folders line, files + versions, history, connections | `App/Sources/Views/ItemExtras.swift` |
| Connections graph | `App/Sources/Views/GraphView.swift` |
| Drawing editor: model (tools, lasso actions, shapes, guides, text, library) / toolbar and panels / iPad canvas (PencilKit) / Mac canvas | `App/Sources/Drawing/InkEditorModel.swift` / `InkEditorView.swift`, `InkEditingViews.swift`, `InkEditorPanels.swift` / `PencilCanvas.swift` / `MouseInkCanvas.swift` |
| Ink maths shared with the website: geometry, outlines, shapes, editing, elements library, vault ops | `Packages/TroveCore/Sources/TroveCore/Drawing/` (`InkEditing.swift`, `InkStickers.swift`, `InkArrange.swift`, …) |
| Shortcuts/Siri | `App/Sources/Intents/*` |
| Share sheet | `App/ShareExtension/ShareViewController.swift` (seals via `CaptureDrop`) |
| Widgets + Control Center | `App/Widgets/TroveWidgets.swift` |
