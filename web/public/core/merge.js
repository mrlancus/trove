// Line-based 3-way merge (diff3 over a Myers LCS). A straight port of TextMerge.swift so every
// device, browser included, merges concurrent edits identically. Returns null on a real conflict.

export function merge(base, ours, theirs) {
  if (ours === theirs || theirs === base) return ours;
  if (ours === base) return theirs;
  const b = base.split("\n"), o = ours.split("\n"), t = theirs.split("\n");
  const mo = matches(b, o), mt = matches(b, t);
  const out = [];
  let i = 0, j = 0, k = 0;
  const same = (x, y) => x.length === y.length && x.every((v, n) => v === y[n]);
  for (;;) {
    if (j < b.length && mo[j] === i && mt[j] === k) {
      out.push(b[j]);
      i++; j++; k++;
      continue;
    }
    let j2 = j;
    while (j2 < b.length && (mo[j2] === null || mt[j2] === null)) j2++;
    const i2 = j2 < b.length ? mo[j2] : o.length;
    const k2 = j2 < b.length ? mt[j2] : t.length;
    const oc = o.slice(i, i2), bc = b.slice(j, j2), tc = t.slice(k, k2);
    if (same(oc, bc)) out.push(...tc);
    else if (same(tc, bc) || same(oc, tc)) out.push(...oc);
    else return null;
    i = i2; j = j2; k = k2;
    if (j >= b.length && i >= o.length && k >= t.length) break;
  }
  return out.join("\n");
}

/** For each line of `a`, the index of its match in `b` on a longest common subsequence, or null. */
export function matches(a, b) {
  const n = a.length, m = b.length;
  const result = new Array(n).fill(null);
  if (n === 0 || m === 0) return result;
  const max = n + m, offset = max;
  let v = new Array(2 * max + 2).fill(0);
  const trace = [];
  outer: for (let d = 0; d <= max; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x++; y++; }
      v[offset + k] = x;
      if (x >= n && y >= m) break outer;
    }
  }
  let x = n, y = m;
  for (let d = trace.length - 1; d >= 0; d--) {
    const vd = trace[d];
    const k = x - y;
    const prevK = k === -d || (k !== d && vd[offset + k - 1] < vd[offset + k + 1]) ? k + 1 : k - 1;
    const prevX = d === 0 ? 0 : vd[offset + prevK];
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) { x--; y--; result[x] = y; }
    if (d === 0) break;
    x = prevX; y = prevY;
  }
  return result;
}
