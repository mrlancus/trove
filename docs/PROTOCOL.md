# Trove sync & crypto protocol (v1)

This is the contract shared by **TroveCore** (Swift), the **relay Worker** (TypeScript) and the
**browser extension** (JavaScript). Change it only with a version bump.

All multi-byte integers are big-endian. `b64u` = base64url without padding.

---

## 1. Keys

| Key | Size | Where it lives | Purpose |
|---|---|---|---|
| **Vault key** `VK` | 32 random bytes | Keychain on each device (never on the server) | Root symmetric key |
| **Vault keypair** | X25519 | Private key: Keychain on devices. Public key: server and extensions | Sealed inbox (others can *add*, only devices can *read*) |

Derived keys use HKDF-SHA256 with `ikm = VK`, an empty salt, `L = 32` and these `info` strings:

| info | Use |
|---|---|
| `trove/v1/segment` | AEAD key for journal segments |
| `trove/v1/blob` | AEAD key for attachments |
| `trove/v1/blob-id` | HMAC-SHA256 key for attachment ids |

**Attachment id** = lowercase hex of `HMAC-SHA256(blobIdKey, plaintextBytes)`. It's deterministic, so
duplicates de-dupe, and it reveals nothing about the content to the server.

---

## 2. TRV1 chunked AEAD container

Every encrypted file or body (segments, blobs, inbox entries) uses this one format. It works with
streams, so the Worker can seal a 90 MB GoodNotes PDF without holding two copies in memory.

```
offset size  field
0      4     magic "TRV1"
4      1     mode: 1 = symmetric, 2 = sealed (X25519)
5      4     chunkSize (plaintext bytes per chunk; default 65536)
9      32    ephemeralPublicKey (only when mode = 2)
..     8     noncePrefix (random)
..     ...   chunks
```

- **Header** = every byte before the first chunk. That's 17 bytes for symmetric, 49 for sealed.
- **Chunk i**: `AES-256-GCM(key, nonce = noncePrefix ‖ u32(i), plaintext_i, aad = header ‖ u8(isLast))`. Each chunk is `len(plaintext_i) + 16` bytes.
- **Chunk sizes:** every chunk except the last carries exactly `chunkSize` plaintext bytes. The last carries `0 … chunkSize` bytes. Empty plaintext is a single empty last chunk.
- **Reading:** a chunk is "last" when the remaining ciphertext is ≤ `chunkSize + 16` bytes. A truncated or extended stream fails authentication.
- **Sealed key (mode 2):**
  `shared = X25519(ephemeralPrivate, vaultPublic)`,
  `key = HKDF-SHA256(ikm = shared, salt = ephemeralPublic ‖ vaultPublic, info = "trove/v1/sealed", L = 32)`.
- **Symmetric key (mode 1):** the derived key for the purpose (segment or blob).

---

## 3. Records and operations

All of Trove's state is a set of **records**: items, collections, spaces and settings. Each record has an
id, a `kind`, and a map of fields. State is never stored directly. It is **materialised from ops**,
and every device that has the same set of ops computes the same state.

### Hybrid logical clock (HLC)
`hlc` = `"<millis, 13 digits>-<counter, 4 digits>-<deviceId>"`, for example `1760000000000-0003-7F3A…`.
It sorts as a plain string, and ties break on device id. Each device keeps its HLC ≥ every HLC it has seen.

### Op (JSON)
```json
{
  "d": "<deviceId>",           // author device
  "s": 42,                      // per-device sequence, starts at 1, no gaps
  "h": "<hlc>",
  "r": "<recordId>",
  "k": "item",                  // record kind (only needed on the first op, but always allowed)
  "t": "set" | "text",
  "f": { "title": "…", "_deleted": false },   // for "set": field → JSON value (LWW per field)
  "x": { "field": "body", "value": "…", "base": "<sha256 hex of previous text or empty>" } // for "text"
}
```

