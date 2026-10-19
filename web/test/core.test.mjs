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

test("clips: classify, secrets and transforms match the Swift rules", async () => {
  const { classify, color, isSensitive, availableTransforms, transforms, colorFormats } = await import("../public/core/clips.js");
  const cases = {
    "https://example.com/a?b=1": "link", "me@example.com": "email", "+44 20 7946 0958": "phone", "#ff8a3d": "color",
    "rgb(255, 138, 61)": "color", "hsl(24, 100%, 62%)": "color", "1,299.50": "number", "~/Documents/notes.md": "path",
    '{"a": [1, 2]}': "json", "func hello() {\n    return 1\n}": "code", "const x = a => a + 1;\nconsole.log(x(1));": "code",
    "Remember to buy milk and eggs": "text", facade: "text",
  };
  for (const [input, kind] of Object.entries(cases)) assert.equal(classify(input), kind, input);
  assert.deepEqual(color("#fff"), { r: 1, g: 1, b: 1, a: 1 });
  for (const secret of ["sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "Tr0ub4dor&3x!", "482913",
    "AKIAIOSFODNN7EXAMPLE", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc", "q8Zr2LmX9vB4nT7cK1pW5sY3hJ6gD0fA"]) assert.ok(isSensitive(secret), secret);
  for (const normal of ["Remember to buy milk", "https://example.com/Page?id=1&X=2", "me@example.com", "hello", "1,299", "~/Documents/My File.txt",
    "#ff8a3d", "iPhone 17 Pro", '{"b":1,"a":2}', "rgb(1,2,3)",
    "Tuesday,", "Hello-World!", "Trove-macOS.zip", "Report2024.pdf"]) assert.ok(!isSensitive(normal), normal);
  const t = Object.fromEntries(transforms.map((x) => [x.id, x.apply]));
  assert.equal(t.cleanLink("https://example.com/a?utm_source=x&id=2"), "https://example.com/a?id=2");
  assert.equal(t.minifiedJSON('{ "a" : 1 }'), '{"a":1}');
  assert.equal(t.singleLine("one\n  two\n\nthree"), "one two three");
  assert.equal(t.titleCase("hello world"), "Hello World");
  assert.ok(availableTransforms("plain words").some((x) => x.id === "uppercase"));
  assert.ok(!availableTransforms("plain words").some((x) => x.id === "prettyJSON"));
  assert.deepEqual(colorFormats(color("#ff8a3d")), ["#FF8A3D", "rgb(255, 138, 61)", "hsl(24, 100%, 62%)"]);
});

test("clips in the vault: dedupe, pin, delete and save to the library", async () => {
  const { Vault } = await import("../public/core/vault.js");
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  let t = 1_760_000_000_000;
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const v = new Vault(storage, { deviceName: "Chrome", encrypted: true }, keys, { device: "WEB" }, [], [], [], 0, { now: () => (t += 1000) });
  const a = v.addClip("first", { sourceApp: "Notes" });
  const b = v.addClip("https://example.com/x");
  assert.deepEqual(v.clips().map((c) => c.id), [b, a]);
  assert.equal(v.addClip("first"), a);
  assert.deepEqual(v.clips().map((c) => c.id), [a, b]);
  assert.equal(v.clip(b).kind, "link");
  assert.equal(v.clip(a).sourceDevice, "Chrome");
  assert.equal(v.addClip("   "), null);
  v.setClipPinned(b, true);
  assert.equal(v.clip(b).isPinned, true);
  const item = await v.saveClipToLibrary(b);
  assert.equal(v.item(item).url.toString(), "https://example.com/x");
  assert.equal(await v.saveClipToLibrary(b), item);
  v.deleteClip(a);
  assert.deepEqual(v.clips().map((c) => c.id), [b]);
  assert.equal(v.items().length, 1);
});

test("imports the same zip as FileImportTests.swift", async () => {
  const { importActions, countActions, isJunk, readZip, parseMarkdownNote } = await import("../public/core/importer.js");
  const bytes = new Uint8Array(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/import-sample.zip", import.meta.url)));
  const zip = readZip(bytes);
  assert.equal(zip.entries.length, 9);
  const long = await zip.data(zip.entries.find((e) => e.path === "Export/long.txt"));
  assert.equal(long.length, 196_710);
  const actions = await importActions("export.zip", bytes);
  const notes = actions.filter((a) => a.type === "note").map((a) => a.title);
  assert.deepEqual(new Set(notes), new Set(["Big ideas", "long", "Inside"]));
  assert.deepEqual(actions.filter((a) => a.type === "file").map((a) => `${a.name} ${a.mime}`), ["photo.png image/png"]);
  const items = actions.filter((a) => a.type === "items").flatMap((a) => a.items);
  assert.deepEqual(items.filter((i) => i.kind === "link").map((i) => i.url), ["https://example.com/a", "https://example.org/b"]);
  const dune = items.find((i) => i.kind === "highlight");
  assert.equal(dune.title, "Dune");
  assert.equal(dune.externalId, "kindle:dacb4933b882f63a"); // same as Swift: sha256("Dune|Fear is the mind-killer.")
  assert.equal(countActions(actions), 7);
  assert.ok(isJunk("__MACOSX/a/._b.md") && isJunk("a/.DS_Store") && !isJunk("a/b.md"));
  assert.deepEqual(parseMarkdownNote("---\ntags: [ideas]\n---\n# Big ideas\n\nShip it #now\n", "x.md"),
    { title: "Big ideas", tags: ["ideas", "now"], body: "Ship it #now" });
});
