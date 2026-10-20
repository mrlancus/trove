// Writes Paste-like databases to Packages/TroveCore/Tests/TroveCoreTests/Fixtures (paste-new.sqlite
// with its -wal, and the older paste-old.db) and what core/pasteimport.js reads from them
// (paste-expected.json), so PasteImport.swift is checked against the website.
// Run: node test/make-paste-fixture.mjs
import { DatabaseSync } from "node:sqlite";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { archivePasteboard, writeBplist } from "./bplist-writer.mjs";
import { readPasteDatabase } from "../public/core/pasteimport.js";

const out = new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/", import.meta.url).pathname;
const dir = mkdtempSync(join(tmpdir(), "paste"));
const enc = (s) => new TextEncoder().encode(s);
const at2001 = (unixMs) => unixMs / 1000 - 978307200;

const path = join(dir, "db.sqlite");
const db = new DatabaseSync(path);
db.exec(`PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
  CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNAME VARCHAR, ZBUNDLEIDENTIFIER VARCHAR);
  CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);
  CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAPPLICATION INTEGER, ZCREATEDATE TIMESTAMP, ZMODIFIEDDATE TIMESTAMP, ZTITLE VARCHAR, ZTYPE INTEGER);
  CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZRAWPASTEBOARDITEMS BLOB);
  CREATE TABLE Z_2ITEMS (Z_2LISTS INTEGER, Z_3ITEMS INTEGER, PRIMARY KEY (Z_2LISTS, Z_3ITEMS));
  INSERT INTO ZAPPLICATIONENTITY VALUES (1, 1, 'Safari', 'com.apple.Safari'), (2, 1, 'Xcode', 'com.apple.dt.Xcode');
  INSERT INTO ZLISTENTITY VALUES (1, 'Clipboard'), (2, 'Work Links'), (3, 'Snippets');`);
const item = db.prepare("INSERT INTO ZITEMENTITY VALUES (?, 3, 1, ?, ?, ?, ?, 0)"), data = db.prepare("INSERT INTO ZITEMDATAENTITY (ZITEM, ZRAWPASTEBOARDITEMS) VALUES (?, ?)");
db.exec("BEGIN");
const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const utf16 = (s) => Uint8Array.from([...s].flatMap((c) => [c.charCodeAt(0) & 255, c.charCodeAt(0) >> 8]));
item.run(1, 1, at2001(1760000000000), at2001(1760000000000), null);
data.run(1, archivePasteboard([{ "public.utf8-plain-text": enc("https://example.com/page"), "public.url": enc("https://example.com/page"), "public.html": enc("<a>x</a>") }]));
item.run(2, 2, at2001(1760000100000), at2001(1760000100000), "Query");
data.run(2, archivePasteboard([{ "public.utf16-plain-text": utf16("SELECT 1 — ok") }]));
item.run(3, null, at2001(1760000200000), at2001(1760000200000), null);
data.run(3, archivePasteboard([{ "public.png": png, "public.tiff": enc("II*\0") }]));
item.run(4, 1, at2001(1760000300000), null, null);
data.run(4, archivePasteboard([{ "com.apple.webarchive": enc("nothing readable") }]));
item.run(5, 1, at2001(1760000400000), null, null);
data.run(5, archivePasteboard([{ "public.utf8-plain-text": enc("x".repeat(9000)) }])); // overflow pages
db.exec("COMMIT; BEGIN");
for (let i = 6; i < 150; i++) { item.run(i, 2, at2001(1760001000000 + i * 1000), null, null); data.run(i, archivePasteboard([{ "public.utf8-plain-text": enc(`clip number ${i} ` + "é".repeat(i % 50)) }])); }
db.exec("INSERT INTO Z_2ITEMS VALUES (2, 1), (3, 2), (1, 2); COMMIT");
copyFileSync(path, join(out, "paste-new.sqlite"));
copyFileSync(path + "-wal", join(out, "paste-new.sqlite-wal"));
db.close();

const oldPath = join(dir, "Paste.db");
const old = new DatabaseSync(oldPath);
old.exec("CREATE TABLE ZSNIPPET (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP TIMESTAMP, ZAPPLICATIONNAME VARCHAR, ZPREVIEW2 BLOB)");
old.prepare("INSERT INTO ZSNIPPET (ZTIMESTAMP, ZAPPLICATIONNAME, ZPREVIEW2) VALUES (?, ?, ?)").run(701805006.78, "Terminal", writeBplist({ text: "keytool -list" }));
old.close();
copyFileSync(oldPath, join(out, "paste-old.db"));
rmSync(dir, { recursive: true });

const summary = (r) => ({ skipped: r.skipped, entries: r.entries.map((e) => ({ text: e.text, image: e.image ? { mime: e.image.mime, size: e.image.bytes.length } : null,
  url: e.url, createdAt: e.createdAt, app: e.app, bundle: e.bundle, title: e.title, pinboards: e.pinboards })) });
const read = (name, wal) => readPasteDatabase(new Uint8Array(readFileSync(join(out, name))), wal ? new Uint8Array(readFileSync(join(out, wal))) : null);
const expected = { new: summary(read("paste-new.sqlite", "paste-new.sqlite-wal")), old: summary(read("paste-old.db")) };
writeFileSync(join(out, "paste-expected.json"), JSON.stringify(expected));
console.log(expected.new.entries.length, expected.new.skipped, expected.old.entries.length);
