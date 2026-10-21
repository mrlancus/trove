// Where trove-mcp keeps its device: ~/.config/trove-mcp (or $TROVE_MCP_HOME), owner-only.
//   device.json  relay address, vault id, this device's id and token, and the raw vault key (0600)
//   state.json   the local copy of the vault's ops and the journal of unsent edits (0600)
// The vault key is what lets this program read the vault, exactly like the web app's key store, so
// the folder is readable by your user only. Removing the device in Trove (Devices) revokes its token;
// deleting this folder removes the key.
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { importVaultKeys } from "../../web/public/core/keys.js";

export function homeDir() {
  return process.env.TROVE_MCP_HOME ?? join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "trove-mcp");
}

function writePrivate(path, text) {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

function readJSON(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return undefined; }
}

// What LocalStore (web/public/core/localstore.js) keeps: the journal, applied ids, cursor, the
// chunk index and owner, and the op chunks themselves ("ops.<n>"; "ops" is the pre-chunk layout).
const isStateKey = (key) => ["journal", "ops", "applied", "cursor", "opChunks", "localOwner"].includes(key) || /^ops\.\d+$/.test(key);

/**
 * The storage interface Vault expects ({get, set, clear}), backed by two files. Keys are kept as raw
 * bytes in device.json (WebCrypto keys can't be written to a file) and imported on start.
 */
export class FileStorage {
  constructor(dir = homeDir()) {
    this.dir = dir;
    this.devicePath = join(dir, "device.json");
    this.statePath = join(dir, "state.json");
    this.device = readJSON(this.devicePath);
    this.state = readJSON(this.statePath) ?? {};
    this.keys = null;
  }

  /** The folder is owner-only and LocalStore's at-rest key would have to sit next to it: keep values as they are. */
  get plainAtRest() { return true; }

  get exists() { return Boolean(this.device?.config && this.device?.rawKeys); }

  ensureDir() {
    if (!existsSync(this.dir)) mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    chmodSync(this.dir, 0o700);
  }

  /** Remembers the raw keys a setup code carried (only the vault key: never the inbox private key). */
  setRawKeys(rawKeys) {
    this.device = { ...(this.device ?? {}), rawKeys: { vaultKey: rawKeys.vaultKey } };
  }

  async loadKeys() {
    if (!this.keys && this.device?.rawKeys) this.keys = await importVaultKeys(this.device.rawKeys);
    return this.keys;
  }

  async get(key) {
    if (key === "config") return this.device?.config ? structuredClone(this.device.config) : undefined;
    if (key === "keys") return this.loadKeys();
    return this.state[key] === undefined ? undefined : structuredClone(this.state[key]);
  }

  async set(key, value) {
    if (key === "keys") { this.keys = value; return; }
    this.ensureDir();
    if (key === "config") {
      this.device = { ...(this.device ?? {}), config: value };
      writePrivate(this.devicePath, JSON.stringify(this.device, null, 2));
      return;
    }
    if (!isStateKey(key)) return;
    if (value === undefined) delete this.state[key];
    else this.state[key] = structuredClone(value);
    writePrivate(this.statePath, JSON.stringify(this.state));
  }

  async delete(key) { return this.set(key, undefined); }

  async clear() {
    this.device = undefined;
    this.state = {};
    this.keys = null;
    rmSync(this.devicePath, { force: true });
    rmSync(this.statePath, { force: true });
  }
}