**Materialisation:** sort all ops by `h`, then apply them in order.
- **`set`:** each field takes the value from the op with the highest `h` (last writer wins). Deleting a record = setting `_deleted: true`. Undeleting = setting it to `false` later.
- **`text`:** a per-field text register with history.
  - If `base` equals the hash of the current text, the new value replaces it.
  - Otherwise this was a concurrent edit. Run a 3-way line merge with `base text = history[base]` (empty string if unknown), `ours = current`, `theirs = value`.
  - A clean merge becomes the new text.
  - On conflict, the current text stays and `value` is kept in the record's `_conflicts` list for the UI to show. Data is never silently lost.
  - Every text value seen is added to the history, keyed by its hash.

### Segment (the file and relay unit)
A segment is an immutable batch of consecutive ops from one device:
- **Plaintext:** UTF-8 JSON Lines, one op per line, with sequence numbers contiguous from `firstSeq` to `lastSeq`.
- **Encrypted:** TRV1 mode 1, using the segment key.
- **File name:** `<firstSeq zero-padded to 12>-<lastSeq zero-padded to 12>.trv`.
- **Limit:** 512 KiB of plaintext per segment.

### iCloud Drive vault layout
```
Trove/
  vault.json                 public info: { "v":1, "vaultId", "vaultPublicKey" (b64u), "createdAt", "encrypted": true }
  .sync/<deviceId>/<first>-<last>.trv      journals; ONLY that device writes in its own folder
  .blobs/<aa>/<blobId>.trv   attachments (blobId prefix folders); written once, never modified
  Notes/…                    readable Markdown mirror (written only by the "mirror owner" device, the Mac)
```
No file is ever written by two devices, so iCloud never has to resolve a conflict.

---

## 4. Relay HTTP API (Cloudflare Worker)

Base: `https://<worker>/v1`. Auth: `Authorization: Bearer <token>`.

| Token kind | Can do |
|---|---|
| **device** | Everything in its vault |
| **inbox** | Only `POST /vaults/:v/inbox` and WebDAV uploads (write-only) |

| Method & path | Auth | Body → Response |
|---|---|---|
| `POST /vaults` | none | `{vaultPublicKey, deviceName, deviceKind?, deviceId?}` → `{vaultId, deviceId, deviceToken, inboxToken}` |
| `POST /vaults/:v/pairings` | device | → `{pairingCode, expiresAt}` (single use, 10 min) |
| `POST /vaults/:v/devices` | none (pairing code in body) | `{pairingCode, deviceName, deviceKind?, deviceId?}` → `{deviceId, deviceToken}` |
| `GET /vaults/:v/devices` | device | → `{devices:[{deviceId,name,kind,createdAt,lastSeenAt,revoked}]}` |
| `DELETE /vaults/:v/devices/:id` | device | revoke → `204` |
| `POST /vaults/:v/inbox-tokens` | device | → `{inboxToken}` (for the extension / GoodNotes / email) |
| `PUT /vaults/:v/segments/:device/:first/:last` | device (must be `:device`) | TRV1 bytes → `{cursor}`. Idempotent: an identical re-upload returns the same cursor |
| `GET /vaults/:v/segments?after=<cursor>&limit=<n>` | device | → `{segments:[{cursor,device,first,last,size}], more}` |
| `GET /vaults/:v/segments/:device/:first/:last` | device | → TRV1 bytes |
| `PUT /vaults/:v/blobs/:blobId` | device | TRV1 bytes → `201` (or `200` if it already exists) |
| `GET /vaults/:v/blobs/:blobId` | device | → TRV1 bytes |
| `POST /vaults/:v/inbox` | inbox or device | TRV1 **sealed** bytes, plus header `X-Trove-Source: web\|ios\|other` → `{id, cursor}` |
| `GET /vaults/:v/inbox?after=<cursor>` | device | → `{entries:[{id,cursor,size,source,davPath?,createdAt}], more}` |
| `GET /vaults/:v/inbox/:id` | device | → TRV1 sealed bytes |
| `DELETE /vaults/:v/inbox/:id` | device | ack after import → `204` |
| `GET /vaults/:v/live` | device (token may also be sent as `?token=`) | WebSocket. Server → client messages: `{"type":"segment",cursor,device,first,last}`, `{"type":"inbox",cursor,id}`, `{"type":"price",id,itemId,price,previous,currency}` |
| `GET /vaults/:v/watches` | device | → `{watches:[Watch]}` (§5) |
| `PUT /vaults/:v/watches/:id` | device | `{url, itemId?}` → `201`/`200` `Watch` (§5) |
| `DELETE /vaults/:v/watches/:id` | device | → `204` |
| `GET /vaults/:v/published` | device | → `{pages:[{slug,title,updatedAt,path}]}` (§6) |
| `PUT /vaults/:v/published/:slug` | device | `{title, markdown}` → `201 {slug, path}` (§6) |
| `DELETE /vaults/:v/published/:slug` | device | → `204` |
| `GET /p/:v/:slug` | none | the published page as HTML (§6) |
| `POST /vaults/:v/ai/enrich` | device | `{text, url?, title?}` → `{title, summary, tags[], kind?}` (Claude) |
| `POST /vaults/:v/ai/ask` | device | `{question, sources:[{id,text}]}` → `{answer, citations:[id]}` (Claude) |
| `POST /vaults/:v/ai/transcribe` | device | audio bytes → `{text}` (Workers AI Whisper) |
| `POST /vaults/:v/ai/embed` | device | `{texts[]}` → `{vectors[][]}` (Workers AI bge-m3) |
| `GET /health` | none | `{ok:true, version}` |

