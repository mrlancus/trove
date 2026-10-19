# Trove: research report
*Working name. A "save anything" brain and notes app that plugs into the apps you already use.*

Researched October 2026. Sources are listed at the bottom. Where a fact couldn't be confirmed, it's marked **(verify)**, and the build prompt tells Claude to check it before relying on it.

---

## 1. The idea in one paragraph

Trove is one place for everything you want to keep. That covers links, screenshots, photos, PDFs, voice notes, highlights, emails and proper written notes. The difference from other apps:
- **It organizes itself.** It reads text in images, pulls out dates, places, prices and recipes, tags and summarizes, and finds things by meaning.
- **It sits on top of the notes apps you already use.** It imports and searches Apple Notes, GoodNotes handwriting, Obsidian vaults, Notion, Kindle and Readwise, so you aren't forced to move everything.
- **It works on old devices.** The clever features come in tiers, so an iPhone without Apple Intelligence still gets most of them.
- **It syncs for free through your own iCloud Drive**, with an optional Cloudflare relay for instant sync and server features.
- **It looks Apple-made.**

---

## 2. Who it competes with and how Trove wins

| App | What it's good at | Where it falls short (Trove's opening) |
|---|---|---|
| **mymind** | Beautiful auto-organizing "save anything" | Paid only (about $5–8/mo), cloud-hosted, no real notes editor, doesn't integrate with your other apps |
| **Obsidian** | Local Markdown notes, plugins, linking | Not a capture tool; saving a link or screenshot is manual. Its iCloud sync is famously flaky on iOS, and Obsidian Sync is paid |
| **Apple Notes** | Built-in, fast, iCloud | No auto-organizing, weak search across media, no API on iOS (Markdown export only arrived in iOS 26) |
| **Capacities / Anytype** | Structured "objects" and local-first | Steep learning curve, not Apple-native in feel, AI is bolted on |
| **Raindrop / Karakeep / Readwise Reader** | Bookmarks and read-later | Focused on links, not a whole brain. Karakeep's iOS app was still listed as planned |
| **DoubleMemory** | Apple-native capture | Small and limited |

**Trove's angle:** mymind's magic, Obsidian's ownership, Apple Notes' polish, and it connects to the apps you already use.

---

## 3. Your big question: what happens on devices without on-device AI?

### Who has Apple's on-device AI?
- **Apple Intelligence** (and the free **Foundation Models** framework that lets apps use it):
  - iPhone 15 Pro and newer
  - iPads with M1 or newer, or the A17 Pro iPad mini
  - Macs with M1 or newer
  - It needs about 7 GB free and OS 26 or newer.
- **Everything else has no on-device LLM.** That includes iPhone 11–15 (non-Pro), iPhone SE models, Intel Macs, and anything that can't update.
- The on-device model is small (about 3B parameters) with roughly a **4K-token context**. It's great for summaries and tags, but not for reading 50 documents at once **(verify the limits)**.

### The answer: four tiers, and most of the magic needs no AI at all

**Tier 0: every device, no AI needed (this does about 70% of the work).** These are classic Apple frameworks that run on any iPhone or Mac:

| What | How | Works on |
|---|---|---|
| Text in screenshots, photos, PDFs and handwriting | Vision text recognition (handwriting since iOS 15; document structure such as tables and lists with the newer `RecognizeDocumentsRequest` on 26+) | All |
| Dates, times, addresses, phone numbers, links, flight numbers | `NSDataDetector` | All |
| People, places and organisations in text | `NLTagger` named entities | All |
| **Search by meaning** ("blue chair") | `NLEmbedding` sentence embeddings, plus image "feature prints" for similar images | All |
| Image labels (dog, receipt, food, document…) | Vision image classification | All |
| Recipes, products and prices, events, articles from web pages | **schema.org JSON-LD** structured data embedded in most sites, plus a reader-mode text extractor. No AI needed and very accurate. | All |
| Link titles and preview images | `LinkPresentation` | All |
| Voice notes to text | `SFSpeechRecognizer` on-device (older devices); the new `SpeechAnalyzer` on 26+ (seems to need a newer Neural Engine: works on iPhone 12+, not SE 2 **(verify)**) | All / most |
| Auto-tags | Rules plus entity types plus domain ("youtube.com" becomes Video, a Recipe schema becomes Recipe) | All |

