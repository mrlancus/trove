// TRV1 chunked AEAD container (docs/PROTOCOL.md §2), implemented with WebCrypto so the exact same
// file works in the Worker, in the browser extension and in tests. The Swift twin lives in
// Packages/TroveCore/Sources/TroveCore/Crypto/TRV1.swift.

export const MAGIC = new Uint8Array([0x54, 0x52, 0x56, 0x31]); // "TRV1"
export const MODE_SYMMETRIC = 1;
export const MODE_SEALED = 2;
export const DEFAULT_CHUNK_SIZE = 64 * 1024;
const TAG = 16;
const SEALED_INFO = new TextEncoder().encode("trove/v1/sealed");

export function headerLength(mode: number): number {
  return 4 + 1 + 4 + (mode === MODE_SEALED ? 32 : 0) + 8;
}

/** Exact ciphertext size for a plaintext of `length` bytes (lets R2 accept a fixed-length stream). */
export function sealedLength(length: number, chunkSize = DEFAULT_CHUNK_SIZE, mode = MODE_SEALED): number {
  const chunks = length === 0 ? 1 : Math.ceil(length / chunkSize);
  return headerLength(mode) + length + TAG * chunks;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

function nonce(prefix: Uint8Array, index: number): Uint8Array {
  const n = new Uint8Array(12);
  n.set(prefix, 0);
  new DataView(n.buffer).setUint32(8, index);
  return n;
}

async function sealChunk(key: CryptoKey, header: Uint8Array, prefix: Uint8Array, index: number, last: boolean, data: Uint8Array) {
  const aad = concat(header, new Uint8Array([last ? 1 : 0]));
  return new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce(prefix, index), additionalData: aad }, key, data),
  );
}

/**
 * Both sides compute X25519(own private, other side's public); the salt always binds
 * ephemeralPublic ‖ vaultPublic in that order.
 */