**Recovery** (no token): `POST /vaults/:v/recovery` → `201 {challengeId, box}`, where `box` is 32 random bytes
sealed (TRV1 mode 2) to the vault public key. It expires after 5 minutes, and at most 10 can be open at once (`429` after that).
Only a holder of the vault private key can open it. `POST /vaults/:v/devices {recoveryChallenge, recoveryAnswer (b64u), deviceName, deviceKind, deviceId?}`
then adds a device, as a pairing code would. Each challenge works once. A wrong answer gives `403`.

`POST /vaults` returns `403` when the Worker var `ALLOW_NEW_VAULTS` is `"false"`. Set it once your own vault
exists, so nobody else can use your relay. Existing vaults are unaffected.

`deviceId` (optional, a UUID) is kept if no other device uses it. That way a device that started in an
iCloud-only vault keeps the journal id it already writes under `.sync/<deviceId>/`.

AI routes return `403` unless the vault has AI enabled (`PUT /vaults/:v/settings {aiEnabled:true}`).
The Anthropic key is a Worker secret (`ANTHROPIC_API_KEY`). Content sent to AI routes is plaintext
by necessity, and the apps label those items "processed in cloud".

### Inbox plaintext (inside the sealed TRV1)
```
u32 headerLength | header JSON (UTF-8) | body bytes
header = { "v":1, "source":"email|webdav|web|ios", "receivedAt": ISO8601,
           "name"?: "file.pdf", "mime"?: "application/pdf", "url"?: "…", "title"?: "…",
           "groupId"?: "…" (links an email to its attachments), "meta"?: {…} }
```

### WebDAV (for GoodNotes Auto Backup)
- **Address:** `https://<worker>/dav/`. Basic auth: username = vaultId, password = an inbox token.
- **Supported:** `OPTIONS`, `PROPFIND` (depth 0/1), `MKCOL`, `PUT`, `HEAD`, `DELETE`, `MOVE`, `LOCK`/`UNLOCK` (fake locks).
- **How uploads are handled:** a `PUT` is sealed straight into the inbox, with `davPath` recorded. The server keeps only path, size and etag, so `PROPFIND` can list what was uploaded. A newer upload of the same path supersedes the older one on import.
- **Privacy caveat:** notebook *file names* are visible to the server. The contents are not.

## 5. Price-drop watches (opt-in per item)
A device turns on "Track price drops" for a product item by sending `PUT /vaults/:v/watches/:id`
with `{url, itemId}`. `id` is 8–64 of `[A-Za-z0-9_-]`; apps use the item id. The relay can see the
product URL and the item id, and nothing else about the item. A vault can have up to 200 watches.

