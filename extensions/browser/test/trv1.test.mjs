// The extension's sealing must open with the Worker's reference implementation.
// Run: node --experimental-strip-types --test extensions/browser/test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { b64uEncode, envelope, parseSetupCode, seal } from "../trv1.js";
import { open, parseEnvelope } from "../../../server/src/crypto.ts";

async function vault() {
  const keys = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
  return { keys, pub };
}

test("extension-sealed envelopes open with the vault key", async () => {
  const { keys, pub } = await vault();
  for (const size of [0, 10, 70_000]) {
    const body = new Uint8Array(size).map((_, i) => i % 251);
    const box = await seal(envelope({ source: "web", url: "https://a.example", title: "T" }, body), pub);
    const plain = await open(box, { recipientPrivateKey: keys.privateKey, recipientPublicKey: pub });
    const { header, body: back } = parseEnvelope(plain);
    assert.equal(header.source, "web");
    assert.equal(header.url, "https://a.example");
    assert.equal(header.v, 1);
    assert.deepEqual(back, body);
  }
});

test("setup codes are validated", async () => {
  const { pub } = await vault();
  const good = { v: 1, relayURL: "https://relay.example/", vaultId: "V", inboxToken: "tin_x", vaultPublicKey: b64uEncode(pub) };
  const code = b64uEncode(new TextEncoder().encode(JSON.stringify(good)));
  assert.equal(parseSetupCode(code).relayURL, "https://relay.example");
  assert.throws(() => parseSetupCode(b64uEncode(new TextEncoder().encode(JSON.stringify({ ...good, inboxToken: "" })))));
  assert.throws(() => parseSetupCode(b64uEncode(new TextEncoder().encode(JSON.stringify({ ...good, vaultPublicKey: "abc" })))));
});
