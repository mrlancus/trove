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
- **Stray items:** a record of kind `item` with neither a `kind` field nor `createdAt` was made only
  by edits (or a delete without `k`) aimed at an id that never was an item. Clients leave it out of
  the library. Writers send `k` on deletes (the record's own kind) and never `set` item fields on an
  id that has no item record.

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
| `GET/POST /vaults/:v/bridges`, `GET/PUT/DELETE /vaults/:v/bridges/:id`, `POST …/:id/run`, `POST …/:id/regenerate` | device | Bridges (below) |
| `POST /hook/:v/:secret` | the secret in the path | a bridge's incoming address: webhook "add" URL or Telegram bot (below) |
| `POST /vaults/:v/preview` | device | `{url}` → `{url, title, description, image, site, icon}` link preview (below) |
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
header = { "v":1, "source":"email|webdav|web|ios|other|rss|github|telegram|webhook", "receivedAt": ISO8601,
           "name"?: "file.pdf", "mime"?: "application/pdf", "url"?: "…", "title"?: "…",
           "groupId"?: "…" (links an email to its attachments),
           "folder"?: ["Feeds", "Tech Daily"] (bridges: folder path hint), "tags"?: ["github", "cli"] (bridges),
           "meta"?: {…} }
```
Readers ignore fields they don't know, so older apps import bridge entries as plain links, notes and
files (without the folder and tags).

### WebDAV (for GoodNotes Auto Backup)
- **Address:** `https://<worker>/dav/`. Basic auth: username = vaultId, password = an inbox token.
- **Supported:** `OPTIONS`, `PROPFIND` (depth 0/1), `MKCOL`, `PUT`, `HEAD`, `DELETE`, `MOVE`, `LOCK`/`UNLOCK` (fake locks).
- **How uploads are handled:** a `PUT` is sealed straight into the inbox, with `davPath` recorded. The server keeps only path, size and etag, so `PROPFIND` can list what was uploaded. A newer upload of the same path supersedes the older one on import.
- **Privacy caveat:** notebook *file names* are visible to the server. The contents are not.

### Bridges
Bridges connect outside services to Trove **one way, into the inbox**. The relay fetches or receives
something public (a feed, GitHub stars, a Telegram message, a webhook post), seals it with the vault's
public key like email-in does, and devices import it as usual. The relay never reads the vault; it
keeps only each bridge's settings, its status and the ids it has already sent.

**API** (device token):

| Method & path | Body → Response |
|---|---|
| `GET /vaults/:v/bridges` | → `{bridges:[Bridge], kinds:["webhook","rss","github","telegram"]}` |
| `POST /vaults/:v/bridges` | `{kind, enabled?, settings, token?}` → `201 Bridge` |
| `GET /vaults/:v/bridges/:id` | → `Bridge` |
| `PUT /vaults/:v/bridges/:id` | `{enabled?, settings?, token?}` (GitHub only: `token: ""` removes it) → `Bridge` |
| `DELETE /vaults/:v/bridges/:id` | → `204` (a Telegram bot's webhook is removed too) |
| `POST /vaults/:v/bridges/:id/run` | run a feed or GitHub bridge now (at most every 2 minutes, else `429`) → `Bridge` |
| `POST /vaults/:v/bridges/:id/regenerate` | a new incoming address for a webhook or Telegram bridge; the old one stops working → `Bridge` |

`Bridge` = `{id, kind, enabled, settings, hasToken, createdAt, status:{lastRunAt, nextRunAt, lastError,
lastErrorAt, itemsAdded, lastAddedAt}}` (times are Unix ms or `null`), plus `hookURL` (webhook),
`title` (rss: the feed's own title) and `telegram:{bot, linked, linkURL}` (telegram). Tokens are
write-only: no response contains them. At most 40 bridges per vault.

| kind | settings | What it adds |
|---|---|---|
| `webhook` | `{name, folder, tags[]}` | Each `POST hookURL` (see below) |
| `rss` | `{url, name, folder (default "Feeds")}` | New posts of an RSS 0.9x/1.0/2.0 or Atom feed as links, into `folder/<feed name>`. The first run adds the newest 5, later runs every new post (at most 25 a run). Checked every 2 hours with `If-None-Match`/`If-Modified-Since` |
| `github` | `{username, stars (true), releases (false), folder (default "GitHub")}`, optional `token` | Public stars as links into `GitHub/Stars` with the description, language and topics as the note and `github` + topics + language as tags (the first runs page back through older stars). With `releases`, new releases of the user's own public repos into `GitHub/Releases`. Checked every 6 hours |
| `telegram` | `{folder, tags[]}`, required `token` (from BotFather) | Messages to the bot from the linked chat: text as notes, the first link as a link (the message as its note), photos (largest size) and files up to 20 MB as attachments |

**Incoming: `POST /hook/:vaultId/:secret`.** `secret` is `thk_` + 43 base64url characters and is the
only credential, like an inbox token (`regenerate` replaces it).
- *Webhook*: a JSON object, a form (`application/x-www-form-urlencoded` or `multipart/form-data`) or
  plain text. Fields: `url`, `text`, `title`, `tags` (array or comma/space separated), `folder`
  ("A/B"), `file` (multipart, 20 MB at most). A body that is just a link is saved as that link.
  `201 {ok, added}`; `400` with nothing to save, `403` when the bridge is off, `404` for an unknown
  secret, `429` after 120 posts in an hour.
- *Telegram*: the relay calls `setWebhook` with this address and `secret_token` = the secret, and
  checks the `X-Telegram-Bot-Api-Secret-Token` header. Until a chat is linked, only the message
  `/start <linkCode>` (sent by opening `telegram.linkURL`) is accepted; it links that chat, and
  messages from any other chat are ignored. The bot answers "Saved to Trove." Telegram always gets
  `200` (it retries anything else); problems are recorded in `status.lastError`.

**Inbox entries from bridges** use `source` `rss`, `github`, `telegram` or `webhook` and
`meta.bridge` = the bridge id (`meta` also carries `feed`, `repo`, `chat`… for display). Bodies are
plain text (`mime: "text/plain"`) for links and notes. Importers (`Library.importInbox`,
`Vault.importEnvelope`, checked by `Fixtures/inbox-bridges.json`):
- they treat these like `other` (item `source` `share`) and store `origin.bridge` = the entry's source;
- `folder` (an array, or a string split on `/`; empty parts dropped, at most 5 deep) files a *new* item
  there with `folderAuto: false`, so enrichment won't move it; an existing item (the same link saved
  before) keeps its folder;
- `tags` (lowercased, `#` dropped, no repeats) are added to the item's tags, new or existing.

**Running.** Feed and GitHub bridges run on the vault's Durable Object alarm (shared with price
watches) at most 9 outside fetches per run, so a run plus price checks stays under the free plan's 50
subrequests. A failing bridge backs off (2×, 4×, … its interval, at most a day) and shows the error;
a success clears it. Turning a bridge back on, or changing its feed or user, runs it within seconds
(a changed feed or user starts over).

**Tokens** (Telegram bot, optional GitHub token) are stored by the relay because it must use them while
devices sleep. They are encrypted at rest with AES-256-GCM under a key from the Worker secret
`BRIDGE_KEY` (HKDF-SHA256, salt = vault id, info `trove/v1/bridge-token`) when that secret is set, and
otherwise kept in the Durable Object's storage, which Cloudflare encrypts at rest. A GitHub token should
be a fine-grained, read-only token with no repository access (public data only); without one the
relay uses GitHub's anonymous limit (60 requests an hour, shared).

**Link previews.** `POST /vaults/:v/preview {url}` fetches a page for a device (browsers can't fetch
other sites) and returns `{url (after redirects), title, description, image, site, icon}` from Open
Graph, Twitter and plain HTML tags (any may be `null`). A page that can't be fetched still answers
`200`, with every field `null` plus `error` (and `refused: true` when the URL wasn't allowed), so
browsers don't log background previews as errors. The relay sees that URL, nothing else. It
refuses non-http(s) URLs, user:password URLs, ports other than 80/443/8080/8443, `localhost`,
single-label and `.local`/`.internal`/`.lan`/`.home.arpa` names, IP literals in private, loopback,
link-local, CGNAT and multicast ranges, and IPv6 literals, re-checks every redirect (at most
4), stops after 8 seconds and reads at most 512 KB. 240 previews an hour per vault (`429`). Feeds are
fetched under the same rules.

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
| `sourceBundle`, `sourceURL`, `sourceTitle` | the app's bundle id, and the web page (or document) it was copied from, when known |
| `pinned` | pinned clips are never pruned |
| `savedItem` | the library item the clip was saved as |
| `autoTitle`, `stats`, `entities` | worked out by the device that made the clip (below) |
| `title`, `tags`, `note`, `editedAt` | the user's name for it ("" = none), tags (lowercase, no `#`), a note, when the text was last edited |
| `aiTitle`, `summary`, `ocrText`, `enrichment`, `needsEnrichment` | enrichment, as for items (§5): an AI title, a one-line summary, text found in an image |
| `uses` | how many times it was copied again or pasted from history |
| `links` | ids of other clips and library items it's connected to |

- **Insights:** `autoTitle` is the link's host (without `www.`) and path, `"Colour " + text`, a
  path's last component, `"JSON"`, or the first non-empty line with its whitespace collapsed, cut to
  60 characters at a word past the middle plus `…`. `stats` is `{chars, words, lines}` (chars are
  Unicode scalars). `entities` is `{links, emails, phones, colors, hashtags}`, each unique and at most
  20; colours are lowercased `#rgb`/`#rrggbb` and aren't hashtags. `ClipInsights.swift` and
  `clips.js insights` both check `Fixtures/clip-cases.json` (made by `web/test/make-clip-fixture.mjs`).
- **Rule tags:** a new or edited text clip gets the built-in rules' tags in `tags` (merged with
  what's there): the kind (`link`, `email`, `phone`, `colour`, `json`, `path`, `code`), a link's site
  (`github` for github.com, `bbc` for bbc.co.uk), code's language (`swift`, `python`, `javascript`,
  `sql`, `html`, `c`, `rust`), `contact` for prose with an email or phone number, then hashtags;
  unique, at most 8 (`ClipInsights.ruleTags` / `clips.js ruleTags`, same fixture under `rules`).
- **Enrichment:** devices with Vision read the text in image clips (`ocrText`, and the entities of
  that text). Then the best tier the device has names, summarises and tags the clip: on-device AI,
  cloud AI (opt-in), or the rules (for an image, its first line of text becomes `aiTitle`). A clip
  is picked up while `needsEnrichment` is true, or, by a device with AI, while only the rules have
  seen it (`enrichment.tier == 0`) and it's less than 14 days old.
- **Settings:** one synced record, id `settings.clipboard`, kind `setting`: `autoSave` is a sorted
  list of clip kinds (`link`, `image`, `code`, `text`, …). The device that records a new clip of one of
  those kinds saves it to the library at once (below). `keepDays` and `keepCount` say how much
  history to keep (numbers; 0 = no limit; missing = 30 days and 1,000 clips).
- **Shared app settings:** one synced record, id `settings.app`, kind `setting`, booleans that
  every device follows: `clipboardHistory`, `holdSensitive` (the preference; held copies still
  never leave the device), `saveCopiesOnOpen` (iPhone/iPad), `recordPages` and `autoUpdate`
  (Mac), `cloudAI`, `recordPlaces`. A missing field means the default (all on, except `cloudAI`). A device whose
  own value differs from the default before the field exists writes it once. Things that belong
  to one machine (folder paths, permissions, layout) aren't shared.
- **Tags with colours:** one synced record, id `settings.tags`, kind `setting`. Each field is a tag
  (lowercase, no `#`, spaces turned into `-`, never starting with `_`) and its value a colour name:
  `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `blue`, `indigo`, `purple`, `pink`, `brown`,
  `gray` (anything else reads as `gray`). `null` removes the tag; removing also takes the tag off
  every clip and item. Tags in this record are "your tags": the clipboard shows them as sections
  to filter by, and they colour the tag wherever it appears. One field per tag, so two devices
  adding different tags at once both keep theirs.
- **Search:** words must all appear (case and accents ignored) in the text, titles, note, tags,
  OCR text, app, device, page and file names; `tag:x` or `#x` keeps clips with that tag, `app:x`
  clips from that app, `is:pinned` pinned ones (`ClipQuery`, `clips.js parseClipQuery`).
- **Title shown:** `title`, else `aiTitle`, else the image's name, the files' names, or `autoTitle`.
- **Editing text** sets `text`, `hash`, `editedAt`, fresh insights and `needsEnrichment: true`, and
  clears `aiTitle` and `summary`. The user's `title`, `tags` and `note` stay.
- **Saving to the library** makes a link, note (text plus the note) or file item with
  `source: "clipboard"`, the clip's title, tags, summary and OCR text, and
  `origin: {clip, app?, url?, title?}`.
- **De-duplication:** copying something whose `hash` matches an existing clip just sets that clip's
  `lastUsedAt`, `uses + 1` (and `sourceApp` and the source fields).
- **Pruning:** any device may delete unpinned clips last used more than `keepDays` days ago or
  beyond the newest `keepCount` (settings above; 30 days and 1,000 when unset). Builds from before
  this setting always use 30 days and 1,000, so every device needs a current build.
- **Never stored:** copies marked concealed or transient (nspasteboard.org types), copies from
  password managers, and text that looks sensitive (passwords, API keys, private keys, one-time
  codes) are never written as clips. The Mac holds sensitive copies in memory for two minutes only.
  The rules live in `Clip.swift` (`SensitiveDetector`) and `web/public/core/clips.js`, and their
  tests are kept in step.
- **Copy and paste events:** each copy, paste or reuse is its own record, kind `clipEvent`, so two
  devices recording at once never overwrite each other: `clip` (the clip's id), `type` (`copy`,
  `paste` into another app, or `use`: copied back out of Trove's history), `at` (Unix ms), `device`,
  `deviceName`, and when known `app`, `bundle`, `url` (the page), `title` (window or page title) and
  `place` `{lat, lon, accuracy?, name?, city?}`: where the device was, from its own location
  (CoreLocation, the browser's geolocation), never an IP address; 5 decimal places, accuracy in
  metres, `name`/`city` looked up by Apple devices. Places are recorded while the shared setting
  `recordPlaces` (in `settings.app`, on unless turned off) is on. Deleting or pruning a clip deletes
  its events. A copy that only bumps an existing clip still gets its own `copy` event.
- **The clipboard map** joins clips to where they were copied from (the site for a page, else the
  app), where they were pasted, their places (by `name`, else position rounded to 3 decimals), days
  and tags, and to connected clips and items (`core/clipmap.js`, `ClipEvents.swift`; both check
  `Fixtures/clip-events.json`, made by `web/test/make-clip-events-fixture.mjs`).
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
| `alsoFrom` | other sources (`ItemSource` values) the same thing arrived from later. When a link that's already saved comes in again from somewhere else, the existing item gains that source instead of a duplicate being made, so "Sources" lists it under every source it came from (`source` stays the first one). An item whose attachment (or an earlier version of it) is a `.goodnotes` file is also listed under `goodnotes`, however it arrived (`Item.sources`, `items.js itemView`) |

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

## 10. Drawing (sketches and ink on files)
Every stroke is its own record with `kind: "stroke"` (`Ink.swift`, `web/public/core/ink.js`, both
checked against `Fixtures/ink-cases.json`). Two devices drawing at once just add strokes, erasing
is a delete (`_deleted: true`), and undo deletes your last stroke. Fields (all `set`):

| Field | Meaning |
|---|---|
| `on` | the item id the ink belongs to |
| `layer` | `""` for a sketch's own pages; the attachment id of a file (PDF or image) drawn on |
| `page` | a file's 0-based page (a PDF page, or 0 for an image); on a sketch, the page's id (a string; a number n means the page `"n"`) |
| `tool` | `pen`, `pencil`, `marker`, `highlighter`, `fountain` or `brush` |
| `shape` | optional: the clean shape it was snapped to (`line`, `polyline`, `triangle`, `rectangle`, `polygon`, `circle`, `ellipse`); drawn as straight segments at even width |
| `color` | `"#rrggbb"` |
| `width` | full width in page points |
| `points` | base64url of little-endian float32 quadruples `x, y, pressure (0…1), t (ms since the stroke began)` |
| `createdAt` | Unix ms; strokes draw in this order (each new stroke on an item gets a later time than the last) |
| `device` | device id |

- **Coordinates** are page points: a PDF page's points, an image's pixels, or a sketch page
  (768 × 1024 unless the item's `pageSize` says otherwise).
- **Look**: pen and pencil widths follow pressure (`width × (0.35 + 0.65 × pressure)`), brushes
  `width × (0.15 + 0.85 × pressure)` tapering over their first and last 15 % of points, and fountain
  pens `width × (0.25 + 0.75 × |sin(direction − 45°)|) × (0.6 + 0.4 × pressure)`, where the
  direction runs from the previous to the next point. Markers and highlighters are even. Opacity:
  pencil 0.85, highlighter 0.35 (blended under the ink), others 1.
- **Drawing order**: pictures, then strokes, then text boxes, each by `createdAt` (a new stroke or
  element gets a later time than anything on the item).
- **Partial eraser**: a crossed stroke is deleted and replaced by the pieces outside the eraser (a
  circle of the eraser's radius plus half the stroke's width moved along its path, with segments cut
  to half the radius first; pieces of fewer than 2 points go). Pieces keep the stroke's `createdAt`.
  The highlighter eraser only touches `highlighter` strokes.
- **Lasso**: picks strokes with at least half their points inside the loop (even-odd rule) and
  elements whose centre is inside. Moving and resizing rewrite `points` (x' = ox + (x − ox)·sx + dx)
  and multiply `width` by √(sx·sy); recolouring sets `color`; duplicating adds copies 20 points
  down and right.
- **Shapes**: `InkShapes.swift` / `recognizeShape` in ink.js. Open drawings: a line if no point is
  further than 8 % of the ends' distance from it, else up to 3 straight pieces (Ramer–Douglas–Peucker
  at 8 % of the diagonal). Closed ones (ends within 20 % of the diagonal): an ellipse (a circle when
  the radii are within 12 %) or the polygon through the corners (RDP at 10 %), whichever fits closer;
  a near-upright quadrilateral snaps to its box. The geometry is checked by both sides against
  `Fixtures/ink-geometry.json` (made by `web/test/make-ink-fixture.mjs`).
- **The file under the ink never changes.** Ink on a new version of a file (a new attachment id) starts
  empty; the old version keeps its ink.
- **GoodNotes notebooks** (`.goodnotes`, docs/GOODNOTES.md) can be drawn on like files, page n being
  the notebook's page n. The first time one is opened in the editor, its handwriting, shapes and
  typed text are copied into Trove strokes and text elements on that layer (`editableInk` in
  core/goodnotes.js, `GoodNotesInk.editableInk` in Swift, checked against `Fixtures/ink-expected.json`:
  page points = GoodNotes units × 72/132; each pen-down run is a stroke; a highlighter (alpha < 0.95)
  becomes `highlighter`, a pencil `pencil`, the rest `pen`; a pen's `width` is its widest point and
  `pressure` = (point width / width − 0.35) / 0.65; highlighters and shapes are even with pressure 0.5,
  and a shape gets `shape` `line` (2 points), `polygon` (closed) or `polyline`). The item's
  `goodnotesInk` (array of attachment ids) records it, so it's never copied twice and viewers then
  draw the notebook's background, pictures and shape fills with Trove's ink and text on top instead
  of GoodNotes' own.

**Sketch items** have `kind: "sketch"` and are filed in "Sketches". Extra fields:
- `paper`: one of `blank`, `lined`, `narrow` (24 apart), `wide` (40), `margin` (lined with a red
  margin at x 72 and header line), `grid`, `smallgrid` (16), `graph` (8, every fifth bold),
  `dotted`, `smalldots` (16), `isometric` (dots in a triangular lattice 24 apart), `cornell` (lined,
  a cue column at 28 % of the width and a summary area below 80 % of the height), `todo` (lines 40
  apart with a box to tick), `planner` (a week: seven lined bands), `storyboard` (six 4:3 frames
  with note lines), `music` (five lines 8 apart, a stave every 80) or `calligraphy` (groups of four
  handwriting guides, 96 apart). Lines are 32 points apart unless noted. The exact lines and dots
  are `paperShapes` (core/ink.js) and `InkPaperShapes` (Swift), checked against
  `Fixtures/ink-papers.json` (made by `web/test/make-paper-fixture.mjs`). Unknown papers draw blank.
- `pages`: the page count. `pageList`: the pages in order, `[{id, paper?, color?, size?}]` (a page's
  own paper, `"#rrggbb"` colour (white when unset) and `[w, h]` size in points (36–4000 a side; the
  sketch's `pageSize` when unset)). Without `pageList` the pages are `"0"` … `"pages-1"`.
  Adding (with the size, paper and colour of the page before), duplicating (with everything on the
  page), reordering and deleting pages rewrite the list; the last page can't be deleted. Two
  devices changing the list at once: the last write wins.
- `pageSize` `[w, h]` (optional, 768 × 1024 when unset), and `canvas`: `"infinite"` for one endless
  page `"0"` (any coordinates, paper drawn everywhere; papers that lay out a page are plain lined
  there) instead of pages. Named sizes (scaled so pages are about 768 points wide): iPad 768 × 1024,
  A4 768 × 1086, A5 543 × 768, US Letter 791 × 1024, US Legal 791 × 1303, square 768 × 768,
  16:9 576 × 1024 and phone 473 × 1024, portrait; landscape swaps them.
- `sketchText`: the words in its text boxes (rewritten when they change), and `inkText`: handwriting
  an Apple device read off the pages (Vision). Search covers both.

**Elements** (`kind: "element"`) are text boxes and pictures, on a sketch page or a file like
strokes (`on`, `layer`, `page`, `createdAt`, `device`), with `type` (`text` or `image`) and a box
`x`, `y`, `w`, `h` in page points. Text has `text`, `size` (points) and `color`, wrapped to `w`
with lines 1.25 × size apart. Pictures have `image` (an attachment, stored as a blob).
