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
        Notes/*.md (Mac mirror)
```

## Data model
- Everything is a **record** (`kind`: `item` or `collection`), materialised from **ops** (PROTOCOL.md §3).
- Plain fields are last-writer-wins per field, ordered by a hybrid logical clock. Note bodies are a
  text field merged with diff3. When an edit can't be merged, it is kept as a conflict copy, which the
  app shows as "Needs Attention", so nothing is ever silently lost.
- `Item` (TroveCore/Model/Item.swift) is a typed view over a record. Field names are listed in `Field`.
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
| Shortcuts/Siri | `App/Sources/Intents/*` |
| Share sheet | `App/ShareExtension/ShareViewController.swift` (seals via `CaptureDrop`) |
| Widgets + Control Center | `App/Widgets/TroveWidgets.swift` |
