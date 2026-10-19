import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { b64uDecode, b64uEncode, hex, sha256, utf8 } from "../public/core/bytes.js";
import { cleanURL, dedupeKey, hashtags, itemView, search, terms } from "../public/core/items.js";
import { importVaultKeys } from "../public/core/keys.js";
import { merge } from "../public/core/merge.js";
import { decodeSegment, encodeSegment, HLCClock, RecordStore } from "../public/core/records.js";
import { decrypt, encrypt } from "../public/core/trv1.js";
import { parseSetupCode } from "../public/core/vault.js";
import { expectedRecords, scenario } from "./scenario.mjs";

test("sha256 matches node's", () => {
  for (const s of ["", "abc", "café ☕️", "x".repeat(1000), "a".repeat(55), "a".repeat(56), "a".repeat(64)]) {
    assert.equal(hex(sha256(utf8.encode(s))), createHash("sha256").update(s).digest("hex"));
  }
});

test("TRV1 round trip across chunk boundaries, and tampering fails", async () => {
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  for (const size of [0, 1, 7, 8, 9, 16, 17]) {
    const plain = crypto.getRandomValues(new Uint8Array(size));
    const box = await encrypt(plain, keys.segment, 8);
    assert.equal(box.length, 17 + size + 16 * (size === 0 ? 1 : Math.ceil(size / 8)));
    assert.deepEqual(await decrypt(box, keys.segment), plain);
  }
  const box = await encrypt(utf8.encode("hello world, more than one chunk"), keys.segment, 8);
  await assert.rejects(decrypt(box.subarray(0, box.length - 24), keys.segment));
  box[20] ^= 1;
  await assert.rejects(decrypt(box, keys.segment));
});

test("Swift-produced TRV1 fixtures decrypt (symmetric cases)", async () => {
  const f = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/trv1.json", import.meta.url)));
  const key = await crypto.subtle.importKey("raw", b64uDecode(f.symmetricKey), "AES-GCM", false, ["decrypt"]);
  let checked = 0;
  for (const c of f.cases) {
    const box = b64uDecode(c.box);
    if (box[4] !== 1) continue;
    assert.deepEqual(await decrypt(box, key), b64uDecode(c.plaintext), c.name);
    checked++;
  }
  assert.ok(checked > 0);
});

test("3-way merge", () => {
  assert.equal(merge("a\nb\nc", "A\nb\nc", "a\nb\nC"), "A\nb\nC");
  assert.equal(merge("a\nb\nc", "a\nx\nc", "a\ny\nc"), null);
  assert.equal(merge("a", "a", "b"), "b");
  assert.equal(merge("", "one", "two"), null);
  assert.equal(merge("a\nb", "a\nb\nc", "z\na\nb"), "z\na\nb\nc");
});

test("HLCs sort as strings and never go backwards", () => {
  let t = 1000;
  const clock = new HLCClock("dev", null, () => t);
  const a = clock.tick(), b = clock.tick();
  assert.ok(a < b && a === "0000000001000-0000-dev");
  clock.observe("0000000005000-0007-other");
  assert.equal(clock.tick(), "0000000005000-0008-dev");
});

test("Swift-written journals materialise identically in JS", async () => {
  const f = JSON.parse(readFileSync(new URL("./fixtures/swift-journal.json", import.meta.url)));
  const keys = await importVaultKeys(f.keys);
  const store = new RecordStore();
  for (const s of f.segments) {
    const ops = decodeSegment(await decrypt(b64uDecode(s.data), keys.segment), s.device);
    assert.equal(ops[0].s, s.first);
    store.apply(ops);
  }
  assert.deepEqual(expectedRecords(store), f.expected);
});

test("the JS scenario gives the same records as the Swift one", () => {
  const swift = JSON.parse(readFileSync(new URL("./fixtures/swift-journal.json", import.meta.url))).expected;
  assert.deepEqual(expectedRecords(scenario().store), swift);
});

test("segments are JSON Lines with sorted keys and round-trip", () => {
  const { journals } = scenario();
  const batch = journals[0].segments()[0];
  const text = new TextDecoder().decode(encodeSegment(batch));
  assert.match(text.split("\n")[0], /^\{"d":"AAAA-WEB","f":\{/);
  assert.deepEqual(decodeSegment(encodeSegment(batch), "AAAA-WEB"), batch);
  assert.throws(() => decodeSegment(encodeSegment(batch.slice(1)), "OTHER"));
});

test("record order doesn't matter (rebuilds when older ops arrive later)", () => {
  const { journals, store } = scenario();
  const shuffled = new RecordStore();
  for (const op of [...journals[0].pending, ...journals[1].pending].reverse()) shuffled.apply([op]);
  assert.deepEqual(expectedRecords(shuffled), expectedRecords(store));
});

test("URL cleaning, tags, search", () => {
  assert.equal(cleanURL("https://Example.com/post?utm_source=x&id=3#:~:text=hi").toString(), "https://example.com/post?id=3");
  assert.equal(dedupeKey("https://www.example.com/post/"), "example.com/post");
  assert.deepEqual(hashtags("Plan #Garden and `#not` this\n```\n#nope\n```\n#2024 #ideas/later"), ["garden", "ideas/later"]);
  assert.deepEqual(terms("The Café's RECIPES, boxes & ideas!"), ["cafe", "recipe", "box", "idea"]);
  const rec = (id, fields, body = "") => itemView({ id, fields, texts: { body }, conflicts: {} });
  const items = [
    rec("1", { title: "Miso ramen recipe", tags: ["food"], category: "recipe", kind: "link", createdAt: 3 }),
    rec("2", { title: "Trip notes", kind: "note", createdAt: 2 }, "We had ramen in Tokyo"),
    rec("3", { title: "Desk lamp", category: "product", pinned: true, createdAt: 1 }),
  ];
  assert.deepEqual(search(items, "ramen").map((i) => i.id), ["1", "2"]);
  assert.deepEqual(search(items, "ram").map((i) => i.id)[0], "1");
  assert.deepEqual(search(items, "ramen type:note").map((i) => i.id), ["2"]);
  assert.deepEqual(search(items, "is:pinned").map((i) => i.id), ["3"]);
  assert.deepEqual(search(items, "tag:food").map((i) => i.id), ["1"]);
});

test("setup codes", () => {
  const payload = { v: 1, vaultId: "V", keys: { v: 1, vaultKey: "k", privateKey: "p" }, encrypted: true, pairingCode: "PC" };
  const code = b64uEncode(utf8.encode(JSON.stringify(payload)));
  assert.equal(parseSetupCode(code).pairingCode, "PC");
  assert.equal(parseSetupCode(`trove://pair?d=${code}`).vaultId, "V");
  assert.throws(() => parseSetupCode("nonsense"));
  assert.throws(() => parseSetupCode(b64uEncode(utf8.encode(JSON.stringify({ ...payload, pairingCode: undefined })))), /relay/);
});
