# Trove relay (Cloudflare Worker)

This is optional. Trove works with just iCloud Drive. The relay adds:
- instant sync, with live WebSocket pings
- the browser extension
- email-in
- GoodNotes Auto Backup (WebDAV)
- opt-in cloud AI
- price-drop alerts and publish-to-link
- **the web app**: Trove in any browser, at the relay's address

It runs on Cloudflare's free plan, and it only ever stores encrypted bytes (see `../docs/PROTOCOL.md`).

## Deploy (about 5 minutes, one time)

```bash
cd server
npm install
npx wrangler login                       # opens the browser; approve
npx wrangler r2 bucket create trove-blobs
npx wrangler deploy                      # prints https://trove-relay.<you>.workers.dev
```

Then in Trove go to **Settings → Cloudflare relay**, paste that URL and choose **Connect relay**.

**Web app:** open the same URL in any browser (Windows, Android, a work laptop). In Trove go to
**Settings → Devices → Add a device → Copy setup code instead** and paste the code there. The browser
joins as a device you can remove later. It's served from `../web/public` as Workers static assets,
so `wrangler deploy` uploads it too.

### After your vault exists: close the relay to new vaults
Anyone who finds the URL could otherwise create vaults and use your free-tier storage. Once Trove
has created your vault, set `"ALLOW_NEW_VAULTS": "false"` in `wrangler.jsonc` and run
`npx wrangler deploy` again.

### Optional: cloud AI
Turn this on per vault in Trove → Settings → Intelligence.
```bash
npx wrangler secret put ANTHROPIC_API_KEY   # from console.anthropic.com (billed separately from Claude Pro)
```
- **Model:** `CLAUDE_MODEL` in `wrangler.jsonc` is `claude-haiku-5-5` (pennies a month), and that's
  the recommended default: it's quick and costs $0.10 per million tokens in, $0.50 out. If it's
  unset the relay also uses `claude-haiku-5-5`. See `../docs/RESEARCH.md` §3 for costs.
- **Monthly cap:** each vault gets `AI_MONTHLY_LIMIT` tokens a month (input + output, counted from
  the API's own usage numbers; default 1,000,000, which is about $0.10 to $0.50 on Haiku). Past it,
  AI answers "used up until the 1st" (429) without calling Claude. To change it, add
  `"AI_MONTHLY_LIMIT": "2000000"` to `vars` in `wrangler.jsonc` and deploy. Trove shows the running
  total under **AI** on the website (and `GET /v1/vaults/:v/ai/status`).
- Until the key is set, nothing is sent anywhere and nothing costs money: the apps and website hide
  cloud AI features. Content sent for AI is never stored by the relay.

### Optional: email-in (needs a domain on Cloudflare)
1. In the Cloudflare dashboard, go to **Email → Email Routing** and enable it for your domain.
2. Create a custom address, for example `save@yourdomain`, with the action **Send to a Worker → trove-relay**.
3. Set `EMAIL_VAULT_ID` in `wrangler.jsonc` to your relay vault id (Trove → Settings shows it under the GoodNotes username), then run `npx wrangler deploy`.

### GoodNotes
1. In Trove, go to **Settings → Cloudflare relay → GoodNotes Auto Backup** and copy the server, username and password.
2. In GoodNotes (iPad/iPhone), go to **Settings → Cloud & Backup → Auto Backup → WebDAV**, paste them, and choose PDF.

Notebooks then arrive in Trove, and the handwriting gets OCR'd so you can search it.
- **Upload size:** the free plan limits uploads to about 100 MB, so a huge notebook may fail.
- **Privacy:** notebook *names* are visible to the server. The contents are not.

## Develop / test
```bash
npm test                    # 55 tests on the real Workers runtime (no network, no cost)
npx tsc --noEmit
npx wrangler dev --local --config wrangler.test.jsonc   # local relay on :8787
# Swift client end-to-end against it:
cd ../Packages/TroveCore && TROVE_RELAY_URL=http://127.0.0.1:8787 swift test --filter RelayIntegration
```
Cross-language crypto checks: `scripts/make-fixtures.ts` (Worker → Swift) and `scripts/check-swift-vector.ts` (Swift → Worker).

## Free-tier budget (personal use)
| Service | Free allowance | Used for |
|---|---|---|
| Workers | 100k requests/day | API |
| Durable Objects | 100k requests/day, SQLite storage | per-vault journals, devices, live sockets (pings auto-answered) |
| R2 | 10 GB, 1M writes and 10M reads a month | encrypted attachments and inbox |
| Workers AI | 10k neurons/day | Whisper, embeddings (optional) |
