# Save to Trove: browser extension

One codebase for **Chrome** (load unpacked) and **Safari** (bundled in the Trove app as `TroveSafari`).

## Chrome
1. Go to `chrome://extensions` and turn on **Developer mode**.
2. Choose **Load unpacked** and pick this `extensions/browser` folder.
3. On the setup page, paste the code from **Trove → Settings → Cloudflare relay → Browser extension setup code**.

How to save:
- **Right-click** a page, selection, link or image and choose **Save … to Trove**.
- **⌘⇧S** opens the popup, where you can add a note before saving.
- **⌥⇧S** saves the page straight away.

The extension holds only the vault **public** key and an inbox token. It can add things to your Trove but never read them. Saves made while offline are queued and retried.

## Tests
```bash
npm test          # crypto: the Worker's reference code opens what the extension seals
npm run test:e2e  # real Chromium + local relay (start `npx wrangler dev --local --config wrangler.test.jsonc` in server/ first)
```
The e2e test loads the extension in Chromium and saves a real page (title, canonical URL,
selection, note), then decrypts the entry from the relay. It also covers the offline queue.
The setup page's permission prompt needs a real click, so the test grants host access in a copy of
the manifest instead.