**Tier 1: Apple Intelligence devices (free, private, on-device).** These use the Foundation Models framework:
- Smart titles.
- 1–3 sentence summaries.
- Tag suggestions using "guided generation", where the model fills a Swift struct, so the output is reliable.
- Extracting tasks from notes.
- "Ask Trove" answers over the top search results, with citations. This uses RAG (retrieval-augmented generation), which fits the small context window.

**Tier 2: your iPad is the AI helper for your iPhone and Mac.** Your iPad is your only Apple Intelligence device, so it becomes the "brain" for the others:
- Items saved on the iPhone or Mac are marked "needs enrichment".
- When the iPad sees them through sync, it runs Tier 1 on them and syncs the results back: the summary, title, tags and image descriptions. Everything stays **end-to-end encrypted**, because the iPad has the key.
- **When it runs:**
  - Instantly while Trove is open on the iPad.
  - Overnight when the iPad is **plugged in**, using a background processing task that requires external power.

  Apple engineers say the on-device model isn't rate-limited on power, but it *is* limited in the background on battery. So "plug the iPad in at night and it catches up on the day's saves" is the reliable pattern.
- Anything urgent can't wait for the iPad, such as an "Ask Trove" question on the iPhone. That falls back to Tier 0 search results, or to Tier 3 if you've turned it on.