- **Checking:** a Durable Object alarm re-fetches each page about every 12 hours, at most 40 pages
  per run. It also runs about 1 second after a watch is added. The price comes from schema.org
  `Product` JSON-LD (`offers.price`, `lowPrice`, `priceSpecification.price`, including inside
  `@graph`), with a fallback to the `product:price:amount`, `og:price:amount` and `itemprop=price` meta tags.
- **Watch:** `{id, url, itemId, createdAt, checkedAt|null, error|null, price|null, currency|null,
  lowest|null, history:[{at,price}] (last 60 changes), droppedAt|null}`. Times are Unix ms.
- **Drop:** when a check finds a price lower than the previous one, the relay sets `droppedAt` and
  sends `{"type":"price",id,itemId,price,previous,currency}` on every live socket. Apps also poll
  `GET /watches` when they sync. They show the alert and write `price`/`lowest` into the item's
  fields, so the price also syncs to iCloud-only devices.

## 6. Publish to link
Publishing a note is the user's explicit choice to make that note public. The relay stores it in
**plaintext** and serves it at `GET /p/:vaultId/:slug`. The app picks a random slug of 6–64
`[A-Za-z0-9_-]` (22 characters of base64url in practice), so links can't be guessed. The page is
capped at 256 KB of Markdown.

- **Rendering:** the server renders a safe subset of Markdown and escapes everything first:
  headings, lists, tasks, quotes, code, bold, italic, strike, `[[wikilinks]]` (as plain text) and
  links (`http`, `https`, `mailto` only).
- **Headers:** `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src https: data:`, `noindex`, `nosniff`, `no-referrer`.
- **Updating:** re-publishing the same slug updates the page. `DELETE` takes it down (`404` afterwards).
- **On the item:** the app stores `published: {slug, url}` in the item's fields so every device can
  show and remove the link.

## 7. Web app (`web/public`, served at the relay root)
The web app is a relay device like any other (`deviceKind: "web"`). It joins with the app's
"Add a device" setup code (`PairingPayload`: vault keys plus a single-use relay pairing code) and is
revoked the same way.
- **Keys:** it stores the segment, blob and blob-id keys (HKDF, §1) and, when the code it joined
  with carried it, the vault X25519 private key. All of them are **non-extractable** WebCrypto keys
  in IndexedDB. The raw bytes are used once and dropped. With the private key it imports the sealed
  inbox (extension, email, GoodNotes) like the apps do.
- **Creating a vault:** the web app can create a vault (`POST /vaults`, `deviceKind: "web"`). It
  shows the **recovery code** once: a `PairingPayload` without a pairing code. With that code, a
  device can make setup codes for new devices (`POST pairings` plus the keys) or recover access with
  the recovery challenge (§4).
- **Journal:** it writes the same ops and segments as the apps (§3). Its sequence numbers live in
  IndexedDB. If its own journal on the relay is already ahead (a stale tab or restored storage), it
  renumbers its unpushed ops past it before uploading.
- **Same results everywhere:** `web/test` and `WebInteropTests.swift` check journals written by
  each side materialise to identical records on the other.
- **Headers:** static assets carry a strict CSP (`web/public/_headers`): scripts and connections to
  the same origin only, no inline script or style.

## 8. Clipboard history (clips)
Clips are records with `kind: "clip"`, synced and encrypted like everything else. They're kept apart
from library items (`kind: "item"`). Fields (all `set`, last writer wins):

| Field | Meaning |
|---|---|
| `text` | the copied text (for files: their paths, one per line) |
| `image` | attachment JSON `{id, name, mime, size}` for a copied image (an encrypted blob, §1) |
| `files` | `[path]` when files were copied (Mac) |
| `hash` | `"t:" + sha256hex(utf8 text)`, `"i:" + sha256hex(image bytes)` or `"f:" + sha256hex(paths joined by "\n")` |
| `createdAt`, `lastUsedAt` | Unix ms. History is sorted by the later of the two |
| `device`, `sourceDevice`, `sourceApp` | device id, its display name, and the app it was copied from |
| `pinned` | pinned clips are never pruned |
| `savedItem` | the library item the clip was saved as |

- **De-duplication:** copying something whose `hash` matches an existing clip just sets that clip's
  `lastUsedAt` (and `sourceApp`).
