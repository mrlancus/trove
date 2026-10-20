// Writes binary plists and NSKeyedArchiver archives, for tests of core/bplist.js and the Paste importer.
export const uid = (n) => ({ uid: n });

export function writeBplist(root) {
  const objects = [], index = new Map();
  const add = (v) => {
    if (v !== null && typeof v === "object" && index.has(v)) return index.get(v);
    const i = objects.length;
    objects.push(null);
    if (v !== null && typeof v === "object") index.set(v, i);
    if (Array.isArray(v)) objects[i] = { array: v.map(add) };
    else if (v && typeof v === "object" && !(v instanceof Uint8Array) && !("uid" in v)) {
      const keys = Object.keys(v);
      objects[i] = { dict: [keys.map(add), keys.map((k) => add(v[k]))] };
    } else objects[i] = { leaf: v };
    return i;
  };
  add(root);
  const parts = [], offsets = [];
  let size = 8;
  const push = (bytes) => { parts.push(bytes); size += bytes.length; };
  const head = (kind, n) => (n < 15 ? [kind << 4 | n] : [kind << 4 | 15, 0x12, n >>> 24 & 255, n >>> 16 & 255, n >>> 8 & 255, n & 255]);
  for (const o of objects) {
    offsets.push(size);
    if (o.array) push(Uint8Array.from([...head(10, o.array.length), ...o.array.flatMap((r) => [r >> 8, r & 255])]));
    else if (o.dict) push(Uint8Array.from([...head(13, o.dict[0].length), ...[...o.dict[0], ...o.dict[1]].flatMap((r) => [r >> 8, r & 255])]));
    else {
      const v = o.leaf;
      if (v === null) push(Uint8Array.of(0));
      else if (typeof v === "boolean") push(Uint8Array.of(v ? 9 : 8));
      else if (typeof v === "number") { const b = new Uint8Array(9); b[0] = 0x13; new DataView(b.buffer).setBigInt64(1, BigInt(v)); push(b); }
      else if (v instanceof Uint8Array) push(Uint8Array.from([...head(4, v.length), ...v]));
      else if (typeof v === "string") {
        if (/^[\x00-\x7f]*$/.test(v)) push(Uint8Array.from([...head(5, v.length), ...[...v].map((c) => c.charCodeAt(0))]));
        else { const u = []; for (let i = 0; i < v.length; i++) { const c = v.charCodeAt(i); u.push(c >> 8, c & 255); } push(Uint8Array.from([...head(6, v.length), ...u])); }
      } else if ("uid" in v) push(Uint8Array.of(0x81, v.uid >> 8, v.uid & 255));
    }
  }
  const tableAt = size;
  const table = offsets.flatMap((o) => [o >>> 24 & 255, o >>> 16 & 255, o >>> 8 & 255, o & 255]);
  const trailer = new Uint8Array(32);
  const tv = new DataView(trailer.buffer);
  tv.setUint8(6, 4); tv.setUint8(7, 2);
  tv.setBigUint64(8, BigInt(objects.length)); tv.setBigUint64(16, 0n); tv.setBigUint64(24, BigInt(tableAt));
  const all = [new TextEncoder().encode("bplist00"), ...parts, Uint8Array.from(table), trailer];
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of all) { out.set(p, at); at += p.length; }
  return out;
}

/** An NSKeyedArchiver archive of an array of pasteboard items, each {type: Uint8Array | string}. */
export function archivePasteboard(items) {
  const objects = ["$null"];
  const put = (v) => { objects.push(v); return uid(objects.length - 1); };
  const cls = (name, chain) => put({ $classname: name, $classes: chain });
  const dictClass = cls("NSDictionary", ["NSDictionary", "NSObject"]), arrClass = cls("NSArray", ["NSArray", "NSObject"]);
  const dataClass = cls("NSMutableData", ["NSMutableData", "NSData", "NSObject"]);
  const itemRefs = items.map((item) => {
    const keys = Object.keys(item).map((k) => put(k));
    const vals = Object.values(item).map((v) => (typeof v === "string" ? put(v) : put({ "NS.data": v, $class: dataClass })));
    return put({ "NS.keys": keys, "NS.objects": vals, $class: dictClass });
  });
  const root = put({ "NS.objects": itemRefs, $class: arrClass });
  return writeBplist({ $version: 100000, $archiver: "NSKeyedArchiver", $top: { root }, $objects: objects });
}