**Tier 3: cloud AI, opt-in only, for when no device is capable.**
- **Cloudflare Workers AI** has a free allowance of **10,000 "neurons" a day**, shared across all models. Its models cover summarizing, embeddings, speech-to-text and image captioning, though the catalog changes, so check the models list.
- **Or bring your own API key** (Claude, OpenAI, or Gemini's free tier). Requests go straight from your device to that provider.
- **Trade-off, stated honestly:** cloud AI has to see the content, which breaks end-to-end encryption for that item. So it's **off by default**, can be switched on per item or per collection, and shows a small "☁︎ processed in cloud" badge.

### What cloud AI actually costs (October 2026 prices)
Assumptions per saved item: about 1,500 tokens in (the extracted text plus instructions) and about 200 tokens out (title, summary and tags).

| Option | Per item | 1,000 items/month | One-off import of 5,000 old notes | "Ask Trove" question (about 8k tokens of context) |
|---|---|---|---|---|
| **Cloudflare Workers AI**, Gemma 4 26B (does text, vision and tools) | ~19 neurons | **Free.** The 10k neurons/day free allowance covers about 500 items a day | Free, spread over about 10 days, or roughly $1 on the paid plan | ~80 neurons, so about 100 free questions a day |
| **Claude Haiku 5.5** ($0.10 in / $0.50 out per million tokens) | ~$0.00025 | **~$0.25** | ~$1.25, or ~$0.63 with the Batch API (50% off) | ~$0.001 |
| **Claude Sonnet 5.5** ($2 / $10 per million tokens) | ~$0.005 | ~$5 | ~$25 (~$12.50 batched) | ~$0.02 |
| Cloudflare Whisper (voice notes) | $0.0005/min, about 47 neurons/min | Free up to about 200 minutes a day | – | – |
| Cloudflare bge-m3 embeddings | ~0.5 neurons per item | Free | Free | – |

**Bottom line:**
- **Cloudflare AI is effectively free** for one person.
- **Claude Haiku 5.5 costs pennies a month** and is noticeably smarter.
- **Suggested setup:**
  - Haiku 5.5 for summaries, tags and Ask Trove.
  - Cloudflare for transcription and embeddings.
  - The iPad for everything it can do for free.

**Things to know about the Claude API:**
- It's **billed separately from your Claude Pro subscriptions**. You add prepaid credit in the Claude Console, and Pro doesn't include API usage.
- Haiku 5.5 thinks by default, so set effort to `low` for tagging to keep output tokens (and cost) down.
- To exceed Cloudflare's free 10k neurons a day, you need the Workers Paid plan. Above the allowance it's $0.011 per 1,000 neurons.
- **Where the API key lives:** keep it on the Worker as a secret and have the apps call the Worker. Don't put the key inside the apps.

### Design rules that make this work
- **Search indexes are built on each device and never synced.** Different devices may use different models, so each one builds its own index from the synced content. Old devices therefore always have working search.
- **AI *results* are synced**, such as summaries, titles, tags and transcripts, tagged with which device or model made them. One capable device benefits all the others.
- Every AI feature has a non-AI fallback, so the UI never shows broken buttons, just slightly less magic.

### Feature × tier matrix
| Feature | T0 (any) | T1 (Apple Intelligence) | T2 (Mac helper) | T3 (cloud, opt-in) |
|---|---|---|---|---|
| OCR / text in images | ✅ | ✅ | – | – |
| Semantic search | ✅ (NLEmbedding) | ✅ | – | ✅ better embeddings |
| Auto-tags | ✅ rules and entities | ✅ smarter | ✅ | ✅ |
| Summaries / smart titles | ⚠️ first lines / page description | ✅ | ✅ | ✅ |
| Ask Trove (Q&A) | ⚠️ search results only | ✅ | ✅ (ask on Mac) | ✅ |
| Voice transcription | ✅ | ✅ better | – | ✅ Whisper |
| Image descriptions | ⚠️ labels only | ✅ | ✅ | ✅ |

### Which OS versions to support
- **iOS 26** runs on iPhone 11 and later. **iOS 18** also covers the XR, XS and XS Max.
- **macOS 26 (Tahoe)** was the last version to support Intel, and only on four Intel models. **macOS 27** is Apple silicon only.
- **Recommendation:** support **iOS 18+ and macOS 15+** so old devices work. Turn on Liquid Glass design, Foundation Models and SpeechAnalyzer automatically where available. Decide based on your oldest device.
- **Bonus:** a **web app** version (Phase 6) works in any browser, including Windows, Android or a really old Mac. It decrypts in the browser, so it's still end-to-end encrypted.

---

## 4. Sync: iCloud, the free workarounds, and the recommendation

**Your question: can we just save everything into an iCloud folder? Yes.** The naive way is flaky. Obsidian's forums are full of iOS conflicts, files evicted from the device, and "(1)" duplicates. But a smarter file layout avoids almost all of that.

### The "iCloud Drive vault" design (free, uses your normal iCloud storage)
- Everything lives in **one folder in your iCloud Drive**, for example `iCloud Drive/Trove/`.
- **No two devices ever write the same file**, which is what causes iCloud conflicts:
  - Each device appends its changes to **its own journal files** (`Trove/.sync/<device>/000123.log`).
  - Every device reads everyone's journals and merges them, using a CRDT for note text.
- **Attachments** (images, PDFs, audio) are saved under names derived from their content (a hash), so they never clash either.
- A **readable Markdown copy** of every note is written to `Trove/Notes/` for Obsidian, Files and backups. Only one device (the Mac) writes these, to avoid conflicts.
- iCloud does the uploading and downloading itself in the background, **even when Trove is closed**. That's a nice advantage over a server.
- To stop iOS deleting local copies, set **"Keep Downloaded"** on the folder (Files app or Finder). The app also requests downloads when it needs a file.
- **Encryption is optional:**
  - With it on, the journals and attachments are encrypted with your vault key.
  - With it off, Apple's standard iCloud encryption applies, or end-to-end if you've enabled Advanced Data Protection.
- **Storage** comes out of your iCloud plan (5 GB free, or whatever iCloud+ you pay for). No Cloudflare 10 GB limit.

**How each device gets in:**
- **Mac:** the app simply uses `~/Library/Mobile Documents/com~apple~CloudDocs/Trove`. This is just a normal folder, so it works on a free account. ✅
- **iPhone and iPad:** you pick the Trove folder once in the Files picker, and the app keeps permission with a "security-scoped bookmark". You do this once per device. Apple's current docs on folder access don't mention needing the paid iCloud capability, but an old Apple guide says the picker needed it for iCloud Drive. **This is the one thing to test first (about 10 minutes, in Phase 0).** If it fails on a free account, the iPhone and iPad sync through Cloudflare instead and the Mac bridges to iCloud.

### Options compared
| Option | Cost | Live? | Reliability | Verdict |
|---|---|---|---|---|
| **iCloud Drive vault** (design above) | Free, uses your iCloud storage | No: usually seconds to a minute, and the iPhone catches up when Trove opens | Good with the per-device journal design | ✅ **Main storage**, which is what you asked for |
| **Cloudflare relay** (Workers + Durable Objects + R2) | Free | Yes: about 1 second | Great | ✅ **Optional add-on** for instant sync, and needed anyway for email-in, GoodNotes WebDAV, price checks, cloud AI and the web app |
| **CloudKit** | $99/yr developer account | Yes, with push | Best | Later, if you ever pay. Sync stays swappable. |

**Recommendation:** use the iCloud Drive vault as the source of truth. Turn on the Cloudflare relay when you want instant sync or the server features. Both carry the same change journals, so they can run side by side.

### Cloudflare free-tier budget (personal use fits easily)
| Service | Free allowance | Trove uses it for |
|---|---|---|
| Workers | 100k requests/day | API |
| Durable Objects (SQLite) | 100k requests/day, WebSocket hibernation | Live sync hub plus encrypted change log, one per vault |
| R2 | 10 GB storage, 1M writes/month, 10M reads/month, free downloads | Encrypted images, PDFs, audio |
| D1 | 5M rows read/day, 100k written/day, 5 GB | Optional (the Durable Object may be enough) |
| Email Routing + Email Workers | Free (needs a domain on Cloudflare, about $10/yr) | "Email anything to your Trove" |
| Workers AI | 10k neurons/day | Optional Tier 3 AI |

**R2's 10 GB limit matters less now.** Your files live in iCloud, so R2 only holds relay copies and inbox uploads (email, GoodNotes), and those can be cleared once they've landed in iCloud.

### Encryption design (Cloudflare can never read your stuff)
- One vault key is created on your first device and stored in the Keychain.
- Everything is encrypted on the device before upload (AES-GCM, CryptoKit).
- **Pairing a device:** your Mac shows a QR code and your phone scans it, which transfers the key.
- **Recovery key:** a printable or saveable code shown at setup. Without it, losing all your devices means losing the data. The app has to be clear about this.
- **Server-side inbox** for email-in and GoodNotes backups: the vault also has a *public* key, and the Worker encrypts incoming emails and PDFs with it (a "sealed box") before storing them. The server can lock things but never unlock them.

### Two devices editing the same note offline
- Small fields such as tags, pins and titles use "last write wins".
- **Note bodies** use a CRDT (**Automerge** has Swift bindings and was still active in 2026), so edits merge cleanly. The fallback is a 3-way merge plus a visible "conflict copy" (never silent data loss).

---

## 5. Integrations: what's actually possible (honest version)

| App | What's possible | How Trove does it |
|---|---|---|
| **Apple Notes** | **Mac:** AppleScript/JXA can read notes (as HTML) and create notes. It can't read attachments or locked notes, and needs Automation permission. Reading the Notes database directly is encrypted/fragile, so don't. **iOS:** no API. Shortcuts' "Find Notes" gives plain text only, with result caps and filter bugs in iOS 18.5. iOS 26 added **"Export as Markdown"** in the share sheet. | **Mac:** "Notes bridge". Auto-import and refresh Apple Notes into Trove's search (read-only mirror) with an "Open in Notes" button, and save any Trove item *to* Apple Notes. **iOS:** Share → "Export as Markdown" → Trove, plus an "Import from Notes" Shortcut. Not a 2-way sync, which would be fragile. |
| **GoodNotes** | GoodNotes **Auto Backup (iOS)** can upload PDFs to **WebDAV**, Dropbox, Google Drive or OneDrive. iCloud Drive isn't supported. It's one-way. | **Trick:** the Cloudflare Worker exposes a tiny **WebDAV endpoint**. You point GoodNotes Auto Backup at it, and every notebook arrives as a PDF, sealed-box encrypted. Your devices then OCR the handwriting, making it searchable alongside everything else. Alternative: Dropbox, with the Mac app reading the local Dropbox folder. |
| **Obsidian** | Obsidian is just Markdown files plus YAML front matter, `[[wikilinks]]` and an attachments folder. | **Vault bridge:** Trove can mirror notes **two-way** with an Obsidian vault folder (on Mac, watched with FSEvents), so you can use both apps on the same notes. Trove also stores notes as Markdown internally, so export is lossless. |
| **Notion** | Official API: a free "internal integration" token, and you share pages with it. There's a page-to-markdown endpoint **(verify)** and roughly 3 requests/s. | Import or keep-in-sync chosen Notion pages and databases (one-way into Trove). |
| **Kindle** | `My Clippings.txt` is on the Kindle device itself (over USB). | Built-in parser, so highlights become items, grouped by book. |
| **Readwise** | Export API with a personal token. | Optional import of all highlights, with incremental updates. |
| **Safari / Chrome** | Safari Web Extensions ship inside the app and work with a free Apple ID. Chrome extensions are easy. | Save page, selection or highlights, show an "already saved" badge, and capture the article text at save time so dead links don't matter. |
| **Email** | Cloudflare Email Routing → Email Worker (free). | `you@yourdomain` → forward newsletters, receipts, confirmations and PDFs. |
| **Photos** | PhotoKit, opt-in. | Auto-import new **screenshots**, OCR them, and optionally offer to delete the originals. |
| **Reminders / Calendar** | EventKit. | Tasks and events found in items become real reminders and events (with a link back). |
| **Spotlight / Siri / Shortcuts** | CoreSpotlight plus App Intents and App Entities. | Trove items show up in system search, and there are Shortcuts actions such as "Save to Trove", "Search Trove" and "Ask Trove". |
| **Your clipboard app** (the other project) | Same backend design. | A "Send to Trove" action, and both apps can share the same Cloudflare vault code. |
| **Imports** | mymind, Raindrop and Pocket exports (CSV/HTML), browser bookmarks HTML. | One-time importers. |

---

## 6. Full feature list

### Capture (anywhere, in under 2 seconds)
- Share sheet (iOS/Mac), Safari and Chrome extensions, Mac global hotkey quick-capture panel, menu bar.
- iOS widget, Control Center control, Action Button and Back Tap (through an App Intent).
- Email-in, screenshots auto-import, drag-and-drop on Mac, paste.
- Voice note button that records and transcribes.
- Scan documents (VisionKit document camera), which become searchable PDFs.

### Write (a real notes app, aiming to replace Apple Notes and Obsidian for daily use)
- Fast Markdown editor with live styling (like Bear), `[[links]]`, backlinks, tags, checklists, tables, code blocks.
- Daily notes, templates, slash commands, and embedding any saved item in a note.
- iPad: PencilKit sketches inside notes. Handwriting is OCR'd and searchable.

### Organize (automatic first, manual when you want)
- **Smart Collections** that build themselves: Recipes, Things to buy, Places, Articles, Videos, Receipts, Quotes, Ideas, To read.
- Spaces (Personal / Work / Uni). A Face ID-locked private space.
- Manual collections, pins, and multi-select drag and drop.

### Find
- One search across **everything**, including Apple Notes, GoodNotes handwriting and Obsidian files.
- Search by meaning, by text inside images and PDFs, and with filters (type, source, date, place, collection).
- "Similar items", and duplicate detection when saving.

### Resurface (so things don't rot)
- "On this day" and a daily digest widget.
- Spaced-repetition review of highlights and quotes, like Readwise.
- **Places map:** every saved place on a map, plus an optional "you saved a café 200 m from here" alert (geofences; iOS allows up to 20 at once).
- Price-drop alerts for saved products. A Worker cron re-checks the price from the page's product data. Be polite with request rates and respect site terms.

### Act
- Turn items into reminders or calendar events in one tap.
- "Ask Trove" with cited answers.
- Reader mode for articles: offline, with progress and highlights.

### Share and own
- Publish a note or collection to a public link (served by the Worker), optional.
- **Full export:** Markdown plus attachments zip. No lock-in, ever.

---

## 7. Free Apple ID: what works

- ✅ **Works:** iOS app, Mac app, share extension, widgets, Safari extension, App Intents, App Groups, Vision / NaturalLanguage / Speech, Foundation Models (no special entitlement needed **(verify)**).
- ❌ **Doesn't work:** CloudKit, push notifications, Siri entitlement (App Intents and Shortcuts still work).
- ⚠️ **Limits, confirmed on Apple's membership page and forums:**
  - iOS/iPadOS apps must be re-run from Xcode every **7 days**.
  - **3 registered devices** (your iPhone and iPad fit), and **3 of your own apps per device**.
  - **10 App IDs per 7 days.** Extensions almost certainly each need their own App ID. Plan: one multiplatform app ID shared by iOS and Mac, plus share, widget and Safari extensions, about 4 App IDs. Fine, but don't create and delete targets casually.
  - If you also build the clipboard app, that's 2 of your 3 app slots on each device.

---

## 8. The hard parts and risks

1. **The editor:** a great Markdown editor is the single hardest piece. Build it on TextKit 2, or evaluate open-source editors first (licenses).
2. **Sync correctness:** CRDT for note bodies, plus lots of tests (offline edits on two devices, deletes versus edits).
3. **Scope creep:** this is a huge app. The roadmap below gets a usable app early, then layers on.
4. **iOS limits:** no background clipboard and no push on a free account. Covered by "update when opened" and by capture going through extensions.
5. **The 10 GB R2 limit:** compression plus local-only originals.
6. **Third-party breakage:** GoodNotes, Notion, Readwise and Apple Notes may change. Each integration is an isolated plugin, so one breaking doesn't break Trove.

---

## 9. Suggested roadmap

| Phase | What you get |
|---|---|
| **0: Spikes (1 session)** | Prove the risky bits:<br>• **iPhone/iPad can read and write a picked iCloud Drive folder on a free account** (the big one)<br>• Foundation Models on the iPad, including overnight while charging<br>• SpeechAnalyzer on your iPhone<br>• Safari extension loads with a free account<br>• Worker hello-world plus a GoodNotes WebDAV upload |
| **1: Mac MVP** | Save links, images, PDFs and notes; Tier 0 enrichment; search; collections; editor v1 |
| **2: iPhone app** | Share extension, widgets, App Intents, voice notes, document scan |
| **3: Sync** | Cloudflare vault, encryption, QR pairing, live sync, CRDT notes |
| **4: Integrations** | Apple Notes bridge, Obsidian vault bridge, GoodNotes WebDAV, Safari/Chrome extensions, Kindle/Readwise, email-in |
| **5: Intelligence** | Tier 1 Apple AI, Tier 2 Mac helper, Ask Trove, optional Tier 3 cloud |
| **6: Delight** | Resurfacing, places map, price alerts, publish links, web app, Liquid Glass polish everywhere |

---

## 10. Questions to answer before building (Claude will ask you)
1. Which exact devices do you own? Model and OS for iPhone, iPad and Mac. So far we know the **iPad is the only Apple Intelligence device**. We still need the Mac's chip (Intel or older Apple silicon?) and macOS version, and the iPhone model. These set the minimum OS.
2. Do you have, or want, a domain on Cloudflare (about $10/yr) for email-in? It's optional.
3. Which apps do you use most today (Apple Notes, GoodNotes, Obsidian, Notion…)? That decides which integrations come first.
4. Name and visual direction.
5. Personal only, or might you sell it one day? That affects the setlist-style API terms and the CloudKit decision.

---

## 11. Will it all work? Second check, part by part

✅ = confirmed by docs or by many working examples. ⚠️ = works, with a catch you should know. 🧪 = very likely, but needs the quick Phase 0 test.

| Part | Status | Notes |
|---|---|---|
| Mac app on a free Apple ID | ✅ | No time limit on Mac |
| iPhone/iPad app on a free Apple ID | ⚠️ | Re-run from Xcode every 7 days. Limit of 3 apps per device and 10 App IDs per week |
| iCloud Drive vault, Mac side | ✅ | It's just a normal folder |
| iCloud Drive vault, iPhone/iPad side (picked folder, free account) | 🧪 | The one real unknown. If it fails, the iPhone and iPad use the Cloudflare relay and the Mac bridges to iCloud |
| iCloud background syncing and conflicts | ⚠️ | Not instant (seconds to minutes). The per-device journal design avoids conflicts; "Keep Downloaded" avoids evictions |
| Text in images / handwriting OCR, dates, places, semantic search on every device | ✅ | Standard Apple frameworks (Vision, NaturalLanguage, NSDataDetector) |
| Apple Intelligence on the iPad as the AI helper | ✅⚠️ | Works. Background use on battery is rate-limited, so the heavy lifting happens while the app is open or the iPad is charging. About a 4K-token context |
| Voice transcription | ✅🧪 | SpeechAnalyzer reportedly works on iPhone 12 and newer but not the SE 2. Older on-device recognizer as fallback, Cloudflare Whisper as a third option |
| Claude API / Cloudflare AI | ✅ | Pennies or free (see §3). Separate API billing for Claude |
| Cloudflare relay (Workers, Durable Objects, R2) | ✅ | Free plan covers it, with WebSocket hibernation |
| Apple Notes import on Mac (AppleScript) | ✅⚠️ | Works. No attachments, no locked notes, needs Automation permission |
| Apple Notes on iPhone | ⚠️ | No real API. Share → "Export as Markdown" (iOS 26) or a Shortcut. Manual-ish, not automatic |
| GoodNotes via WebDAV | ✅🧪 | GoodNotes officially supports WebDAV Auto Backup (iOS). Open-source R2 WebDAV Workers exist (Davflare, FlareDrive). Workers limit upload size, roughly 100 MB on the free plan, so huge notebooks may fail. Test with your biggest one |
| Obsidian two-way mirror (Mac) | ✅ | Plain Markdown files |
| Notion import | ✅ | Official API. If the Markdown endpoint isn't available, read the page's content blocks instead |
| Kindle / Readwise | ✅ | File parser plus official export API |
| Safari / Chrome extensions | ✅🧪 | Chrome: easy. Safari: ships inside the app; confirm it loads with a free-account signature |
| Email-in | ✅⚠️ | Free, but **needs a domain on Cloudflare** (about $10/yr). Optional |
| Spotlight, Shortcuts, widgets, share sheet | ✅ | No paid features needed |
| Live updates on iPhone while the app is closed | ❌ | Needs push notifications, which are paid-only. The iPhone updates when Trove, its widget or the share sheet opens. iCloud also syncs files in the background, which helps |

**Overall verdict:**
- Yes, it works on what you've got, as long as the 🧪 tests pass in the first session.
- The one thing that might need a fallback is iCloud folder access on iPhone/iPad. If it fails, the Cloudflare relay covers it.
- Nothing in the plan *requires* paying anything. Optional costs: about $10/yr for a domain (email-in), pennies a month for Claude Haiku, or $99/yr for Apple's developer program to get CloudKit, push and no 7-day re-installs.

---

## Sources
- Foundation Models framework: [Cult of Mac](https://www.cultofmac.com/news/apple-foundation-models-framework), [Create with Swift](https://createwithswift.com/exploring-the-foundation-models-framework/), [Blake Crosley guide](https://blakecrosley.com/blog/apple-foundation-models-framework)
- Apple Intelligence devices: [TechRadar](https://www.techradar.com/tech/apple-intelligence-heres-a-full-list-of-the-iphones-ipads-and-macs-thatll-get-apples-new-ai-powers), [iGeeksBlog](https://www.igeeksblog.com/siri-ai-compatible-devices/)
- iOS 26 devices: [9to5Mac](https://9to5mac.com/2025/09/15/ios-26-supports-these-recent-iphones-but-drops-three-models/). Tahoe and Intel: [512 Pixels](https://512pixels.net/?p=32495), [TechRadar](https://www.techradar.com/computing/mac-os/does-your-mac-support-macos-tahoe-26-heres-the-full-list-of-compatible-macbooks-and-macs)
- SpeechAnalyzer devices: [Apple Dev Forums](https://developer.apple.com/forums/thread/802863), [Addpipe](https://blog.addpipe.com/apple-speechanalyzer-api/)
- NaturalLanguage embeddings: [Apple NLEmbedding docs](https://developer.apple.com/documentation/naturallanguage/nlembedding.md). Vision: [RecognizeDocumentsRequest docs](https://developer.apple.com/documentation/vision/recognizedocumentsrequest.md). MobileCLIP: [Maginative](https://www.maginative.com/article/apple-introduces-mobileclip-a-state-of-the-art-image-text-model-for-mobile-devices/)
- Cloudflare: [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/), [Workers AI model deprecations](https://developers.cloudflare.com/changelog/post/2026-05-08-planned-model-deprecations/), [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing), [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), [D1 free-tier enforcement](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/), [Vectorize limits](https://developers.cloudflare.com/vectorize/platform/limits), [Email Routing](https://developers.cloudflare.com/email-routing/), [Email Workers guide](https://flaviocopes.com/cloudflare-email-workers/)
- Apple Notes: [iOS 26 Markdown export (AppleInsider)](https://appleinsider.com/inside/ios-26/tips/how-to-import-and-export-markdown-with-apple-notes-in-ios-26), [Apple Dev Forums on reading Notes](https://developer.apple.com/forums/thread/110473), [Exporting Notes (Michael Tsai)](https://mjtsai.com/blog/2018/08/10/exporting-apple-notes-to-markdown/), [Find Notes bug iOS 18.5](https://itechify.com/2025/06/20/copy-filter-notes-shortcuts-ios-18-iphone/)
- GoodNotes: [Auto Backup help](https://support.goodnotes.com/hc/en-us/articles/7352786555279), [Auto Backup FAQ](https://go.goodnotes.com/support/faq-auto-backup), [WebDAV setup guide](https://docs.mis.mpg.de/misc/goodnotes.html)
- Obsidian iCloud issues: [Obsidian forum](https://forum.obsidian.md/t/understanding-icloud-sync-issues/78186), [conflict/data loss thread](https://forum.obsidian.md/t/icloud-data-loss-issue-sync-conflict-handling/113584)
- Folder access on iOS: [Apple: providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories.md), [bookmark device-scoping thread](https://developer.apple.com/forums/thread/127729)
- Competitors: [mymind on Capterra](https://www.capterra.com/p/10015233/mymind/), [mymind alternatives](https://alternativeto.net/software/mymind), [mymind vs Capacities](https://thedailyworkflow.com/compare/mymind-vs-capacities), [Anytype alternatives](https://toolradar.com/tools/anytype/alternatives)
- Kindle and Readwise: [Readwise My Clippings help](https://help.readwise.io/article/49-how-do-i-import-my-clippingstxt-to-readwise), [Readwise export docs](https://docs.readwise.io/readwise/docs/exporting-highlights). Notion API: [overview](https://rollout.com/integration-guides/notion/api-essentials)
- Automerge Swift: [Swift Forums announcement](https://forums.swift.org/t/introducing-automerge-enable-collaborative-asynchronous-syncing-for-your-data-structures/67985)
- Free account capabilities: [Apple supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios), [Apple membership comparison](https://developer.apple.com/support/compare-memberships/), [10 App ID limit thread](https://developer.apple.com/forums/thread/724896)
- Foundation Models background and rate limits: [Apple Dev Forums](https://developer.apple.com/forums/thread/789788), [WWDC25 ML group lab summary](https://developer.apple.com/forums/thread/791086)
- Claude API pricing: Claude API docs (Haiku 5.5 $0.10/$0.50, Sonnet 5.5 $2/$10 per million tokens, Batch API 50% off)
- Workers AI per-model prices: [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- WebDAV on Workers/R2: [FlareDrive write-up](https://blog.51sec.org/2024/10/use-cloudflare-pages-and-r2-storage-to.html?m=0), [Davflare](https://www.80aj.com/2026/08/29/davflare-cloudflare-r2-webdav/)
- Old document-picker guide (iCloud capability note): [Apple archive](https://developer.apple.com/library/ios/documentation/FileManagement/Conceptual/DocumentPickerProgrammingGuide/Introduction/Introduction.html)
