// The same two-device scenario as WebInteropTests.scenario() in Swift, written with the JS journal.
import { Journal, RecordStore } from "../public/core/records.js";
import { hashText } from "../public/core/clips.js";

export function scenario() {
  const now = () => 1_760_000_000_000;
  const a = new Journal({ device: "AAAA-WEB" }, [], now);
  const b = new Journal({ device: "BBBB-WEB" }, [], now);
  const list = "Shopping\n- milk\n- eggs\n- bread";
  a.set({ kind: "note", title: "List", createdAt: 1_760_000_000_000, tags: ["home"], pinned: true, price: 12.5, readAt: null }, "n1", "item");
  a.text("body", list, "", "n1", "item");
  a.set({ kind: "note", title: "Greeting" }, "n2", "item");
  a.text("body", "Hello\nsecond line", "", "n2");
  a.set({ kind: "link", url: "https://example.com/café?q=☕️", title: "Café ☕️" }, "n3", "item");
  for (const op of a.pending) b.observe(op.h);
  a.text("body", "Shopping\n- oat milk\n- eggs\n- bread", list, "n1");
  b.text("body", "Shopping\n- milk\n- eggs\n- bread\n- coffee ☕️", list, "n1");
  a.text("body", "Hello world\nsecond line", "Hello\nsecond line", "n2");
  b.text("body", "Hello there\nsecond line", "Hello\nsecond line", "n2");
  a.set({ title: "Groceries" }, "n1");
  b.set({ title: "Shopping list", tags: ["home", "food"] }, "n1");
  b.set({ _deleted: true }, "n3");
  b.set({ name: "Kitchen", symbol: "fork.knife" }, "c1", "collection");
  b.set({ text: "#ff8a3d", hash: hashText("#ff8a3d"), createdAt: 1_760_000_000_500, sourceApp: "Figma", device: "BBBB" }, "k1", "clip");
  const store = new RecordStore();
  store.apply(b.pending);
  store.apply(a.pending);
  return { journals: [a, b], store };
}

export function expectedRecords(store) {
  const out = {};
  for (const [id, r] of store.records) out[id] = { kind: r.kind, fields: r.fields, texts: r.texts, conflicts: r.conflicts };
  return out;
}