async function sealedKey(privateKey: CryptoKey, peerPublic: Uint8Array, ephemeralPublic: Uint8Array, vaultPublic: Uint8Array) {
  const peer = await crypto.subtle.importKey("raw", peerPublic, { name: "X25519" }, false, []);
  // The standard field is `public`; workers-types spells it `$public`, so build it untyped.
  const params = { name: "X25519", public: peer } as unknown as SubtleCryptoDeriveKeyAlgorithm;
  const shared = await crypto.subtle.deriveBits(params, privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: concat(ephemeralPublic, vaultPublic), info: SEALED_INFO },
    hkdf,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function importSymmetricKey(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/** Builds the header + key for a new container. */
async function begin(opts: { recipientPublicKey?: Uint8Array; key?: CryptoKey; chunkSize: number }) {
  const prefix = crypto.getRandomValues(new Uint8Array(8));
  const size = new Uint8Array(4);
  new DataView(size.buffer).setUint32(0, opts.chunkSize);
  if (opts.recipientPublicKey) {
    const eph = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
    const ephPublic = new Uint8Array((await crypto.subtle.exportKey("raw", eph.publicKey)) as ArrayBuffer);
    const key = await sealedKey(eph.privateKey, opts.recipientPublicKey, ephPublic, opts.recipientPublicKey);
    return { key, prefix, header: concat(MAGIC, new Uint8Array([MODE_SEALED]), size, ephPublic, prefix) };
  }
  if (!opts.key) throw new Error("TRV1: need a recipient public key or a symmetric key");
  return { key: opts.key, prefix, header: concat(MAGIC, new Uint8Array([MODE_SYMMETRIC]), size, prefix) };
}

export interface SealOptions {
  /** X25519 vault public key (sealed mode). */
  recipientPublicKey?: Uint8Array;
  /** AES-256-GCM key (symmetric mode). */
  key?: CryptoKey;
  chunkSize?: number;
}

/** One-shot encryption of an in-memory buffer. */
export async function seal(plaintext: Uint8Array, opts: SealOptions): Promise<Uint8Array> {
  const chunkSize = opts.chunkSize ?? DEFAULT_CHUNK_SIZE;
  const { key, prefix, header } = await begin({ ...opts, chunkSize });
  const parts: Uint8Array[] = [header];
  const count = plaintext.length === 0 ? 1 : Math.ceil(plaintext.length / chunkSize);
  for (let i = 0; i < count; i++) {
    const chunk = plaintext.subarray(i * chunkSize, Math.min((i + 1) * chunkSize, plaintext.length));
    parts.push(await sealChunk(key, header, prefix, i, i === count - 1, chunk));
  }
  return concat(...parts);
}

/**
 * Streaming encryption: plaintext bytes in, TRV1 bytes out, holding at most ~2 chunks in memory.
 * Every chunk but the last is exactly `chunkSize` bytes, matching `sealedLength`.
 */
export function sealStream(opts: SealOptions): TransformStream<Uint8Array, Uint8Array> {
  const chunkSize = opts.chunkSize ?? DEFAULT_CHUNK_SIZE;
  let state: Awaited<ReturnType<typeof begin>> | undefined;
  let buffered: Uint8Array = new Uint8Array(0);
  let index = 0;
  const start = async (controller: TransformStreamDefaultController<Uint8Array>) => {
    state = await begin({ ...opts, chunkSize });
    controller.enqueue(state.header);
  };
  return new TransformStream({
    start,
    async transform(input, controller) {
      buffered = concat(buffered, input);
      // Only emit a chunk once we know more data follows it (so it is definitely not the last one).
      while (buffered.length > chunkSize) {
        const s = state!;
        controller.enqueue(await sealChunk(s.key, s.header, s.prefix, index++, false, buffered.subarray(0, chunkSize)));
        buffered = buffered.slice(chunkSize);
      }
    },
    async flush(controller) {
      const s = state!;
      controller.enqueue(await sealChunk(s.key, s.header, s.prefix, index, true, buffered));
    },
  });
}

export interface OpenOptions {
  /** X25519 private key for sealed containers. */
  recipientPrivateKey?: CryptoKey;
  recipientPublicKey?: Uint8Array;
  key?: CryptoKey;
}

/** Decrypts a whole TRV1 buffer. Used by tests and the extension's self-check. */
export async function open(data: Uint8Array, opts: OpenOptions): Promise<Uint8Array> {
  if (data.length < 17 || !MAGIC.every((b, i) => data[i] === b)) throw new Error("TRV1: bad magic");
  const mode = data[4]!;
  const chunkSize = new DataView(data.buffer, data.byteOffset + 5, 4).getUint32(0);
  const hlen = headerLength(mode);
  const header = data.subarray(0, hlen);
  const prefix = data.subarray(hlen - 8, hlen);
  let key: CryptoKey;
  if (mode === MODE_SEALED) {
    if (!opts.recipientPrivateKey || !opts.recipientPublicKey) throw new Error("TRV1: sealed container needs the vault keypair");
    const ephemeralPublic = data.subarray(9, 41);
    key = await sealedKey(opts.recipientPrivateKey, ephemeralPublic, ephemeralPublic, opts.recipientPublicKey);
  } else if (mode === MODE_SYMMETRIC && opts.key) {
    key = opts.key;
  } else {
    throw new Error("TRV1: unsupported mode or missing key");
  }
  const out: Uint8Array[] = [];
  let offset = hlen;
  let index = 0;
  for (;;) {
    const remaining = data.length - offset;
    const last = remaining <= chunkSize + TAG;
    const take = last ? remaining : chunkSize + TAG;
    if (take < TAG) throw new Error("TRV1: truncated");
    const aad = concat(header, new Uint8Array([last ? 1 : 0]));
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce(prefix, index++), additionalData: aad },
      key,
      data.subarray(offset, offset + take),
    );
    out.push(new Uint8Array(plain));
    offset += take;
    if (last) break;
  }
  return concat(...out);
}

// ---- Inbox envelope: u32 headerLength | header JSON | body (PROTOCOL.md §4) ----

export interface InboxHeader {
  v: 1;
  source: "email" | "webdav" | "web" | "ios" | "other";
  receivedAt: string;
  name?: string;
  mime?: string;
  url?: string;
  title?: string;
  groupId?: string;
  meta?: Record<string, unknown>;
}

export function envelopePrefix(header: InboxHeader): Uint8Array {
  const json = new TextEncoder().encode(JSON.stringify(header));
  const len = new Uint8Array(4);
  new DataView(len.buffer).setUint32(0, json.length);
  return concat(len, json);
}

export function parseEnvelope(plain: Uint8Array): { header: InboxHeader; body: Uint8Array } {
  const len = new DataView(plain.buffer, plain.byteOffset, 4).getUint32(0);
  const header = JSON.parse(new TextDecoder().decode(plain.subarray(4, 4 + len))) as InboxHeader;
  return { header, body: plain.subarray(4 + len) };
}

// ---- small encoding helpers ----

export function b64uEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64uDecode(text: string): Uint8Array {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(prefix: string): string {
  return prefix + b64uEncode(crypto.getRandomValues(new Uint8Array(32)));
}

export function randomId(): string {
  return b64uEncode(crypto.getRandomValues(new Uint8Array(16)));
}
