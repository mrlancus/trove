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
  assert.deepEqual(search(items, "#Food ramen").map((i) => i.id), ["1"]);
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

test("clip insights match Fixtures/clip-cases.json (ClipInsights.swift)", async () => {
  const { insights } = await import("../public/core/clips.js");
  const cases = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/clip-cases.json", import.meta.url), "utf8"));
  assert.ok(cases.insights.length >= 10);
  for (const { text, ...expected } of cases.insights) assert.deepEqual(insights(text), expected, text);
  const { ruleTags } = await import("../public/core/clips.js");
  assert.ok(cases.rules.length >= 15);
  for (const { text, tags } of cases.rules) assert.deepEqual(ruleTags(text), tags, text);
});

test("clips: rename, edit, tag, note, search and save with where they came from", async () => {
  const { Vault } = await import("../public/core/vault.js");
  const { clipMatches, hashText } = await import("../public/core/clips.js");
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  let t = 1_760_000_000_000;
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const v = new Vault(storage, { deviceName: "Chrome", encrypted: true }, keys, { device: "WEB" }, [], [], [], 0, { now: () => (t += 1000) });
  const id = v.addClip("Call +44 20 7946 0958 about #budget", { sourceApp: "Chrome", sourceURL: "https://news.example.com/story", sourceTitle: "A story" });
  let clip = v.clip(id);
  assert.equal(clip.displayTitle, "Call +44 20 7946 0958 about #budget");
  assert.deepEqual(clip.entities.phones, ["+44 20 7946 0958"]);
  assert.equal(clip.sourceTitle, "A story");
  assert.ok(clip.needsEnrichment);
  v.renameClip(id, "  Ring Anna ");
  v.setClipTags(id, ["#Work", "work", " finance "]);
  v.setClipNote(id, "before Friday");
  clip = v.clip(id);
  assert.equal(clip.displayTitle, "Ring Anna");
  assert.deepEqual(clip.tags, ["work", "finance"]);
  assert.ok(clipMatches(clip, "tag:work anna") && clipMatches(clip, "app:chrome") && clipMatches(clip, "friday") && clipMatches(clip, "story"));
  assert.ok(!clipMatches(clip, "is:pinned") && !clipMatches(clip, "tag:home"));
  assert.ok(clipMatches(clip, "#work Fríday") && !clipMatches(clip, "#home"));
  v.editClip(id, "Email anna@example.org about #budget");
  clip = v.clip(id);
  assert.equal(clip.hash, hashText(clip.text));
  assert.deepEqual(clip.entities.emails, ["anna@example.org"]);
  assert.deepEqual(clip.entities.phones, []);
  assert.ok(clip.aiTitle === null && clip.needsEnrichment && clip.editedAt);
  assert.equal(clip.displayTitle, "Ring Anna");
  v.addClip("Email anna@example.org about #budget");
  assert.equal(v.clip(id).uses, 1);
  const item = v.item(await v.saveClipToLibrary(id));
  assert.equal(item.title, "Ring Anna");
  assert.equal(item.source, "clipboard");
  assert.ok(["finance", "work"].every((x) => item.tags.includes(x)));
  assert.ok(item.body.includes("before Friday"));
  assert.deepEqual(item.record.fields.origin, { clip: id, app: "Chrome", url: "https://news.example.com/story", title: "A story" });
  v.renameClip(id, "");
  assert.equal(v.clip(id).displayTitle, "Email anna@example.org about #budget");
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

const fixture = (name) => JSON.parse(readFileSync(new URL(`../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/${name}.json`, import.meta.url)));

/** A vault with in-memory storage and a fake relay that keeps blobs. */
async function testVault(device = "WEB", blobs = new Map()) {
  const { Vault } = await import("../public/core/vault.js");
  const storage = { m: new Map(), get: async (k) => storage.m.get(k), set: async (k, v) => { storage.m.set(k, v); }, clear: async () => storage.m.clear() };
  let t = 1_760_000_000_000;
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const fetch = async (url, init = {}) => {
    const id = /blobs\/([0-9a-f]+)$/.exec(url)?.[1];
    if (id && init.method === "PUT") { blobs.set(id, init.body); return new Response(null, { status: 204 }); }
    if (id) return blobs.has(id) ? new Response(blobs.get(id)) : new Response("", { status: 404 });
    return new Response("{}", { status: 200 });
  };
  const v = new Vault(storage, { deviceName: "Chrome", encrypted: true, base: "http://relay", vaultId: "V", token: "T" }, keys, { device }, [], [], [], 0,
    { now: () => (t += 1000), fetch });
  return { v, keys, blobs, advance: (ms) => { t += ms; } };
}

test("the organiser matches the shared Swift cases", async () => {
  const { folderPath, folderId, folderTree, folderPathOf } = await import("../public/core/organize.js");
  const f = fixture("organize-cases");
  for (const c of f.paths) assert.deepEqual(folderPath(c), c.expect, JSON.stringify(c));
  for (const c of f.ids) assert.equal(folderId(c.parent, c.name), c.expect);
  const folders = [{ id: "b", name: "beta", parent: null }, { id: "a", name: "Alpha", parent: null }, { id: "c", name: "child", parent: "b" },
    { id: "x", name: "loop1", parent: "y" }, { id: "y", name: "loop2", parent: "x" }];
  assert.deepEqual(folderTree(folders).map((e) => `${e.folder.id}${e.depth}`), ["a0", "b0", "c1", "x0", "y1"]);
  assert.deepEqual(folderPathOf("c", folders).map((x) => x.id), ["b", "c"]);
});

test("links match the shared Swift cases", async () => {
  const { wikilinks, linkGraph, mentions, related, neighbours } = await import("../public/core/links.js");
  const f = fixture("links-cases");
  for (const c of f.wikilinks) assert.deepEqual(wikilinks(c.text), c.expect, c.text);
  const items = f.items.map((o) => itemView({ id: o.id, fields: { title: o.title, createdAt: o.createdAt, tags: o.tags ?? [], ...(o.links ? { links: o.links } : {}) },
    texts: { body: o.body }, conflicts: {} }));
  const graph = linkGraph(items);
  assert.deepEqual(graph, f.graph);
  assert.deepEqual(mentions(items[0], items, new Set(neighbours(graph, "a"))).map((i) => i.id), f.mentions.a);
  assert.deepEqual(related(items[0], items).map((i) => i.id), f.related.a);
});

test("vault: new items are filed, folders can be moved, renamed, deleted and tidied", async () => {
  const { v } = await testVault();
  const pdf = await v.addFile(utf8.encode("pdf"), "Tax.pdf", "application/pdf");
  const sheet = await v.addFile(utf8.encode("x"), "Budget.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
  const note = v.addNote({ body: "hello" });
  const imported = v.addNote({ title: "Week 1", body: "x", source: "import", folder: ["Uni", "Maths"] });
  const { folderPathOf } = await import("../public/core/organize.js");
  const path = (id) => folderPathOf(v.item(id).folder, v.folders()).map((f) => f.name);
  assert.deepEqual(path(pdf), ["Documents"]);
  assert.deepEqual(path(sheet), ["Documents", "Spreadsheets"]);
  assert.deepEqual(path(note), ["Notes"]);
  assert.deepEqual(path(imported), ["Uni", "Maths"]);
  assert.equal(v.item(pdf).folder, "folder:documents");
  assert.equal(v.item(pdf).isAutoFiled, true);
  const uni = v.createFolder("Uni");
  assert.equal(uni, "folder:uni");
  const maths = v.ensureFolder(["uni", "MATHS"]);
  v.moveItem(note, maths);
  assert.equal(v.item(note).isAutoFiled, false);
  v.renameFolder(uni, "University");
  assert.equal(v.ensureFolder(["University", "maths"]), maths);
  assert.equal(v.moveFolder(uni, maths), false);
  v.deleteFolder(maths);
  assert.equal(v.item(note).folder, uni);
  v.deleteFolder(uni);
  assert.equal(v.item(note).folder, null);
  assert.equal(v.tidyUp(), 2); // the note, and "Week 1" whose folders were deleted
  assert.equal(v.item(note).folder, "folder:notes");
  assert.equal(v.tidyUp(), 0);
});

test("vault: file versions, text versions, connections and thumbnails", async () => {
  const { v, advance } = await testVault();
  const id = await v.addFile(utf8.encode("v1"), "notes.txt", "text/plain");
  await v.replaceFile(id, utf8.encode("v2"));
  await v.replaceFile(id, utf8.encode("v3"));
  let item = v.item(id);
  assert.equal(new TextDecoder().decode(await v.attachment(item.attachments[0].id)), "v3");
  assert.equal(item.fileVersions.length, 2);
  v.restoreFileVersion(id, item.fileVersions[1]);
  item = v.item(id);
  assert.equal(new TextDecoder().decode(await v.attachment(item.attachments[0].id)), "v1");
  assert.equal(item.fileVersions.length, 2);

  const n = v.addNote({ body: "a" });
  advance(10_000); v.setBody(n, "ab");
  advance(10_000); v.setBody(n, "abc");
  advance(600_000); v.setBody(n, "abcd");
  assert.deepEqual(v.textVersions(n).map((x) => x.text), ["abcd", "abc"]);

  v.connect(n, id);
  v.connect(n, id);
  assert.deepEqual(v.item(n).links, [id]);
  v.disconnect(id, n);
  assert.deepEqual(v.item(n).links, []);
  await v.setThumbnail(id, utf8.encode("jpeg"));
  assert.equal(v.item(id).thumbnail.name, "thumbnail.jpg");
});

test("vault: an inbox entry imported by two devices is one item; GoodNotes backups keep versions", async () => {
  const blobs = new Map();
  const a = (await testVault("WEB", blobs)).v, b = (await testVault("MAC", blobs)).v;
  const header = { v: 1, source: "web", mime: "text/plain", title: "A thought" };
  const ida = await a.importEnvelope(header, utf8.encode("remember this"), { id: "E1" });
  const idb = await b.importEnvelope(header, utf8.encode("remember this"), { id: "E1" });
  assert.equal(ida, "inbox-e1");
  assert.equal(ida, idb);
  a.store.apply(b.journal.pending);
  b.store.apply(a.journal.pending);
  assert.equal(a.items().length, 1);
  assert.equal(a.item(ida).body, "remember this");
  assert.equal(a.item(ida).hasConflicts, false);
  assert.deepEqual(a.item(ida).record.fields, b.item(ida).record.fields);

  const nb = { v: 1, source: "webdav", name: "Bio.goodnotes", meta: { davPath: "/Bio.goodnotes" } };
  const first = await a.importEnvelope(nb, utf8.encode("one"), { id: "G1" });
  assert.equal(await a.importEnvelope(nb, utf8.encode("two"), { id: "G2" }), first);
  const notebook = a.item(first);
  assert.equal(notebook.kind, "file");
  assert.equal(notebook.source, "goodnotes");
  assert.equal(notebook.folder, "folder:handwritten");
  assert.equal(notebook.fileVersions.length, 1);
});

test("zip imports keep their folders, like FileImport.placed", async () => {
  const { importActions } = await import("../public/core/importer.js");
  const bytes = new Uint8Array(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/import-sample.zip", import.meta.url)));
  const actions = await importActions("import-sample.zip", bytes, ["Dropped"]);
  assert.deepEqual(actions.find((a) => a.name === "photo.png").folder, ["Dropped", "import-sample", "Export"]);
  assert.ok(actions.some((a) => a.type === "note" && a.folder.join("/") === "Dropped/import-sample/Export/nested"));
});

test("file previews: kinds, GoodNotes, Word, Excel, PowerPoint, iWork and CSV", async () => {
  const f = await import("../public/core/files.js");
  const read = (n) => new Uint8Array(readFileSync(new URL(`./fixtures/files/${n}`, import.meta.url)));
  assert.equal(f.previewKind("a.pdf", "application/pdf"), "pdf");
  assert.equal(f.previewKind("Bio.goodnotes", "application/octet-stream"), "goodnotes");
  assert.equal(f.previewKind("x.KEY", ""), "iwork");
  assert.equal(f.previewKind("main.swift", "application/octet-stream"), "text");
  assert.equal(f.previewKind("data.csv", "text/csv"), "csv");
  assert.equal(f.previewKind("song.m4a", "audio/m4a"), "audio");
  assert.equal(f.previewKind("thing.bin", "application/octet-stream"), "other");
  assert.equal(f.typeLabel("Bio.goodnotes"), "GOODNOTES");
  assert.ok(f.isEditableText("notes.md", "text/markdown") && !f.isEditableText("a.pdf", "application/pdf"));

  const gn = await f.goodnotesParts(read("sample.goodnotes"));
  assert.equal(gn.pages, 2);
  assert.equal(gn.thumbnail.mime, "image/jpeg");
  assert.deepEqual(gn.attachments.map((a) => a.mime), ["application/pdf", "image/png"]);

  assert.deepEqual(await f.docxParagraphs(read("sample.docx")), [
    { style: "h1", text: "Essay & notes" }, { style: "h2", text: "Intro" }, { style: "p", text: "Hello world\ttabbed" }, { style: "li", text: "a point" }]);
  assert.deepEqual(await f.xlsxRows(read("sample.xlsx")), [["Name", "Cost"], ["Café", "", "3.5"], ["x < y"]]);
  assert.deepEqual(await f.pptxSlides(read("sample.pptx")), [["Title slide", "Point"], ["Second"]]);
  assert.equal((await f.iworkPreview(read("sample.pages"))).mime, "image/jpeg");
  assert.deepEqual(f.parseDelimited('a,"b, c",d\n1,"say ""hi""",3\r\nlast'), [["a", "b, c", "d"], ["1", 'say "hi"', "3"], ["last"]]);
});

test("a duplicate from another source is listed under that source too", async () => {
  const { v: vault } = await testVault();
  const { id } = vault.addLink("https://example.com/post", { source: "import" });
  const again = vault.addLink("https://www.example.com/post/?utm_source=x", { source: "email" });
  assert.equal(again.id, id);
  assert.equal(again.isNew, false);
  assert.deepEqual(vault.item(id).sources, ["import", "email"]);
  vault.addLink("https://example.com/post", { source: "email" });
  assert.deepEqual(vault.item(id).sources, ["import", "email"]);
  assert.deepEqual(search(vault.items(), "from:email", Date.now()).map((i) => i.id), [id]);
});

test("GoodNotes files count as GoodNotes however they arrived; sketches have their own collection", async () => {
  const { smartCollections } = await import("../public/core/items.js");
  const rec = (id, fields) => itemView({ id, fields, texts: {}, conflicts: {}, updatedHLC: "1" });
  const zipped = rec("gn1", { source: "import", attachments: [{ id: "b", name: "Electricity.goodnotes", mime: "application/octet-stream", size: 1 }] });
  assert.deepEqual(zipped.sources, ["import", "goodnotes"]);
  assert.ok(smartCollections.find((s) => s.id === "handwriting").contains(zipped));
  assert.deepEqual(rec("gn2", { source: "import" }).sources, ["import"]);
  assert.ok(smartCollections.find((s) => s.id === "sketches").contains(rec("sk", { kind: "sketch" })));
});

test("tags with colours sync, and deleting one takes it off everything (Library+Clips.swift)", async () => {
  const { v: vault } = await testVault();
  const id = vault.addClip("Invoice 42");
  assert.equal(vault.setTagColor(" Work Stuff ", "blue"), "work-stuff");
  vault.setTagColor("home", "green");
  vault.setTagColor("#Home", "pink");
  assert.deepEqual(vault.customTags(), [{ name: "home", color: "pink" }, { name: "work-stuff", color: "blue" }]);
  vault.toggleClipTag(id, "work-stuff");
  assert.ok(vault.clip(id).tags.includes("work-stuff"));
  const { clipMatches } = await import("../public/core/clips.js");
  assert.ok(clipMatches(vault.clip(id), "#work-stuff invoice"));
  vault.deleteTag("work-stuff");
  assert.deepEqual(vault.customTags().map((t) => t.name), ["home"]);
  assert.ok(!vault.clip(id).tags.includes("work-stuff"));
  assert.equal(vault.setTagColor("  ", "red"), null);
});

test("search keeps up as items change (cached docs)", async () => {
  const { v: vault } = await testVault();
  const id = vault.addNote({ title: "Electricity revision" });
  assert.deepEqual(search(vault.items(), "elec").map((i) => i.id), [id]);
  vault.update(id, { title: "Magnetism" });
  assert.deepEqual(search(vault.items(), "elec"), []);
  assert.deepEqual(search(vault.items(), "magn").map((i) => i.id), [id]);
});

test("GoodNotes ink: every layout in the shared fixture decodes as GoodNotesInkTests.swift expects", async () => {
  const gn = await import("../public/core/goodnotes.js");
  const fixtures = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/", import.meta.url);
  const expected = JSON.parse(readFileSync(new URL("ink-expected.json", fixtures), "utf8"));
  assert.equal(new TextDecoder().decode(gn.appleLZ4(Uint8Array.from(Buffer.from(expected.lz4.frame, "base64"))).bytes), expected.lz4.text);
  const nb = await gn.readNotebook(new Uint8Array(readFileSync(new URL("ink.goodnotes", fixtures))));
  const r2 = (v) => Math.round(v * 100) / 100;
  assert.deepEqual(nb.pages.map((p) => p.id), expected.pages.map((p) => p.id));
  nb.pages.forEach((p, i) => {
    const want = expected.pages[i];
    assert.deepEqual(p.background, want.background);
    assert.deepEqual(p.layers.map((l) => l.kind), want.layers.map((l) => l.kind));
    p.layers.forEach((l, j) => {
      if (l.kind === "ink") assert.deepEqual(l.runs.map((run) => run.map((pt) => pt.map(r2))), want.layers[j].runs);
      if (l.kind === "text") assert.deepEqual(l.runs.map((t) => t.text), want.layers[j].runs.map((t) => t.text));
    });
  });
  const ink = nb.pages[1].layers.filter((l) => l.kind === "ink");
  assert.equal(ink[1].runs.length, 2, "the highlighter lifts once");
  assert.ok(gn.isHighlighter(ink[1]) && ink[3].pencil && ink[4].shape);
  assert.equal(gn.pageText(nb.pages[1]), "Hello world\nagain");
});

test("sketching geometry matches Fixtures/ink-geometry.json (InkGeometry.swift, InkShapes.swift)", async () => {
  const ink = await import("../public/core/ink.js");
  const f = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-geometry.json", import.meta.url), "utf8"));
  const pts = (a) => a.map(([x, y, p = 0.5, t = 0]) => ({ x, y, p, t }));
  const flat = (a) => a.map((p) => [p.x, p.y, p.p, p.t]);
  for (const c of f.shapes) {
    const got = ink.recognizeShape(pts(c.points));
    assert.deepEqual(got && { shape: got.shape, points: flat(got.points) }, c.expect, c.name);
  }
  for (const c of f.erasing) assert.deepEqual(ink.erase(pts(c.points), pts(c.path), c.radius)?.map(flat) ?? null, c.expect, c.name);
  const polygon = pts(f.lasso.polygon);
  for (const p of f.lasso.points) assert.equal(ink.inside(p.x, p.y, polygon), p.inside);
  for (const s of f.lasso.strokes) assert.equal(ink.lassoSelects(pts(s.points), polygon), s.selected);
  for (const w of f.widths) assert.equal(ink.widthAt(w.width, w.tool, w.pressure), w.expect);
  for (const c of f.fountain) assert.equal(ink.fountainWidth(10, c.pressure, c.dx, c.dy), c.expect);
  for (const c of f.taper) assert.equal(ink.brushTaper(c.index, c.count), c.expect);
  assert.deepEqual(flat(ink.resample(pts(f.resampled.points), f.resampled.spacing)), f.resampled.expect);
});

test("sketch pages, text boxes, lasso and the partial eraser (Library+InkPages)", async () => {
  const { v: vault } = await testVault();
  const sketch = vault.addSketch({ paper: "lined" });
  assert.deepEqual(vault.item(sketch).pageList.map((p) => p.id), ["0"]);
  vault.addStroke({ on: sketch, page: 0, tool: "pen", color: "#000000", width: 4, points: [{ x: 0, y: 0, p: 0.5, t: 0 }, { x: 200, y: 0, p: 0.5, t: 16 }] });
  const second = vault.addPage(sketch);
  vault.setPage(sketch, second, { paper: "music", color: "#fbf6e9" });
  const a = vault.addStroke({ on: sketch, page: second, tool: "fountain", color: "#112233", width: 6, points: [{ x: 10, y: 10, p: 0.5, t: 0 }, { x: 50, y: 50, p: 0.5, t: 0 }] });
  const box = vault.addElement({ on: sketch, page: second, type: "text", frame: { x: 20, y: 20, w: 200, h: 40 }, text: "Buy milk" });
  let item = vault.item(sketch);
  assert.deepEqual(item.pageList, [{ id: "0", paper: null, color: null, size: null }, { id: second, paper: "music", color: "#fbf6e9", size: null }]);
  // Page sizes: one page, then every page.
  vault.setPage(sketch, second, { size: [1086, 768] });
  assert.deepEqual(vault.item(sketch).pageList[1].size, [1086, 768]);
  vault.setAllPages(sketch, { size: [543, 768], paper: "graph" });
  assert.deepEqual(vault.item(sketch).pageList.map((p) => [p.size, p.paper]), [[[543, 768], "graph"], [[543, 768], "graph"]]);
  assert.deepEqual(vault.item(sketch).pageSize, [543, 768]);
  vault.setAllPages(sketch, { size: [768, 1024], paper: "music" });
  vault.setPage(sketch, second, { color: "#fbf6e9" });
  assert.equal(item.sketchText, "Buy milk");
  const { search } = await import("../public/core/items.js");
  assert.deepEqual(search(vault.items(), "milk").map((i) => i.id), [sketch]);
  assert.equal(vault.strokes(sketch, "", "0").length, 1);

  vault.transformStrokes([a], { t: { sx: 2, sy: 2, ox: 10, oy: 10, dx: 5, dy: 0 }, color: "#ff0000" });
  const moved = vault.strokes(sketch, "", second)[0];
  assert.deepEqual(moved.points.map((p) => p.x), [15, 95]);
  assert.equal(moved.width, 12);
  assert.equal(moved.color, "#ff0000");
  vault.transformElements([box], { sx: 1, sy: 1, ox: 0, oy: 0, dx: 10, dy: 10 });
  assert.equal(vault.elements(sketch, "", second)[0].x, 30);
  assert.equal(vault.duplicateInk({ strokes: [a], elements: [box], on: sketch, page: second }).length, 2);
  assert.equal(vault.item(sketch).sketchText, "Buy milk\nBuy milk");

  const third = vault.duplicatePage(sketch, second);
  assert.equal(vault.strokes(sketch, "", third).length, 2);
  vault.movePage(sketch, third, 0);
  assert.deepEqual(vault.item(sketch).pageList.map((p) => p.id), [third, "0", second]);
  vault.deletePage(sketch, third);
  assert.deepEqual(vault.item(sketch).pageList.map((p) => p.id), ["0", second]);

  const before = vault.strokes(sketch, "", "0")[0];
  const pieces = vault.eraseStrokes({ on: sketch, page: "0", path: [{ x: 100, y: -20 }, { x: 100, y: 20 }], radius: 5 });
  const after = vault.strokes(sketch, "", "0");
  assert.equal(pieces.length, 2);
  assert.ok(after.length === 2 && after.every((s) => s.createdAt === before.createdAt));
  assert.equal(vault.eraseStrokes({ on: sketch, page: "0", path: [{ x: 50, y: 0 }], radius: 5, only: ["highlighter"] }).length, 0);
  vault.setSketchCanvas(sketch, true);
  assert.equal(vault.item(sketch).infinite, true);
});

test("drawing: packed points, widths and strokes in the vault match Ink.swift", async () => {
  const ink = await import("../public/core/ink.js");
  const cases = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/ink-cases.json", import.meta.url), "utf8"));
  const points = cases.points.map(([x, y, p, t]) => ({ x, y, p, t }));
  assert.equal(ink.encodePoints(points), cases.encoded);
  assert.deepEqual(ink.decodePoints(cases.encoded), points);
  for (const w of cases.widths) assert.ok(Math.abs(ink.widthAt(w.width, w.tool, w.pressure) - w.expect) < 1e-9);

  const { v: vault } = await testVault();
  const sketch = vault.addSketch({ paper: "lined" });
  assert.equal(vault.item(sketch).kind, "sketch");
  assert.equal(vault.item(sketch).displayTitle, "Sketch");
  assert.equal(vault.item(sketch).paper, "lined");
  assert.equal(vault.folders().find((f) => f.id === vault.item(sketch).folder)?.name, "Sketches");
  const a = vault.addStroke({ on: sketch, page: 0, tool: "pen", color: "#112233", width: 3, points });
  const b = vault.addStroke({ on: sketch, page: 1, tool: "highlighter", color: "#ffee00", width: 20, points: points.slice(0, 2) });
  const c = vault.addStroke({ on: "pdf-item", layer: "blob1", page: 0, tool: "marker", color: "#ff0000", width: 6, points });
  assert.deepEqual(vault.strokes(sketch).map((s) => s.id), [a, b]);
  assert.deepEqual(vault.strokes(sketch, "", 1).map((s) => s.id), [b]);
  assert.deepEqual(vault.strokes("pdf-item", "blob1").map((s) => s.id), [c]);
  assert.ok(ink.hits(vault.strokes(sketch)[0], 10, 21, 1));
  assert.ok(!ink.hits(vault.strokes(sketch)[0], 500, 500, 5));
  vault.deleteStrokes([a]);
  assert.deepEqual(vault.strokes(sketch).map((s) => s.id), [b]);
  vault.setSketch(sketch, { pages: 3 });
  assert.equal(vault.item(sketch).sketchPages, 3);
  assert.deepEqual([...vault.inkedLayers().get("pdf-item")], ["blob1"]);
});

test("how much clipboard history to keep is a synced setting (ClipTests.howMuchToKeepIsASyncedSetting)", async () => {
  let now = 1_760_000_000_000;
  const { v: vault } = await testVault();
  vault.now = () => now;
  assert.deepEqual(vault.clipKeep(), { days: 30, count: 1000 });
  vault.addClip("last spring");
  now += 200 * 86_400_000;
  for (let i = 0; i < 4; i++) { now += 1000; vault.addClip(`clip ${i}`); }
  assert.equal(vault.setClipKeep({ days: 365, count: 0 }), 0);
  assert.equal(vault.setClipKeep({ days: 0, count: 3 }), 2);
  assert.deepEqual(vault.clipKeep(), { days: 0, count: 3 });
  assert.deepEqual(vault.clips().map((c) => c.text), ["clip 3", "clip 2", "clip 1"]);
});

test("clip copy and paste events, places and the clipboard map (core/clipmap.js)", async () => {
  const { v: vault } = await testVault();
  const { buildClipGraph, clipFacts, filterChoices, filterClips } = await import("../public/core/clipmap.js");
  const a = vault.addClip("https://github.com/mrlancus/trove", { sourceApp: "Safari", sourceURL: "https://github.com/mrlancus/trove" });
  const b = vault.addClip("Meeting at 10", { sourceApp: "Notes" });
  const c = vault.addClip("SELECT * FROM clips", { sourceApp: "Xcode" });
  vault.recordClipEvent(a, "copy", { app: "Safari", url: "https://github.com/mrlancus/trove", place: { lat: 51.50735, lon: -0.12776, accuracy: 30, name: "Home" } });
  vault.recordClipEvent(a, "paste", { app: "Slack", place: { lat: 51.50735, lon: -0.12776 } });
  vault.recordClipEvent(b, "copy", { app: "Notes", place: { lat: 51.50731, lon: -0.12771, name: "Home" } });
  vault.recordClipEvent(b, "paste", { app: "Slack" });
  vault.recordClipEvent(c, "paste", { app: "Terminal", place: { lat: 48.8566, lon: 2.3522 } });
  assert.equal(vault.clipEvents(a).length, 2);
  assert.deepEqual(vault.clipEvents(a)[0].place, { lat: 51.50735, lon: -0.12776, accuracy: 30, name: "Home", city: null });
  const clips = vault.clips();
  const facts = clipFacts(clips, vault.clipEvents());
  assert.deepEqual([...facts.get(a).from.keys()], ["site:github.com"]);
  assert.deepEqual([...facts.get(a).to.keys()], ["app:slack"]);
  assert.deepEqual(filterClips(clips, facts, { to: "app:slack" }).map((x) => x.id).sort(), [a, b].sort());
  assert.deepEqual(filterClips(clips, facts, { place: "place:home" }).map((x) => x.id).sort(), [a, b].sort());
  assert.deepEqual(filterClips(clips, facts, { place: "place:48.857,2.352" }).map((x) => x.id), [c]);
  assert.equal(filterChoices(clips, facts).to[0].label, "Slack");
  const graph = buildClipGraph(clips, facts, { groups: ["to", "place"] });
  assert.ok(graph.nodes.some((n) => n.id === "to|app:slack" && n.degree === 2));
  assert.ok(graph.nodes.some((n) => n.id === "place|place:home"));
  // Connections between clips and to items; deleting a clip deletes its events.
  const note = vault.addNote({ title: "Standup" });
  vault.connectClip(b, note);
  vault.connectClip(b, a);
  assert.deepEqual(vault.clip(b).links, [note, a]);
  assert.ok(buildClipGraph(vault.clips(), facts, { groups: [], items: vault.items() }).edges.some((e) => e.a === b && e.b === note));
  vault.deleteClip(a);
  assert.equal(vault.clipEvents(a).length, 0);
  // Places can be turned off for every device.
  assert.equal(vault.appSetting("recordPlaces"), true);
  vault.setAppSetting("recordPlaces", false);
  assert.equal(vault.appSetting("recordPlaces"), false);
});

test("import from Paste: its SQLite database (new and old layouts), keyed archives, pinboards (core/pasteimport.js)", async (t) => {
  const { DatabaseSync } = await import("node:sqlite");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { archivePasteboard, writeBplist } = await import("./bplist-writer.mjs");
  const { readPasteDatabase } = await import("../public/core/pasteimport.js");
  const { decodeBlob } = await import("../public/core/bplist.js");
  const dir = mkdtempSync(join(tmpdir(), "paste"));
  t.after(() => rmSync(dir, { recursive: true }));
  const enc = (s) => new TextEncoder().encode(s);
  assert.deepEqual(decodeBlob(writeBplist({ a: [1, "é", enc("x")] })), { a: [1, "é", enc("x")] });

  // Newer Paste: items, pasteboard data, apps, pinboards (one list per item and a join table).
  const path = join(dir, "db.sqlite");
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL;
    CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNAME VARCHAR, ZBUNDLEIDENTIFIER VARCHAR);
    CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);
    CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAPPLICATION INTEGER, ZCREATEDATE TIMESTAMP, ZMODIFIEDDATE TIMESTAMP, ZTITLE VARCHAR, ZTYPE INTEGER);
    CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZRAWPASTEBOARDITEMS BLOB);
    CREATE TABLE Z_2ITEMS (Z_2LISTS INTEGER, Z_3ITEMS INTEGER, PRIMARY KEY (Z_2LISTS, Z_3ITEMS));`);
  db.exec(`INSERT INTO ZAPPLICATIONENTITY VALUES (1, 1, 'Safari', 'com.apple.Safari'), (2, 1, 'Xcode', 'com.apple.dt.Xcode');
    INSERT INTO ZLISTENTITY VALUES (1, 'Clipboard'), (2, 'Work Links'), (3, 'Snippets');`);
  const item = db.prepare("INSERT INTO ZITEMENTITY VALUES (?, 3, 1, ?, ?, ?, ?, 0)"), data = db.prepare("INSERT INTO ZITEMDATAENTITY (ZITEM, ZRAWPASTEBOARDITEMS) VALUES (?, ?)");
  const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
  const at2001 = (unixMs) => unixMs / 1000 - 978307200;
  item.run(1, 1, at2001(1760000000000), at2001(1760000000000), null);
  data.run(1, archivePasteboard([{ "public.utf8-plain-text": enc("https://example.com/page"), "public.url": enc("https://example.com/page"), "public.html": enc("<a>x</a>") }]));
  item.run(2, 2, at2001(1760000100000), at2001(1760000100000), "Query");
  data.run(2, archivePasteboard([{ "public.utf16-plain-text": Uint8Array.from([...("SELECT 1 — ok")].flatMap((c) => [c.charCodeAt(0) & 255, c.charCodeAt(0) >> 8])) }]));
  item.run(3, null, at2001(1760000200000), at2001(1760000200000), null);
  data.run(3, archivePasteboard([{ "public.png": png, "public.tiff": enc("II*\0") }]));
  item.run(4, 1, at2001(1760000300000), null, null);
  data.run(4, archivePasteboard([{ "com.apple.webarchive": enc("nothing readable") }]));
  item.run(5, 1, at2001(1760000400000), null, null);
  data.run(5, archivePasteboard([{ "public.utf8-plain-text": enc("x".repeat(9000)) }])); // spills onto overflow pages
  db.exec("INSERT INTO Z_2ITEMS VALUES (2, 1), (3, 2), (1, 2)");
  const live = (await import("node:fs")).readFileSync(path), wal = (await import("node:fs")).readFileSync(path + "-wal");
  db.close();
  const read = readPasteDatabase(new Uint8Array(live), new Uint8Array(wal));
  assert.equal(read.entries.length, 4);
  assert.equal(read.skipped, 1);
  const [link, query, image, long] = read.entries;
  assert.deepEqual([link.text, link.url, link.app, link.bundle, link.createdAt, link.pinboards], ["https://example.com/page", "https://example.com/page", "Safari", "com.apple.Safari", 1760000000000, ["Work Links"]]);
  assert.deepEqual([query.text, query.title, query.app, query.pinboards], ["SELECT 1 — ok", "Query", "Xcode", ["Snippets"]]);
  assert.equal(image.image.mime, "image/png");
  assert.equal(long.text.length, 9000);

  // Older Paste: one ZSNIPPET table with the content in a plist.
  const oldPath = join(dir, "Paste.db");
  const old = new DatabaseSync(oldPath);
  old.exec("CREATE TABLE ZSNIPPET (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP TIMESTAMP, ZAPPLICATIONNAME VARCHAR, ZPREVIEW2 BLOB)");
  old.prepare("INSERT INTO ZSNIPPET (ZTIMESTAMP, ZAPPLICATIONNAME, ZPREVIEW2) VALUES (?, ?, ?)").run(701805006.78, "Terminal", writeBplist({ text: "keytool -list" }));
  old.close();
  const oldRead = readPasteDatabase(new Uint8Array((await import("node:fs")).readFileSync(oldPath)));
  assert.deepEqual(oldRead.entries.map((e) => [e.text, e.app, new Date(e.createdAt).getUTCFullYear()]), [["keytool -list", "Terminal", 2023]]);

  // Into the vault: times, apps and pinboards kept; a second import adds nothing.
  const { v: vault } = await testVault();
  const first = await vault.importClips(read.entries);
  assert.deepEqual(first, { added: 4, merged: 0 });
  const clip = vault.clips().find((c) => c.text === "SELECT 1 — ok");
  assert.deepEqual([clip.createdAt, clip.sourceApp, clip.tags.includes("snippets"), clip.title], [1760000100000, "Xcode", true, "Query"]);
  assert.equal(vault.clipEvents(clip.id)[0].at, 1760000100000);
  assert.deepEqual(await vault.importClips(read.entries), { added: 0, merged: 4 });
});

test("GoodNotes whiteboards fit their content (same numbers as GoodNotesInkTests)", async () => {
  const { fitToContent, GN_SCALE } = await import("../public/core/goodnotes.js");
  const ink = (runs) => ({ kind: "ink", rgb: [0, 0, 0], alpha: 1, width: 2, runs });
  const fit = fitToContent({ id: "p", width: 612, height: 792, background: null, layers: [ink([[[-1320, 5280, 2], [1100, 7700, 2]]])] });
  assert.ok(Math.abs(fit.width - (2424 * GN_SCALE + 72)) < 0.001 && Math.abs(fit.height - (2424 * GN_SCALE + 72)) < 0.001);
  assert.ok(Math.abs((fit.layers[0].runs[0][0][0] - 2) * GN_SCALE - 36) < 0.001);
  assert.ok(Math.abs((fit.strokes[0].runs[0][0][1] - 2) * GN_SCALE - 36) < 0.001);
  assert.equal(fit.strokes[0].kind, undefined);
  assert.equal(fitToContent({ id: "q", width: 612, height: 792, background: null, layers: [ink([[[100, 100, 2]]])] }).width, 612);
  const blank = fitToContent({ id: "h", width: 20000, height: 20000, background: { attachment: "a", page: 1 }, layers: [] });
  assert.equal(blank.width, 612);
  assert.equal(blank.background, null);
});

test("Paste's JSON-wrapped text is unwrapped (same as ClipTests.unwrapsPasteJSON)", async () => {
  const { unwrap } = await import("../public/core/pasteimport.js");
  assert.equal(unwrap('{"type":"text","text":"py tools\\/sim.py compare\\ngit push","textLength":230}').text, "py tools/sim.py compare\ngit push");
  assert.equal(unwrap('{"type":"link","url":"https://example.com"}').text, "https://example.com");
  assert.equal(unwrap('{"name":"not paste"}'), null);
  assert.equal(unwrap("plain"), null);
});

test("the local op store is append-only, sealed at rest, and opens old plain data", async () => {
  const { Vault } = await import("../public/core/vault.js");
  const { LocalStore } = await import("../public/core/localstore.js");
  const writes = [];
  const m = new Map();
  const storage = { m, get: async (k) => structuredClone(m.get(k)), set: async (k, v) => { writes.push(k); m.set(k, structuredClone(v)); },
    delete: async (k) => { m.delete(k); }, clear: async () => m.clear() };
  let t = 1_760_000_000_000;
  const keys = await importVaultKeys({ vaultKey: b64uEncode(crypto.getRandomValues(new Uint8Array(32))) });
  const config = { deviceName: "Chrome", deviceId: "WEB", encrypted: true, base: "http://relay", vaultId: "V", token: "T" };
  await storage.set("config", config);
  await storage.set("keys", keys);

  // An old browser: everything plain, every op under "ops".
  const old = new Vault({ get: async () => undefined, set: async () => {} }, config, keys, { device: "WEB" }, [], [], [], 0, { now: () => (t += 1000) });
  for (let i = 0; i < 20; i++) old.addNote({ title: `note ${i}`, body: `secret body ${i}` });
  clearTimeout(old.saveTimer);
  await storage.set("ops", old.store.ops.map((op) => structuredClone(op)));
  await storage.set("journal", { state: old.journal.state, pending: [] });
  await storage.set("applied", ["MAC/1"]);
  await storage.set("cursor", 7);

  const v = await Vault.open(storage, { now: () => (t += 1000) });
  assert.equal(v.items().length, 20);
  assert.equal(m.has("ops"), false, "the plain op list is gone after the migration");
  const plain = (x) => JSON.stringify(x, (k, val) => (val instanceof Uint8Array ? "bytes" : val));
  for (const [k, val] of m) if (!["config", "keys", "localKey", "localOwner", "opChunks"].includes(k)) assert.equal(val?.sealed, 1, `${k} is sealed`);
  assert.ok(![...m.values()].some((val) => plain(val)?.includes("secret body")), "no note text in storage");

  // A save after one edit writes one small chunk, not the whole op list.
  writes.length = 0;
  v.addNote({ title: "new", body: "another secret" });
  clearTimeout(v.saveTimer);
  await v.save();
  const chunkWrites = writes.filter((k) => k.startsWith("ops."));
  assert.ok(chunkWrites.length >= 1 && chunkWrites.length <= 6, `chunk writes: ${chunkWrites}`);
  assert.ok(!writes.includes("ops"));

  // Many saves keep few chunks (small ones merge), and a reopen gets every op back.
  for (let i = 0; i < 40; i++) { v.addNote({ title: `more ${i}` }); clearTimeout(v.saveTimer); await v.save(); }
  assert.ok(m.get("opChunks").chunks.length <= 8, `chunks: ${m.get("opChunks").chunks.length}`);
  const stored = [...m.keys()].filter((k) => k.startsWith("ops."));
  assert.equal(stored.length, m.get("opChunks").chunks.length, "merged chunks are deleted");
  const again = await Vault.open(storage, { now: () => (t += 1000) });
  assert.equal(again.items().length, 61);
  assert.equal(again.cursor, 7);
  assert.deepEqual([...again.applied], ["MAC/1"]);
  assert.equal(again.store.ops.length, v.store.ops.length);

  // The first copy no longer writes once another opened the storage (the "use here" tab).
  assert.equal(await v.local.save({ journal: {}, fresh: [], all: [], applied: [], cursor: 0 }), false);
  assert.equal(await again.local.save({ journal: { state: again.journal.state, pending: [] }, fresh: [], all: [], applied: [...again.applied], cursor: 7 }), true);

  // A lost at-rest key opens as empty with the cursor at 0 (sync pulls everything again).
  m.delete("localKey");
  const lost = await new LocalStore(storage).load();
  assert.deepEqual([lost.ops.length, lost.cursor, lost.applied.length], [0, 0, 0]);
});

test("a failed save leaves the local op store readable and is redone in full", async () => {
  const { LocalStore } = await import("../public/core/localstore.js");
  const m = new Map();
  let failNext = false;
  const storage = { get: async (k) => m.get(k), set: async (k, v) => { if (failNext && k.startsWith("ops.")) { failNext = false; throw new Error("disk full"); } m.set(k, v); },
    delete: async (k) => { m.delete(k); }, clear: async () => m.clear() };
  const op = (s) => ({ d: "WEB", s, h: `17000000000${String(s).padStart(2, "0")}-0000-WEB`, t: "set", r: `r${s}`, k: "item", f: { title: `t${s}` } });
  const all = [];
  const local = new LocalStore(storage, { chunkBytes: 400 });
  for (let s = 1; s <= 30; s++) {
    all.push(op(s));
    failNext = s === 12 || s === 20;
    await local.save({ journal: {}, fresh: [op(s)], all, applied: [], cursor: s }).catch(() => {});
  }
  await local.save({ journal: {}, fresh: [], all, applied: [], cursor: 30 });
  const loaded = await new LocalStore(storage).load();
  assert.deepEqual(loaded.ops.map((o) => o.s).sort((a, b) => a - b), all.map((o) => o.s));
  const listed = new Set(m.get("opChunks").chunks.map((c) => `ops.${c.n}`));
  assert.deepEqual([...m.keys()].filter((k) => k.startsWith("ops.")).sort(), [...listed].sort(), "no orphaned chunks");
  assert.ok(listed.size > 1, "small chunk limit gives several chunks");
});