- **Pruning:** any device may delete unpinned clips older than 30 days or beyond the newest 1,000.
- **Never stored:** copies marked concealed or transient (nspasteboard.org types), copies from
  password managers, and text that looks sensitive (passwords, API keys, private keys, one-time
  codes) are never written as clips. The Mac holds sensitive copies in memory for two minutes only.
  The rules live in `Clip.swift` (`SensitiveDetector`) and `web/public/core/clips.js`, and their
  tests are kept in step.
- **iOS keyboard:** the app writes the latest text clips to the App Group (`keyboard-clips.json`)
  for the Trove keyboard, which has no vault keys.

## 9. Folders, connections, versions and thumbnails
All of these are plain records and fields (`set` ops, last writer wins), so older clients simply
ignore them.

**Folders** are records with `kind: "folder"`:

| Field | Meaning |
|---|---|
| `name` | display name (no `/`) |
| `parent` | parent folder id, or `null` for the top level |
| `auto` | `true` when the organiser made it, `false` once made or renamed by hand |
| `createdAt` | Unix ms |

- **Ids come from the path**: `folder:<lowercased name>` at the top and `<parent id>/<lowercased name>`
  below (`folder:documents/spreadsheets`). Two devices filing into "Documents" at once therefore write
  the same record.
  - Before making a folder, a device first looks for an existing live folder with the same name
    (ignoring case) under the same parent. That way renamed and hand-made folders are reused.
  - If the path id is taken by a live folder that has since moved or been renamed, the device adds
    `~` and 6 random characters.
- **Deleting a folder** (`_deleted: true`) first moves its items and subfolders to its parent.
- **A folder can't be moved inside itself.** Clients break cycles on display by showing such folders
  at the top level.

**Item fields**:

| Field | Meaning |
|---|---|
| `folder` | folder id, or `null` (unfiled) |
| `folderAuto` | `true` while the organiser chose the folder; set to `false` when the user moves the item |
| `links` | ids of items connected by hand. `[[Title]]` links in the body are found from the text and aren't stored |
| `fileVersions` | earlier files, newest first, at most 50: `[{attachment, at, by}]` (`attachment` is the usual `{id,name,mime,size}`, `at` Unix ms, `by` device id) |
| `thumbnail` | a small JPEG preview (attachment JSON). Written once by whichever device sees the file first; cleared when the file changes |
| `alsoFrom` | other sources (`ItemSource` values) the same thing arrived from later. When a link that's already saved comes in again from somewhere else, the existing item gains that source instead of a duplicate being made, so "Sources" lists it under every source it came from (`source` stays the first one) |

**Filing new items**: `Organizer.swift` and `web/public/core/organize.js`, both checked against
`Fixtures/organize-cases.json`.
- The folders a file came from (a dropped folder, or the folders inside a zip, starting with the
  zip's name) win. Notion export ids are dropped, repeats are collapsed, and the path is at most 5
  deep.
- Otherwise the item is filed by what it is: Notes, Documents (› Spreadsheets / Presentations / Scans),
  Handwritten (GoodNotes), Images (› Screenshots), Audio (› Voice notes), Videos, Links, Reading,
  Recipes, Shopping, Places, Events, Code, Bookmarks (› the bookmark folder), Highlights (› the book),
  Email, Receipts, Files.
- When enrichment sets a new category, an item still filed by the organiser (`folderAuto`) moves to
  match (a link that turns out to be a recipe goes to Recipes).
- "Tidy up" files every item that has no live folder.

**Wikilinks** are resolved by title (`Links.swift`, `web/public/core/links.js`,
`Fixtures/links-cases.json`):
- Matching ignores case. When two items share a title, the newest wins, then the smallest id.
- `[[Title|label]]` and `[[Title#heading]]` link to `Title`.
- Links inside code are ignored.

**Text history** needs no extra data: every `text` op on `body` is a saved state. Clients show them
newest first, one per editing session (same device, edits less than 2 minutes apart).

**Inbox imports** (§4) use the item id `inbox-<relay entry id, lowercased>`. When the website and an
app import the same entry at the same time, they write the same item rather than two.
