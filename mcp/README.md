# trove-mcp: Trove for Claude

A small [Model Context Protocol](https://modelcontextprotocol.io) server that lets Claude Desktop and
Claude Code search, read and add to your Trove. It runs on your own computer, joins your vault as its
own device (kind `agent`, listed under Devices like any other) and talks to Claude over stdio. The
relay still never sees anything readable: this program syncs the encrypted vault and decrypts it
locally, exactly like the website does.

No build step and no dependencies: Node 22 and this repository (it reuses `web/public/core`).

## Tools

| Tool | What it does |
|---|---|
| `search` | Search everything (words, plus filters like `tag:food`, `type:note`, `is:pinned`) |
| `read_item` | One item in full: text, link, tags, folder, summary, text found in files and handwriting |
| `list_recent` | Newest items, optionally one kind or one folder |
| `list_folders` | Every folder path with its item count |
| `create_note` | A new note (Markdown, optional folder and tags). Syncs to every device |
| `save_link` | Save a link with an optional note, folder and tags; the relay fills in its title and picture |

Start it with `--read-only` and the two writing tools disappear (and are refused if called anyway).
That switch lives on your computer: the device itself can still write, so for a hard limit remove
the device in Trove.

## Set up

1. In Trove (the website or the app), open **Devices**, paste your recovery code and make a
   **setup code**. It works once, for 10 minutes.
2. On the computer that runs Claude:
   ```bash
   git clone https://github.com/mrlancus/trove.git ~/trove     # or use your existing checkout
   node ~/trove/mcp/bin/trove-mcp.js join '<setup code>' --name "Claude"
   ```
   It prints how many items it can see. `node ~/trove/mcp/bin/trove-mcp.js status` shows the vault
   and device later.
3. Add it to Claude (below), then ask something like "What did I save about ramen?"

### Claude Desktop
Settings → Developer → Edit Config (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "trove": {
      "command": "node",
      "args": ["/Users/you/trove/mcp/bin/trove-mcp.js"]
    }
  }
}
```
Use the full path to `node` (`which node`) if Claude Desktop can't find it, and add `"--read-only"`
to `args` for a read-only connection. Restart Claude Desktop afterwards.

### Claude Code
```bash
claude mcp add trove -- node ~/trove/mcp/bin/trove-mcp.js
# read-only:
claude mcp add trove -- node ~/trove/mcp/bin/trove-mcp.js --read-only
```

## Where the keys are, and why

`trove-mcp` keeps its device in `~/.config/trove-mcp` (or `$TROVE_MCP_HOME`):
- `device.json`: the relay address, this device's id and token, and the **vault key**. The vault key
  is what decrypts your vault, so whoever can read this file can read your Trove.
- `state.json`: the local copy of the vault's records (decrypted), so it starts quickly and works offline.

The folder is created readable by your user only (`0700`, files `0600`). Keeping a key on a computer
is your choice, the same one you make when you add the website: anything running as your user on that
computer could read it. The setup code's inbox private key is dropped, so this device never imports
the inbox (your other devices do that).

To undo it: `node ~/trove/mcp/bin/trove-mcp.js forget` removes the device from the vault and deletes
the folder. Removing the device under Devices in Trove also stops it at once (its token is revoked);
delete the folder yourself afterwards.

Storing the key in the macOS Keychain or the Linux secret service instead of a file is a possible
later step; it isn't done yet, because Node has no built-in access to them and the file permissions
already limit it to your user.

## How it works

- Joining uses the same pairing as any device (PROTOCOL.md §4 and §7) with `deviceKind: "agent"`.
- It pulls new segments from the relay when it starts and before a tool runs (at most every 30
  seconds), and pushes right after a write, so a note Claude makes appears on your phone within
  seconds.
- Writes are ordinary ops (PROTOCOL.md §3) from this device's own journal, merged like any edit.
- `save_link` asks the relay's link preview (`POST /preview`) for the title and picture.

## Tests

```bash
cd mcp && npm test                       # MCP handling against an offline vault
# against a local relay:
cd server && npx wrangler dev --local --config wrangler.test.jsonc --port 8803
cd mcp && TROVE_RELAY_URL=http://127.0.0.1:8803 npm run test:e2e
```

Later (roadmap §5.2 step 2): `trove-mcp --http` behind a Cloudflare Tunnel so claude.ai and the
Claude phone app can use it while the keys stay on your computer.
