// Apple binary property lists ("bplist00") and NSKeyedArchiver archives inside them, read-only,
// for the Paste importer (pasteimport.js). Dates come back as Date, data as Uint8Array, UIDs as
// {uid}. `unarchive` turns a keyed archive into plain values: dictionaries into Maps, arrays,
// strings, data and the fields of other objects (with their class name in `$class`).

const utf16 = new TextDecoder("utf-16be"), latin = new TextDecoder("latin1");

export const isBplist = (b) => b?.length >= 8 && latin.decode(b.subarray(0, 8)) === "bplist00";

export function parseBplist(bytes) {
  if (!isBplist(bytes)) throw new Error("not a binary plist");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const t = bytes.length - 32;
  const offsetSize = view.getUint8(t + 6), refSize = view.getUint8(t + 7);
  const count = Number(view.getBigUint64(t + 8)), top = Number(view.getBigUint64(t + 16)), table = Number(view.getBigUint64(t + 24));
  const uint = (at, size) => { let v = 0; for (let i = 0; i < size; i++) v = v * 256 + bytes[at + i]; return v; };
  const offset = (i) => uint(table + i * offsetSize, offsetSize);
  const cache = new Map();
  const read = (i, depth = 0) => {
    if (depth > 200 || i >= count) return null;
    if (cache.has(i)) return cache.get(i);
    const at = offset(i), marker = bytes[at], kind = marker >> 4, low = marker & 15;
    const length = () => {
      if (low !== 15) return [low, at + 1];
      const m = bytes[at + 1], size = 1 << (m & 15);
      return [uint(at + 2, size), at + 2 + size];
    };
    let value = null;
    if (kind === 0) value = low === 8 ? false : low === 9 ? true : null;
    else if (kind === 1) {
      const size = 1 << low;
      value = size === 8 ? Number(view.getBigInt64(at + 1)) : size === 16 ? Number(view.getBigInt64(at + 9)) : uint(at + 1, size);
    } else if (kind === 2) value = low === 2 ? view.getFloat32(at + 1) : view.getFloat64(at + 1);
    else if (kind === 3) value = new Date((view.getFloat64(at + 1) + 978307200) * 1000);
    else if (kind === 4) { const [n, s] = length(); value = bytes.slice(s, s + n); }
    else if (kind === 5) { const [n, s] = length(); value = latin.decode(bytes.subarray(s, s + n)); }
    else if (kind === 6) { const [n, s] = length(); value = utf16.decode(bytes.subarray(s, s + n * 2)); }
    else if (kind === 7) { const [n, s] = length(); value = new TextDecoder().decode(bytes.subarray(s, s + n)); }
    else if (kind === 8) value = { uid: uint(at + 1, low + 1) };
    else if (kind === 10 || kind === 12) {
      const [n, s] = length();
      value = [];
      cache.set(i, value);
      for (let k = 0; k < n; k++) value.push(read(uint(s + k * refSize, refSize), depth + 1));
    } else if (kind === 13) {
      const [n, s] = length();
      value = {};
      cache.set(i, value);
      for (let k = 0; k < n; k++) {
        const key = read(uint(s + k * refSize, refSize), depth + 1);
        value[String(key)] = read(uint(s + (n + k) * refSize, refSize), depth + 1);
      }
    }
    cache.set(i, value);
    return value;
  };
  return read(top);
}

const isUID = (v) => v && typeof v === "object" && !Array.isArray(v) && typeof v.uid === "number" && Object.keys(v).length === 1;

/** True for an NSKeyedArchiver archive. */
export const isKeyedArchive = (v) => v && typeof v === "object" && Array.isArray(v.$objects) && v.$top && typeof v.$top === "object";

/** A keyed archive as plain values (its root, or every top value when there's no `root`). */
export function unarchive(archive) {
  const objects = archive.$objects;
  const done = new Map();
  const resolve = (v, depth = 0) => {
    if (depth > 100) return null;
    if (isUID(v)) return object(v.uid, depth + 1);
    if (Array.isArray(v)) return v.map((x) => resolve(x, depth + 1));
    return v;
  };
  const object = (index, depth) => {
    if (done.has(index)) return done.get(index);
    const raw = objects[index];
    if (raw === "$null") return null;
    if (!raw || typeof raw !== "object" || raw instanceof Uint8Array || raw instanceof Date || Array.isArray(raw)) return raw;
    const cls = isUID(raw.$class) ? objects[raw.$class.uid]?.$classname ?? null : null;
    if (raw["NS.keys"] && raw["NS.objects"]) {
      const map = new Map();
      done.set(index, map);
      raw["NS.keys"].forEach((k, i) => map.set(resolve(k, depth), resolve(raw["NS.objects"][i], depth)));
      return map;
    }
    if (raw["NS.objects"]) { const list = []; done.set(index, list); for (const x of raw["NS.objects"]) list.push(resolve(x, depth)); return list; }
    if ("NS.string" in raw) return resolve(raw["NS.string"], depth);
    if ("NS.bytes" in raw) return raw["NS.bytes"];
    if ("NS.data" in raw) return resolve(raw["NS.data"], depth);
    if ("NS.relative" in raw) return resolve(raw["NS.relative"], depth);
    if ("NS.time" in raw) return new Date((raw["NS.time"] + 978307200) * 1000);
    const out = { $class: cls };
    done.set(index, out);
    for (const [k, x] of Object.entries(raw)) if (k !== "$class") out[k] = resolve(x, depth);
    return out;
  };
  const top = archive.$top;
  if ("root" in top) return resolve(top.root);
  return Object.fromEntries(Object.entries(top).map(([k, v]) => [k, resolve(v)]));
}

/** Any bytes as a value: a binary plist (unarchived if it's a keyed archive), else the bytes. */
export function decodeBlob(bytes) {
  if (!isBplist(bytes)) return bytes;
  try {
    const v = parseBplist(bytes);
    return isKeyedArchive(v) ? unarchive(v) : v;
  } catch {
    return bytes;
  }
}
